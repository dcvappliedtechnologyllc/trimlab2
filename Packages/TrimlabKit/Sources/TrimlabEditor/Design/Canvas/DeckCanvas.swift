import CoreGraphics
import SwiftUI
import TrimlabModel

/// What the deck shows besides its geometry and media.
public struct DeckState: Equatable {
  /// The deck playhead in source time; nil hides it.
  public var playhead: RationalTime?
  /// The handle held right now (Task 33 sets it): drawn with v1's 1 px `--gold-glow`.
  public var grabbed: DeckLayout.Handle?
  /// Remove audio: the waveform at 20 % instead of 85 %.
  public var removeAudio: Bool
  /// Quick cut only: the clip's keyframes (faint ivory ticks) and the one the cut lands on (gold).
  public var keyframes: [RationalTime]?
  public var keyframeLanding: RationalTime?
  /// Frames or peaks asked for and not back: their block shimmers.
  public var framesLoading: Bool
  public var peaksLoading: Bool
  /// A missing clip: quiet `--bg-2` blocks, the handles, no playhead.
  public var missing: Bool
  /// v1's span-change glow, 0...1 (`DeckGlow.level`): the kept span lifted by `--brand-ink` at 7 % × this.
  public var spanGlow: Double

  public init(playhead: RationalTime? = nil, grabbed: DeckLayout.Handle? = nil, removeAudio: Bool = false,
              keyframes: [RationalTime]? = nil, keyframeLanding: RationalTime? = nil, framesLoading: Bool = false,
              peaksLoading: Bool = false, missing: Bool = false, spanGlow: Double = 0) {
    self.playhead = playhead
    self.grabbed = grabbed
    self.removeAudio = removeAudio
    self.keyframes = keyframes
    self.keyframeLanding = keyframeLanding
    self.framesLoading = framesLoading
    self.peaksLoading = peaksLoading
    self.missing = missing
    self.spanGlow = spanGlow
  }
}

/// v1's "the kept span brightens as it changes" (§6.0): a handle drag that moves the span lifts it by ivory at
/// `alpha`, easing away over `duration` after the last change (holds, then lets go). None under reduced motion.
public enum DeckGlow {
  public static let duration: Double = 0.18
  public static let alpha: Double = 0.07

  /// The glow `elapsed` seconds after the last span change: 1 − e², e = elapsed / duration.
  public static func level(elapsed: Double, reduceMotion: Bool) -> Double {
    let e = elapsed / duration
    return e >= 1 || e < 0 || reduceMotion ? 0 : 1 - e * e
  }
}

/// §4.4, §6.2. The trim deck in one `Canvas`, v1's drawing re-typed from the spike: the primary clip's whole source
/// as a filmstrip over a mirrored `sqrt(peak)` waveform, `--deck-out` outside the kept span, gold span edges, the
/// In and Out brackets with their feet, grab tabs and grip lines, the ivory playhead with its cap. Zoomed, the
/// overview rail runs in the 8 px under the deck. Quick cut adds faint keyframe ticks and the landing one in gold.
/// VoiceOver sees one element with the In and Out times.
public struct DeckCanvas: View {
  let layout: DeckLayout?
  let sprite: StripSprite?
  /// 50 per second (20 ms windows, `MediaCache.peakWindow`).
  let peaks: [Float16]?
  let state: DeckState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(layout: DeckLayout?, sprite: StripSprite?, peaks: [Float16]?, state: DeckState) {
    self.layout = layout
    self.sprite = sprite
    self.peaks = peaks
    self.state = state
  }

  /// The deck and the rail's row under it.
  public static let height = DeckLayout.height + DeckLayout.rail
  static let peaksPerSecond: Double = 50
  /// v1's tick thinning and alphas.
  static let tickSpacing: CGFloat = 4
  static let tickAlpha: Double = 0.22
  static let landingAlpha: Double = 0.9

  public var body: some View {
    let moving = !reduceMotion && layout != nil && (state.framesLoading || state.peaksLoading) && !state.missing
    TimelineView(.animation(paused: !moving)) { timeline in
      let phase = moving
        ? (timeline.date.timeIntervalSinceReferenceDate / StripCanvas.shimmerPeriod).truncatingRemainder(dividingBy: 1)
        : nil
      Canvas(rendersAsynchronously: false) { ctx, _ in
        if let layout { draw(in: &ctx, layout, shimmer: phase) }
      }
    }
    .frame(height: Self.height)
    .accessibilityElement()
    .accessibilityLabel("Trim deck: the selected clip's filmstrip and waveform with In and Out handles")
    .accessibilityValue(layout.map { Self.value(in: $0.inTime, out: $0.outTime, frame: $0.frameDuration) } ?? "")
  }

