import CoreGraphics
import Foundation
import TrimlabModel

/// §4.3.1. Where every tile of the Reel strip sits, and the strip's x ↔ Reel-time mapping. Pure geometry: the canvas
/// draws it and the model hit-tests it, so 30 clips cost one draw.
///
/// - Tile width = trimmed length × px/s, at least `Tokens.Layout.minTile`; 2 px gaps at cuts; at a crossfade the
///   incoming tile overlaps the outgoing one by the effective fade × px/s (no gap).
/// - Fit always fits: the content is exactly `width` wide (minimum-width tiles included). A long Reel lowers the
///   minimum tile to what fits (to 4 px), then the gaps (to 1 px, then 0). A zoom is capped at `maxPxPerSecond`.
/// - x ↔ time is linear **inside each tile**, so a minimum-width tile never shifts time anywhere else. In an
///   overlap, time belongs to the incoming tile.
/// - A missing clip (no placement in `plan`) still gets its tile, at its trimmed length, but covers no Reel time.
/// - All x values are in view coordinates: content x − `scrollX`.
public struct StripLayout: Equatable {
  public struct Tile: Equatable, Identifiable {
    public var id: UUID
    /// The clip's position in the Reel.
    public var index: Int
    /// In view coordinates: y from the cap row's bottom, `Tokens.Layout.stripTile` tall.
    public var rect: CGRect
    /// Source time kept (In ..< Out): what the tile's frames are sampled across.
    public var keptSpan: TimeSpan
    /// Output time the tile covers; zero-length for a missing clip.
    public var reelSpan: TimeSpan
    /// How far this tile overlaps the one before it (the crossfade into it); 0 at a cut.
    public var overlapLeft: CGFloat
  }

  public static let maxPxPerSecond: CGFloat = 200

  public private(set) var tiles: [Tile] = []
  public private(set) var pxPerSecond: CGFloat = 0
  /// The whole strip's width at this zoom (the last tile's right edge, in content coordinates).
  public private(set) var contentWidth: CGFloat = 0
  /// The view's width.
  public let width: CGFloat
  /// True in Fit: the content is exactly the view's width, with nothing to scroll.
  public let fits: Bool
  /// Clamped to the content.
  public private(set) var scrollX: CGFloat = 0
  /// The x of 3:00 when the Reel (Reel format) runs past it; nil otherwise (§4.3.6, Task 27 ruling).
  public private(set) var limitX: CGFloat?

  /// `clips` is the Reel's whole list (missing ones included); `plan` is `Planner.plan` of it. `format` is the
  /// Reel's export format: the 3:00 marker is a Reel-format rule.
  public init(plan: CompositionPlan, clips: [ReelClip], width: CGFloat, zoom: StripZoom, scrollX: CGFloat = 0,
              format: ExportSpec.Format = .reel) {
    self.width = width
    fits = zoom == .fit
    guard !clips.isEmpty else { return }
    let placed = Dictionary(plan.placements.map { ($0.clipID, $0) }, uniquingKeysWith: { a, _ in a })

    // Per tile: its length, and the fade (in seconds) it overlaps the previous tile by.
    let lens = clips.map { CGFloat($0.trimmed.seconds) }
    var fades = [CGFloat](repeating: 0, count: clips.count)
    for i in clips.indices.dropFirst() {
      if let p = placed[clips[i].id], placed[clips[i - 1].id] != nil, p.fadeIn > .zero {
        fades[i] = CGFloat(p.fadeIn.seconds)
      }
    }

    let cuts = fades.indices.dropFirst().filter { fades[$0] == 0 }.count
    let sizes = fits ? Self.squeezed(count: clips.count, cuts: cuts, width: width)
                     : Sizes(minTile: Tokens.Layout.minTile, gap: Tokens.Layout.tileGap)
    let p: CGFloat
    switch zoom {
    case .fit: p = Self.fitPxPerSecond(lens: lens, fades: fades, sizes: sizes, width: width)
    case .pxPerSecond(let v): p = min(max(CGFloat(v), 0), Self.maxPxPerSecond)
    }
    pxPerSecond = p
    let geo = Self.geometry(lens: lens, fades: fades, p: p, sizes: sizes)

    // Lay out in content coordinates.
    var x: CGFloat = 0
    var built: [Tile] = []
    built.reserveCapacity(clips.count)
    var lastEnd = RationalTime.zero
    for (i, clip) in clips.enumerated() {
      let w = geo.widths[i], overlap = geo.overlaps[i]
      if i > 0 { x += overlap > 0 ? -overlap : sizes.gap }
      let span: TimeSpan
      if let pl = placed[clip.id] {
        span = pl.reelSpan
        lastEnd = pl.reelSpan.end
      } else {
        span = TimeSpan(start: lastEnd, duration: .zero)
      }
      built.append(Tile(id: clip.id, index: i,
                        rect: CGRect(x: x, y: Tokens.Layout.stripCap, width: w, height: Tokens.Layout.stripTile),
                        keptSpan: TimeSpan(start: clip.inTime, duration: clip.trimmed), reelSpan: span,
                        overlapLeft: overlap))
      x += w
    }
    contentWidth = x
    let scroll = max(0, min(scrollX, contentWidth - width))
    self.scrollX = scroll
    tiles = built.map { var t = $0; t.rect.origin.x -= scroll; return t }
    if format == .reel, plan.total > Limits.reelMax { limitX = self.x(for: Limits.reelMax) }
  }

