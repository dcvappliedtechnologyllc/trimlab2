import CoreGraphics
import Foundation
import TrimlabModel

/// §4.4. The trim deck's geometry for one clip's whole source, in v1's exact numbers: a 12 px cap row, the 64 px
/// filmstrip, a 2 px gap and the 44 px waveform (122 in all), the timeline inset `pad` from each side so a handle
/// at either end still shows its bar and tab. Zoom narrows the visible window of source time, from 1× (the whole
/// clip) to frame level (8 px a frame, v1 T20). Pure geometry: the canvas draws it, the model hit-tests it.
///
/// All x values are in the deck's own coordinates: the deck is `width` wide, the timeline runs from `pad` to
/// `width − pad`.
public struct DeckLayout: Equatable {
  public enum Handle: Hashable, Sendable { case `in`, out }

  public static let cap: CGFloat = 12, film: CGFloat = 64, gap: CGFloat = 2, wave: CGFloat = 44, pad: CGFloat = 20
  /// cap + filmstrip + gap + waveform: 122.
  public static let height: CGFloat = cap + film + gap + wave
  /// The filmstrip and waveform together, under the cap row.
  public static let body: CGFloat = film + gap + wave
  /// The overview rail's box, under the deck in the bottom pad (shown only when zoomed).
  public static let rail: CGFloat = 8
  /// A handle drag snaps to the playhead within this many px (§4.4).
  public static let snapDistance: CGFloat = 6
  /// v1 T20: the deepest zoom shows a frame this many px wide.
  public static let pxPerFrameAtMax: Double = 8
  /// v1's overview: a deep zoom's window stays at least this wide on the rail.
  public static let railMinThumb: CGFloat = 6

  /// The deck's whole width.
  public let width: CGFloat
  /// The timeline's width: the deck less `pad` each side.
  public let canvasWidth: CGFloat
  /// The source's duration, In and Out (exclusive).
  public let duration: RationalTime
  public let inTime: RationalTime
  public let outTime: RationalTime
  public let frameDuration: RationalTime
  /// Clamped to 1 … `maxZoom`.
  public let zoom: Double
  /// The frame level for this clip at this width: duration × fps × 8 / canvas width, never under 1.
  public let maxZoom: Double
  /// The visible window's start (clamped so the window stays inside the clip) and its length in seconds.
  public let visibleStart: RationalTime
  public let visibleDuration: Double

  private let start: Double
  private let total: Double

  /// `offset` is the source time the visible window should start at; it is clamped to the clip.
  public init(clip: ReelClip, width: CGFloat, zoom: Double, offset: RationalTime) {
    self.width = width
    canvasWidth = max(1, width - 2 * Self.pad)
    duration = clip.facts.duration
    inTime = clip.inTime
    outTime = clip.outTime
    frameDuration = clip.facts.frameDuration
    total = max(clip.facts.duration.seconds, 1e-6)
    let frame = max(clip.facts.frameDuration.seconds, 1e-6)
    maxZoom = max(1, total / frame * Self.pxPerFrameAtMax / Double(canvasWidth))
    let z = zoom.isFinite ? min(max(zoom, 1), maxZoom) : 1
    self.zoom = z
    visibleDuration = total / z
    start = z <= 1 ? 0 : min(max(offset.seconds, 0), total - visibleDuration)
    visibleStart = RationalTime(seconds: start, timescale: 60_000)
  }

  /// True while zoomed in: the overview rail shows.
  public var overviewVisible: Bool { zoom > 1 + 1e-9 }

  /// Source time → x (unclamped: a handle off the visible window gets an x off the timeline).
  public func x(forSource t: RationalTime) -> CGFloat {
    Self.pad + CGFloat((t.seconds - start) / visibleDuration) * canvasWidth
  }

  /// x → source time, clamped to the clip.
  public func source(at x: CGFloat) -> RationalTime {
    let s = start + Double((x - Self.pad) / canvasWidth) * visibleDuration
    return RationalTime(seconds: min(max(s, 0), total), timescale: 60_000)
  }

  /// The handle under `p`. v1's reach: a handle owns its bar, foot and grab tab (13 px outside the span) plus 5 px
  /// inside it; where the two reaches overlap (a tiny span), the nearer tab wins.
  public func handle(at p: CGPoint) -> Handle? {
    guard p.y >= 0, p.y <= Self.height else { return nil }
    let xi = x(forSource: inTime), xo = x(forSource: outTime)
    let dIn = p.x >= xi - 13 && p.x <= xi + 5 ? abs(p.x - (xi - 6)) : .infinity
    let dOut = p.x >= xo - 5 && p.x <= xo + 13 ? abs(p.x - (xo + 6)) : .infinity
    if dIn == .infinity && dOut == .infinity { return nil }
    return dIn <= dOut ? .in : .out
  }

  /// `x`, or the playhead's x when it is within `snapDistance` and snapping isn't disabled (⌥).
  public func snapped(_ x: CGFloat, playheadX: CGFloat, disable: Bool) -> CGFloat {
    !disable && abs(x - playheadX) <= Self.snapDistance ? playheadX : x
  }

  // MARK: overview rail

  /// Source time → x on the rail, which spans the timeline's width and shows the whole clip.
  public func railX(forSource t: RationalTime) -> CGFloat {
    Self.pad + CGFloat(t.seconds / total) * canvasWidth
  }

  /// The visible window on the rail: at least `railMinThumb` wide, centred on where it really is, inside the rail.
  public var railWindow: ClosedRange<CGFloat> {
    let k = canvasWidth / CGFloat(total)
    let w = max(Self.railMinThumb, CGFloat(visibleDuration) * k)
    let x = min(max(0, CGFloat(start + visibleDuration / 2) * k - w / 2), max(0, canvasWidth - w))
    return (Self.pad + x)...(Self.pad + x + w)
  }
}