  /// "In 0:01.21, Out 0:10.07".
  public static func value(_ clip: ReelClip) -> String {
    value(in: clip.inTime, out: clip.outTime, frame: clip.facts.frameDuration)
  }

  static func value(in i: RationalTime, out o: RationalTime, frame: RationalTime) -> String {
    "In \(Formatting.timecode(i, frame: frame)), Out \(Formatting.timecode(o, frame: frame))"
  }

  // MARK: drawing

  private static let top = DeckLayout.cap
  private static let bottom = DeckLayout.height

  func draw(in ctx: inout GraphicsContext, _ L: DeckLayout, shimmer: Double?) {
    let x0 = L.x(forSource: L.visibleStart).rounded()
    let x1 = L.x(forSource: L.visibleStart + RationalTime(seconds: L.visibleDuration, timescale: 60_000)).rounded()
    let body = CGRect(x: x0, y: Self.top, width: x1 - x0, height: DeckLayout.body)
    ctx.fill(Path(body), with: .color(Tokens.bg0))
    var media = ctx
    media.clip(to: Path(body))
    let filmRect = CGRect(x: x0, y: Self.top, width: x1 - x0, height: DeckLayout.film)
    let waveRect = CGRect(x: x0, y: Self.top + DeckLayout.film + DeckLayout.gap, width: x1 - x0,
                          height: DeckLayout.wave)
    if state.missing {
      media.fill(Path(filmRect), with: .color(Tokens.bg2))
      media.fill(Path(waveRect), with: .color(Tokens.bg2))
    } else {
      if let sprite, !sprite.frames.isEmpty {
        film(sprite, L, x0: x0, x1: x1, in: &media)
      } else {
        quiet(filmRect, loading: state.framesLoading, shimmer: shimmer, in: &media)
      }
      if let peaks {
        waveform(peaks, L, x0: x0, x1: x1, rect: waveRect, in: &media)
      } else {
        quiet(waveRect, loading: state.peaksLoading, shimmer: shimmer, in: &media)
      }
    }
    overlay(in: &ctx, L, x0: x0, x1: x1)
    if L.overviewVisible { rail(in: &ctx, L) }
  }

  /// No frames (or peaks) yet: a `--bg-2` block, with v1's drifting band while they load (still under reduced
  /// motion, where `shimmer` is nil).
  private func quiet(_ r: CGRect, loading: Bool, shimmer: Double?, in ctx: inout GraphicsContext) {
    ctx.fill(Path(r), with: .color(Tokens.bg2))
    guard loading, let shimmer else { return }
    let band: CGFloat = 220
    let bx = r.minX - band + CGFloat(shimmer) * (r.width + band)
    let gradient = Gradient(colors: [Tokens.brandInk.opacity(0), Tokens.brandInk.opacity(StripCanvas.shimmerPeak),
                                     Tokens.brandInk.opacity(0)])
    ctx.fill(Path(CGRect(x: bx, y: r.minY, width: band, height: r.height).intersection(r)),
             with: .linearGradient(gradient, startPoint: CGPoint(x: bx, y: 0), endPoint: CGPoint(x: bx + band, y: 0)))
  }

  /// Tiles at the source aspect, laid from the clip's start so a pan carries them along. Zoomed out, each tile
  /// shows the frame for the time at its centre; zoomed in past one cell per tile, each cell fills its own time span
  /// with its frame (the last tile cropped at the next cell), as v1.
  private func film(_ sprite: StripSprite, _ L: DeckLayout, x0: CGFloat, x1: CGFloat,
                    in ctx: inout GraphicsContext) {
    let tw = DeckLayout.film * sprite.aspect
    guard tw > 0 else { return }
    let n = min(sprite.frames.count, sprite.times.count)
    let total = max(L.duration.seconds, 1e-6)
    func tile(_ image: CGImage, _ tx: CGFloat, _ w: CGFloat) {
      guard tx + w > x0, tx < x1, w > 0 else { return }
      let r = CGRect(x: tx, y: Self.top, width: tw, height: DeckLayout.film)
      if w < tw {
        var c = ctx
        c.clip(to: Path(CGRect(x: tx, y: Self.top, width: w, height: DeckLayout.film)))
        c.draw(Image(decorative: image, scale: 1), in: r)
      } else {
        ctx.draw(Image(decorative: image, scale: 1), in: r)
      }
    }
    if n > 0, CGFloat(total / Double(n) / L.visibleDuration) * L.canvasWidth > tw {
      let end = L.visibleStart.seconds + L.visibleDuration
      var i = max(0, sprite.times.lastIndex { $0 <= L.visibleStart } ?? 0)
      while i < n, sprite.times[i].seconds < end {
        let a = L.x(forSource: i == 0 ? .zero : sprite.times[i]).rounded()
        let b = L.x(forSource: i + 1 < n ? sprite.times[i + 1] : L.duration).rounded()
        var tx = a
        while tx < b {
          tile(sprite.frames[i], tx, min(tw, b - tx))
          tx += tw
        }
        i += 1
      }
    } else {
      let ox = L.x(forSource: .zero)
      var tx = ox + ((x0 - ox) / tw).rounded(.down) * tw
      while tx < x1 {
        if let image = sprite.frame(at: L.source(at: tx + tw / 2)) { tile(image, tx, tw) }
        tx += tw
      }
    }
  }