  /// The smallest a tile may be and the gap at a cut.
  struct Sizes: Equatable {
    var minTile, gap: CGFloat
  }

  /// Fit's sizes for `count` tiles: 24 px tiles and 2 px gaps while they fit; else the minimum falls to what does
  /// fit, down to 4 px; then the gaps shrink to 1 px, then 0; with no gaps the minimum is whatever fits (fix round 1).
  static func squeezed(count n: Int, cuts: Int, width: CGFloat) -> Sizes {
    let floor: CGFloat = 4
    for gap in [Tokens.Layout.tileGap, 1, 0] as [CGFloat] {
      let m = min(Tokens.Layout.minTile, (width - gap * CGFloat(cuts)) / CGFloat(max(n, 1)))
      if m >= floor || gap == 0 { return Sizes(minTile: max(m, 0.01), gap: gap) }
    }
    return Sizes(minTile: floor, gap: 0)
  }

  /// Every tile's width and the overlap into it at `p` px/s. An overlap is the fade × px/s, but never more than
  /// half the shorter of its two tiles.
  static func geometry(lens: [CGFloat], fades: [CGFloat], p: CGFloat, sizes: Sizes)
    -> (widths: [CGFloat], overlaps: [CGFloat], content: CGFloat) {
    let widths = lens.map { max(sizes.minTile, $0 * p) }
    var overlaps = [CGFloat](repeating: 0, count: lens.count)
    var content = widths.reduce(0, +)
    for i in lens.indices.dropFirst() {
      if fades[i] > 0 {
        overlaps[i] = min(fades[i] * p, min(widths[i - 1], widths[i]) / 2)
        content -= overlaps[i]
      } else {
        content += sizes.gap
      }
    }
    return (widths, overlaps, content)
  }

  /// The largest px/s at which the content still fits `width`: exactly `width` wherever the content grows with
  /// px/s, which it always does in the end. Bisection, then a linear step inside the last bracket (the content is
  /// piecewise linear in px/s).
  static func fitPxPerSecond(lens: [CGFloat], fades: [CGFloat], sizes: Sizes, width: CGFloat) -> CGFloat {
    let slack: CGFloat = 1e-9
    func content(_ p: CGFloat) -> CGFloat { geometry(lens: lens, fades: fades, p: p, sizes: sizes).content }
    let total = max(lens.reduce(0, +), 1e-9)
    var lo: CGFloat = 0
    var hi = max(width, 1) / total * 2 + 1
    var grow = 0
    while content(hi) <= width + slack, grow < 64 { lo = hi; hi *= 2; grow += 1 }
    for _ in 0..<64 {
      let mid = (lo + hi) / 2
      if content(mid) <= width + slack { lo = mid } else { hi = mid }
    }
    let cl = content(lo), ch = content(hi)
    if ch > cl {
      let p = lo + (width - cl) * (hi - lo) / (ch - cl)
      if p >= lo, p <= hi, content(p) <= width + slack { return p }
    }
    return lo
  }

