import CoreGraphics
import SwiftUI
import TrimlabMedia
import TrimlabModel

/// One clip's strip frames: the sprite's 40 cells cut apart and decoded once, with the source time of each.
public struct StripSprite: @unchecked Sendable {
  public let frames: [CGImage]
  /// Source time of each frame, ascending.
  public let times: [RationalTime]
  /// Frame width / height (the source's display aspect).
  public let aspect: CGFloat

  public init(frames: [CGImage], times: [RationalTime]) {
    self.frames = frames
    self.times = times
    let first = frames.first
    aspect = first.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 9.0 / 16.0
  }

  /// Cuts `sprite` into its cells, decoded off the main actor so drawing never decodes.
  @concurrent
  public static func make(_ sprite: Sprite) async -> StripSprite? {
    let sheet = sprite.image
    let n = max(sprite.frames, 1)
    let cellW = sheet.width / n, h = sheet.height
    guard cellW > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var frames: [CGImage] = []
    frames.reserveCapacity(n)
    for i in 0..<n {
      guard let cell = sheet.cropping(to: CGRect(x: i * cellW, y: 0, width: cellW, height: h)),
            let ctx = CGContext(data: nil, width: cellW, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return nil }
      ctx.draw(cell, in: CGRect(x: 0, y: 0, width: cellW, height: h))
      guard let decoded = ctx.makeImage() else { return nil }
      frames.append(decoded)
    }
    let times = sprite.times.count == n ? sprite.times : Array(sprite.times.prefix(n))
    return StripSprite(frames: frames, times: times)
  }

  /// A poster as a one-frame sprite: scaled to the sprite's cell height (64 pt at 2×) and decoded off the main actor,
  /// so a tile draws it until its sprite lands.
  @concurrent
  public static func poster(_ image: CGImage) async -> StripSprite? {
    guard image.width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let h = min(image.height, Self.cellHeight)
    let w = max(1, Int((Double(h) * Double(image.width) / Double(image.height)).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let decoded = ctx.makeImage() else { return nil }
    return StripSprite(frames: [decoded], times: [.zero])
  }

  /// The sprite's cell height in px (`MediaCache`'s 64 pt at 2×).
  static let cellHeight = 128

  /// The frame showing source time `t`: the last one at or before it.
  func frame(at t: RationalTime) -> CGImage? {
    guard !frames.isEmpty else { return nil }
    var lo = 0, hi = min(times.count, frames.count) - 1
    if hi < 0 { return frames[0] }
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if times[mid] <= t { lo = mid } else { hi = mid - 1 }
    }
    return frames[lo]
  }
}

/// What the strip shows besides geometry: selection, tile states, the playhead, the reorder caret and ghost.
public struct StripState: Equatable {
  /// The reorder ghost: tile `id` at `Tokens.ghostOpacity`, at most `Tokens.Layout.ghostMaxWidth` wide and lifted
  /// `Tokens.Layout.ghostLift`, following the pointer's x.
  public struct Ghost: Equatable {
    public var id: UUID
    /// The pointer's x (view coordinates).
    public var x: CGFloat
    /// Where on the tile it was grabbed, in px of the tile (kept proportionally under the pointer).
    public var grabOffset: CGFloat
    public init(id: UUID, x: CGFloat, grabOffset: CGFloat) {
      self.id = id
      self.x = x
      self.grabOffset = grabOffset
    }
  }

  public var primary: UUID?
  /// The whole selection, primary included.
  public var selected: Set<UUID>
  /// Tiles still waiting for facts or frames: the shimmer.
  public var loading: Set<UUID>
  public var missing: Set<UUID>
  /// Tiles being dragged (35 %).
  public var dragged: Set<UUID>
  /// Reel time; nil hides the playhead.
  public var playhead: RationalTime?
  /// The reorder / Finder-drop caret's gap (`StripLayout.gap(at:)`); nil hides it.
  public var caretGap: Int?
  public var ghost: Ghost?
  /// VoiceOver label per tile (`StripCanvas.label`).
  public var labels: [UUID: String]