  /// Mirrored `sqrt(peak)`, 1 px columns every 2 px on the clip's own grid (a pan doesn't make them crawl); a
  /// silent clip is a flat baseline.
  private func waveform(_ peaks: [Float16], _ L: DeckLayout, x0: CGFloat, x1: CGFloat, rect: CGRect,
                        in ctx: inout GraphicsContext) {
    let cy = rect.midY, reach = DeckLayout.wave / 2 - 3
    let hz = Self.peaksPerSecond
    let perPx = L.visibleDuration / Double(L.canvasWidth) * hz
    let origin = L.x(forSource: .zero).rounded()
    let phase = ((origin - x0).truncatingRemainder(dividingBy: 2) + 2).truncatingRemainder(dividingBy: 2)
    var path = Path()
    var px = x0 + phase
    let n = peaks.count
    while px < x1 {
      var p: Float = 0
      if n > 0 {
        let a = Int((L.source(at: px).seconds * hz).rounded(.down))
        let b = max(a + 1, Int((Double(a) + 2 * perPx).rounded(.down)))
        var k = max(0, a)
        while k < min(n, b) {
          p = max(p, Float(peaks[k]))
          k += 1
        }
      }
      let h = max(0.5, CGFloat(p.squareRoot()) * reach)
      path.addRect(CGRect(x: px, y: cy - h, width: 1, height: h * 2))
      px += 2
    }
    var c = ctx
    c.opacity = state.removeAudio ? 0.2 : 0.85
    c.fill(path, with: .color(Tokens.wave))
  }

  /// The dim, Quick's keyframe ticks, the span edges, the brackets (glow first) and the playhead.
  private func overlay(in ctx: inout GraphicsContext, _ L: DeckLayout, x0: CGFloat, x1: CGFloat) {
    // Zoomed, a handle can sit far off the canvas: keep the rects near it.
    func lim(_ x: CGFloat) -> CGFloat { min(max(x, -40), L.width + 40) }
    let xi = lim(L.x(forSource: L.inTime).rounded()), xo = lim(L.x(forSource: L.outTime).rounded())
    if xi > x0 { ctx.fill(Path(CGRect(x: x0, y: Self.top, width: xi - x0, height: DeckLayout.body)),
                          with: .color(Tokens.deckOut)) }
    if x1 > xo { ctx.fill(Path(CGRect(x: xo, y: Self.top, width: x1 - xo, height: DeckLayout.body)),
                          with: .color(Tokens.deckOut)) }
    if let keyframes = state.keyframes { ticks(keyframes, L, in: &ctx) }
    let ei = max(xi, x0), eo = min(xo, x1)
    if state.spanGlow > 0, eo > ei {
      ctx.fill(Path(CGRect(x: ei, y: Self.top, width: eo - ei, height: DeckLayout.body)),
               with: .color(Tokens.brandInk.opacity(DeckGlow.alpha * min(state.spanGlow, 1))))
    }
    if eo > ei {
      ctx.fill(Path(CGRect(x: ei, y: Self.top, width: eo - ei, height: 1)), with: .color(Tokens.brandGold))
      ctx.fill(Path(CGRect(x: ei, y: Self.bottom - 1, width: eo - ei, height: 1)), with: .color(Tokens.brandGold))
    }
    if let grabbed = state.grabbed {
      bracket(grabbed == .in ? xi : xo, opensRight: grabbed == .in, grow: 1, color: Tokens.goldGlow, in: &ctx)
    }
    bracket(xi, opensRight: true, grow: 0, color: Tokens.brandGold, in: &ctx)
    bracket(xo, opensRight: false, grow: 0, color: Tokens.brandGold, in: &ctx)
    if let t = state.playhead, !state.missing {
      let xp = lim(L.x(forSource: t).rounded())
      ctx.fill(Path(CGRect(x: xp, y: Self.top, width: 1, height: DeckLayout.body)), with: .color(Tokens.brandInk))
      ctx.fill(Path(roundedRect: CGRect(x: xp - 4, y: 3, width: 9, height: 7), cornerRadius: 2),
               with: .color(Tokens.brandInk))
    }
  }