  /// Reel time → x. Inside the tile that owns `t` (the incoming one in an overlap); clamped to the strip.
  public func x(for t: RationalTime) -> CGFloat {
    guard let first = tiles.first else { return 0 }
    for tile in tiles.reversed() where tile.reelSpan.duration > .zero && t >= tile.reelSpan.start {
      let f = min(1, CGFloat((t - tile.reelSpan.start).seconds / tile.reelSpan.duration.seconds))
      return tile.rect.minX + f * tile.rect.width
    }
    return first.rect.minX
  }

  /// x → Reel time: the last tile starting at or before `x` (a gap reads as the end of the tile before it).
  public func time(at x: CGFloat) -> RationalTime {
    for tile in tiles.reversed() where tile.reelSpan.duration > .zero && x >= tile.rect.minX {
      let f = min(1, max(0, (x - tile.rect.minX) / tile.rect.width))
      return Self.time(tile.reelSpan.start.seconds + Double(f) * tile.reelSpan.duration.seconds)
    }
    return tiles.first { $0.reelSpan.duration > .zero }?.reelSpan.start ?? .zero
  }

  /// The tile under `p` (in the tile row only); in an overlap, the incoming tile, which is drawn on top.
  public func tile(at p: CGPoint) -> UUID? {
    guard inRow(p) else { return nil }
    return tiles.last { p.x >= $0.rect.minX && p.x <= $0.rect.maxX }?.id
  }

  /// The insertion gap nearest `x`: gap k sits before tile k (0 = before the first, `tiles.count` = after the last).
  public func gap(at x: CGFloat) -> Int { tiles.filter { $0.rect.midX < x }.count }

  /// How far a cut's join reaches past its gap into each neighbour (Task 29 ruling).
  public static let cutSlop: CGFloat = 4

  /// The join under `p`, as the incoming clip's id: a cut's gap plus `cutSlop` either side, or a crossfade's
  /// overlap (at least 4 px wide around its middle). Never the first clip. A join zone sits over the tiles'
  /// edges, so callers test `joinHit` **before** `tile(at:)`: a click on a join cycles it rather than selecting a
  /// tile.
  public func joinHit(at p: CGPoint) -> UUID? {
    guard inRow(p) else { return nil }
    for i in tiles.indices.dropFirst() {
      let t = tiles[i]
      let lo: CGFloat, hi: CGFloat
      if t.overlapLeft > 0 {
        let mid = t.rect.minX + t.overlapLeft / 2
        lo = min(t.rect.minX, mid - 2)
        hi = max(t.rect.minX + t.overlapLeft, mid + 2)
      } else {
        // The gap and `cutSlop` either side of it, but never more than a third of either neighbour (a dense Fit's
        // hairline tiles stay grabbable).
        let prev = tiles[i - 1].rect
        lo = prev.maxX - min(Self.cutSlop, prev.width / 3)
        hi = t.rect.minX + min(Self.cutSlop, t.rect.width / 3)
      }
      if p.x >= lo && p.x <= hi { return t.id }
    }
    return nil
  }

  private func inRow(_ p: CGPoint) -> Bool {
    p.y >= Tokens.Layout.stripCap && p.y <= Tokens.Layout.stripCap + Tokens.Layout.stripTile
  }

  /// Display-side time from the strip's float geometry (never fed back into the edit list unsnapped).
  static func time(_ seconds: Double) -> RationalTime { RationalTime(seconds: seconds, timescale: 60_000) }
}