  public init(primary: UUID? = nil, selected: Set<UUID> = [], loading: Set<UUID> = [], missing: Set<UUID> = [],
              dragged: Set<UUID> = [], playhead: RationalTime? = nil, caretGap: Int? = nil, ghost: Ghost? = nil,
              labels: [UUID: String] = [:]) {
    self.primary = primary
    self.selected = selected
    self.loading = loading
    self.missing = missing
    self.dragged = dragged
    self.playhead = playhead
    self.caretGap = caretGap
    self.ghost = ghost
    self.labels = labels
  }
}

/// §4.3.1. The Reel strip in one `Canvas`: a 12 px cap row (playhead cap, the `3:00` label) over 56 px tiles of
/// sprite frames sampled across each clip's kept span, edge to edge at source aspect, radius 3. Crossfades carry a
/// `JoinMark`, the 3:00 point a `ThreeMinuteMarker` (tiles past it dimmed), and a reorder a `DropCaret`.
/// VoiceOver sees one element per tile.
public struct StripCanvas: View {
  let layout: StripLayout
  let sprites: [UUID: StripSprite]
  let state: StripState
  /// VoiceOver's default action on a tile: select it (the strip's click).
  let onSelect: ((UUID) -> Void)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `sprites` by clip id.
  public init(layout: StripLayout, sprites: [UUID: StripSprite], state: StripState,
              onSelect: ((UUID) -> Void)? = nil) {
    self.layout = layout
    self.sprites = sprites
    self.state = state
    self.onSelect = onSelect
  }

  static let radius: CGFloat = 3
  /// v1's shimmer: a soft band crossing in 1.8 s, `--brand-ink` at 4.5 % at its peak.
  static let shimmerPeriod: Double = 1.8
  static let shimmerPeak: Double = 0.045

  public var body: some View {
    let moving = !reduceMotion && !state.loading.isEmpty
    TimelineView(.animation(paused: !moving)) { timeline in
      let phase = moving
        ? (timeline.date.timeIntervalSinceReferenceDate / Self.shimmerPeriod).truncatingRemainder(dividingBy: 1) : nil
      Canvas(rendersAsynchronously: false) { ctx, size in
        draw(in: &ctx, size: size, shimmer: phase)
      }
    }
    .frame(height: Tokens.Layout.strip)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Reel strip")
    .accessibilityChildren { tileElements }
  }