  /// A bracket `[` (In, opens right) or `]` (Out): a 3 px bar, 7 × 2 feet into the span, and a 9 × 18 grab tab
  /// outside it with a 1 px `--bg-0` grip line. `grow` 1 draws the glow: every part 1 px larger all round.
  private func bracket(_ bx: CGFloat, opensRight: Bool, grow e: CGFloat, color: Color, in ctx: inout GraphicsContext) {
    let top = Self.top, bot = Self.bottom, h = DeckLayout.body
    let bar = opensRight ? bx - 3 : bx, fx = opensRight ? bx : bx - 7, tabY = top + h / 2 - 9
    var p = Path()
    p.addRect(CGRect(x: bar - e, y: top - e, width: 3 + 2 * e, height: h + 2 * e))
    p.addRect(CGRect(x: fx - e, y: top - e, width: 7 + 2 * e, height: 2 + 2 * e))
    p.addRect(CGRect(x: fx - e, y: bot - 2 - e, width: 7 + 2 * e, height: 2 + 2 * e))
    let tab = CGRect(x: (opensRight ? bar - 9 : bar + 3) - e, y: tabY - e, width: 9 + 2 * e, height: 18 + 2 * e)
    let radii = opensRight ? RectangleCornerRadii(topLeading: 3, bottomLeading: 3, bottomTrailing: 0, topTrailing: 0)
                           : RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: 3, topTrailing: 3)
    p.addPath(UnevenRoundedRectangle(cornerRadii: radii).path(in: tab))
    ctx.fill(p, with: .color(color))
    guard e == 0 else { return }
    ctx.fill(Path(CGRect(x: opensRight ? bar - 5 : bar + 6, y: tabY + 5, width: 1, height: 8)),
             with: .color(Tokens.bg0))
  }

  /// Quick cut: faint ivory ticks at keyframes (one per 4 px), the landing one in gold, full height.
  private func ticks(_ times: [RationalTime], _ L: DeckLayout, in ctx: inout GraphicsContext) {
    let start = L.visibleStart, end = L.visibleStart + RationalTime(seconds: L.visibleDuration, timescale: 60_000)
    var faint = Path()
    var last = -CGFloat.infinity
    for t in times where t >= start && t <= end && t != state.keyframeLanding {
      let x = L.x(forSource: t).rounded()
      if x - last < Self.tickSpacing { continue }
      faint.addRect(CGRect(x: x, y: Self.top, width: 1, height: DeckLayout.body))
      last = x
    }
    ctx.fill(faint, with: .color(Tokens.brandInk.opacity(Self.tickAlpha)))
    if let land = state.keyframeLanding, land >= start, land <= end {
      ctx.fill(Path(CGRect(x: L.x(forSource: land).rounded(), y: Self.top, width: 1, height: DeckLayout.body)),
               with: .color(Tokens.brandGold.opacity(Self.landingAlpha)))
    }
  }

  /// v1's overview, zoomed only: a 3 px `--line` rail across the timeline, the kept span as a gold run, the
  /// visible window as a `--brand-steel` hairline outline, the playhead as a 1 px ivory mark.
  private func rail(in ctx: inout GraphicsContext, _ L: DeckLayout) {
    let y = Self.bottom
    let track = CGRect(x: DeckLayout.pad, y: y + 3, width: L.canvasWidth, height: 3)
    ctx.fill(Path(roundedRect: track, cornerRadius: 1.5), with: .color(Tokens.line))
    let si = L.railX(forSource: L.inTime), so = L.railX(forSource: L.outTime)
    if so > si {
      ctx.fill(Path(roundedRect: CGRect(x: si, y: y + 3, width: so - si, height: 3), cornerRadius: 1.5),
               with: .color(Tokens.brandGold.opacity(0.8)))
    }
    let w = L.railWindow
    let window = CGRect(x: w.lowerBound, y: y + 2, width: w.upperBound - w.lowerBound, height: 5)
    ctx.stroke(Path(roundedRect: window.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
               with: .color(Tokens.brandSteel.opacity(0.6)), lineWidth: 1)
    if let t = state.playhead, !state.missing {
      ctx.fill(Path(CGRect(x: L.railX(forSource: min(t, L.duration)), y: y + 1, width: 1, height: 7)),
               with: .color(Tokens.brandInk))
    }
  }
}