  /// One invisible element per tile, where the tile is.
  private var tileElements: some View {
    ZStack(alignment: .topLeading) {
      ForEach(layout.tiles) { tile in
        Rectangle()
          .frame(width: tile.rect.width, height: tile.rect.height)
          .offset(x: tile.rect.minX, y: tile.rect.minY)
          .accessibilityElement()
          .accessibilityLabel(state.labels[tile.id] ?? "Clip \(tile.index + 1)")
          .accessibilityIdentifier("strip.tile.\(tile.index)")
          .accessibilityAddTraits(state.selected.contains(tile.id) ? [.isSelected, .isButton] : .isButton)
          .accessibilityAction { onSelect?(tile.id) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// "Clip 4 of 18, IMG_4821, 3.2 seconds" (the length as the inspector's Clip row); ", missing" when it is.
  public static func label(index: Int, count: Int, clip: ReelClip, missing: Bool) -> String {
    let length = Formatting.clipLength(clip.trimmed).replacingOccurrences(of: "\u{00A0}s", with: " seconds")
    return "Clip \(index + 1) of \(count), \(InspectorView.clipName(clip)), \(length)\(missing ? ", missing" : "")"
  }

  // MARK: drawing

  func draw(in ctx: inout GraphicsContext, size: CGSize, shimmer: Double?) {
    let visible = layout.tiles.filter { $0.rect.maxX >= 0 && $0.rect.minX <= size.width }
    for tile in visible {
      var c = ctx
      if state.dragged.contains(tile.id) { c.opacity = 0.35 }
      paintTile(tile, in: &c, shimmer: shimmer)
    }
    for tile in visible where tile.overlapLeft > 0 { JoinMark.draw(in: &ctx, over: tile) }
    if let lx = layout.limitX {
      ThreeMinuteMarker.draw(in: &ctx, at: lx, contentEnd: (layout.tiles.last?.rect.maxX ?? lx), size: size)
    }
    outlines(in: &ctx, visible)
    if let t = state.playhead, !layout.tiles.isEmpty { playhead(in: &ctx, x: layout.x(for: t).rounded()) }
    if let gap = state.caretGap { DropCaret.draw(in: &ctx, gap: gap, layout: layout) }
    if let ghost = state.ghost { self.ghost(ghost, in: &ctx, shimmer: shimmer) }
  }

  /// The grabbed tile at 80 % with the primary's gold outline, at most 96 px wide, lifted 6 px (the mockup).
  private func ghost(_ g: StripState.Ghost, in ctx: inout GraphicsContext, shimmer: Double?) {
    guard var tile = layout.tiles.first(where: { $0.id == g.id }), tile.rect.width > 0 else { return }
    let w = min(Tokens.Layout.ghostMaxWidth, tile.rect.width)
    let grab = min(max(g.grabOffset / tile.rect.width, 0), 1) * w
    tile.rect = CGRect(x: g.x - grab, y: tile.rect.minY - Tokens.Layout.ghostLift, width: w, height: tile.rect.height)
    var c = ctx
    c.opacity = Tokens.ghostOpacity
    paintTile(tile, in: &c, shimmer: shimmer)
    let line: CGFloat = 1.5
    let ring = Path(roundedRect: tile.rect.insetBy(dx: line / 2, dy: line / 2), cornerRadius: Self.radius - line / 2,
                    style: .continuous)
    ctx.stroke(ring, with: .color(Tokens.brandGold), lineWidth: line)
  }

  private func paintTile(_ tile: StripLayout.Tile, in ctx: inout GraphicsContext, shimmer: Double?) {
    let r = tile.rect
    var c = ctx
    c.clip(to: Path(roundedRect: r, cornerRadius: Self.radius, style: .continuous))
    if state.missing.contains(tile.id) {
      c.fill(Path(r), with: .color(Tokens.bg2))
      let text = c.resolve(Text("Missing").font(.tl(.inter(.regular), 12)).foregroundStyle(Tokens.muted))
      if text.measure(in: r.size).width + 6 <= r.width { c.draw(text, at: CGPoint(x: r.midX, y: r.midY + 0.5)) }
    } else if let sprite = sprites[tile.id], !state.loading.contains(tile.id) {
      frames(sprite, tile, in: &c)
    } else {
      c.fill(Path(r), with: .color(Tokens.bg2))
      if state.loading.contains(tile.id), let shimmer { band(in: &c, r, phase: shimmer) }
    }
  }

  /// Frames edge to edge at the source aspect, each showing the kept-span time under its middle.
  private func frames(_ sprite: StripSprite, _ tile: StripLayout.Tile, in ctx: inout GraphicsContext) {
    let r = tile.rect
    let fw = r.height * sprite.aspect
    guard fw > 0 else { return }
    let start = tile.keptSpan.start.seconds, dur = tile.keptSpan.duration.seconds
    var tx = r.minX
    while tx < r.maxX {
      let s = start + Double((tx + fw / 2 - r.minX) / r.width) * dur
      if let image = sprite.frame(at: StripLayout.time(s)) {
        ctx.draw(Image(decorative: image, scale: 1), in: CGRect(x: tx, y: r.minY, width: fw, height: r.height))
      }
      tx += fw
    }
  }

  /// The shimmer's band at tile size; reduced motion leaves only the `--bg-2` block.
  private func band(in ctx: inout GraphicsContext, _ r: CGRect, phase: Double) {
    let width = min(220, max(24, r.width))
    let bx = r.minX - width + CGFloat(phase) * (r.width + width)
    let gradient = Gradient(colors: [Tokens.brandInk.opacity(0), Tokens.brandInk.opacity(Self.shimmerPeak),
                                     Tokens.brandInk.opacity(0)])
    ctx.fill(Path(CGRect(x: bx, y: r.minY, width: width, height: r.height)),
             with: .linearGradient(gradient, startPoint: CGPoint(x: bx, y: 0), endPoint: CGPoint(x: bx + width, y: 0)))
  }

  /// Also-selected: a 1 px `--muted` ring just outside the tile (in its half of the gap). Primary: 1.5 px gold,
  /// inset. A dragged primary shows no outline.
  private func outlines(in ctx: inout GraphicsContext, _ visible: [StripLayout.Tile]) {
    for tile in visible where state.selected.contains(tile.id) && tile.id != state.primary {
      let ring = Path(roundedRect: tile.rect.insetBy(dx: -0.5, dy: -0.5), cornerRadius: Self.radius + 0.5,
                      style: .continuous)
      ctx.stroke(ring, with: .color(Tokens.muted), lineWidth: 1)
    }
    if let id = state.primary, !state.dragged.contains(id), let tile = visible.first(where: { $0.id == id }) {
      let w: CGFloat = 1.5
      let path = Path(roundedRect: tile.rect.insetBy(dx: w / 2, dy: w / 2), cornerRadius: Self.radius - w / 2,
                      style: .continuous)
      ctx.stroke(path, with: .color(Tokens.brandGold), lineWidth: w)
    }
  }

  /// 1 px ivory line over the tiles with v1's 9 × 7 cap in the cap row.
  private func playhead(in ctx: inout GraphicsContext, x: CGFloat) {
    ctx.fill(Path(CGRect(x: x, y: Tokens.Layout.stripCap, width: 1, height: Tokens.Layout.stripTile)),
             with: .color(Tokens.brandInk))
    ctx.fill(Path(roundedRect: CGRect(x: x - 4, y: 3, width: 9, height: 7), cornerRadius: 2),
             with: .color(Tokens.brandInk))
  }
}
