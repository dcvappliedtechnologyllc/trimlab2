import CoreGraphics
import Foundation
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 32: the trim deck's geometry (§4.4, v1's exact numbers), its one-`Canvas` drawing and deck zoom.
@MainActor @Suite struct DeckLayoutTests {
  static let fps = RationalTime(1001, 30000)

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  // MARK: helpers

  /// The mockup's IMG_4821: 23.6 s at 29.97, kept 0:01.21 – 0:10.07.
  static func clip(duration: RationalTime = RationalTime(236, 10)) -> ReelClip {
    let facts = ClipFacts(duration: duration, frameDuration: fps, displayWidth: 1080, displayHeight: 1920,
                          rotation: 0, videoCodec: "hevc", hasAudio: true, hdr: .sdr, bitrate: 10_000_000,
                          captureDate: nil, needsRemux: false)
    var c = ReelClip.make(source: SourceRef(relativePath: nil, absolutePath: "/Spa Tour/IMG_4821.MOV", size: 1,
                                            modified: Date(timeIntervalSince1970: 0)),
                          facts: facts, framing: .fill)
    c.inTime = StageViewTests.tc(1, 21)
    c.outTime = StageViewTests.tc(10, 7)
    return c
  }

  static func s(_ seconds: Double) -> RationalTime { RationalTime(seconds: seconds, timescale: 30000) }

  // MARK: geometry

  @Test func geometryMatchesV1() {
    #expect(DeckLayout.cap + DeckLayout.film + DeckLayout.gap + DeckLayout.wave == 122)
    #expect(DeckLayout.height == Tokens.Layout.deck)
    #expect(DeckLayout.pad == Tokens.Layout.deckPad)
    let L = DeckLayout(clip: Self.clip(), width: 1240, zoom: 1, offset: .zero)
    #expect(L.canvasWidth == CGFloat(1200), "\(L.canvasWidth)")
    #expect(L.x(forSource: .zero) == 20)
    #expect(L.x(forSource: Self.clip().facts.duration) == 1220)
    // The spike's mapping: 20 + t / d × 1200.
    let t = StageViewTests.tc(1, 21)
    #expect(abs(L.x(forSource: t) - (20 + t.seconds / 23.6 * 1200)) < 1e-6)
  }

  @Test func sourceRoundTrip() {
    let c = Self.clip()
    let frame = c.facts.frameDuration
    for zoom in [1.0, 8.0] {
      let L = DeckLayout(clip: c, width: 1240, zoom: zoom, offset: Self.s(6))
      let lo = L.visibleStart.seconds, hi = L.visibleStart.seconds + L.visibleDuration
      for k in 0...40 {
        let t = Self.s(lo + (hi - lo) * Double(k) / 40)
        let back = L.source(at: L.x(forSource: t))
        #expect(abs((back - t).seconds) <= frame.seconds, "zoom \(zoom): \(t.seconds) → \(back.seconds)")
      }
    }
  }

  @Test func zoomedWindowClampsToTheClip() {
    let c = Self.clip()
    let L = DeckLayout(clip: c, width: 1240, zoom: 4, offset: Self.s(100))
    #expect(abs(L.visibleStart.seconds + L.visibleDuration - 23.6) < 1e-4, "the window ends at the clip's end")
    #expect(DeckLayout(clip: c, width: 1240, zoom: 1, offset: Self.s(5)).visibleStart == .zero, "1× shows it all")
    #expect(DeckLayout(clip: c, width: 1240, zoom: 0.2, offset: .zero).zoom == 1, "never below 1×")
  }

  @Test func snapWithin6px() {
    let L = DeckLayout(clip: Self.clip(), width: 1240, zoom: 1, offset: .zero)
    #expect(L.snapped(505, playheadX: 500, disable: false) == 500)
    #expect(L.snapped(494, playheadX: 500, disable: false) == 500)
    #expect(L.snapped(507, playheadX: 500, disable: false) == 507)
    #expect(L.snapped(505, playheadX: 500, disable: true) == 505, "⌥ disables")
  }

  /// v1's reach: a handle owns its bar, foot and tab (13 px outside the span) and 5 px inside it.
  @Test func handleHits() {
    let L = DeckLayout(clip: Self.clip(), width: 1240, zoom: 1, offset: .zero)
    let xi = L.x(forSource: Self.clip().inTime), xo = L.x(forSource: Self.clip().outTime)
    let y = DeckLayout.cap + 40
    #expect(L.handle(at: CGPoint(x: xi - 6, y: y)) == .in)
    #expect(L.handle(at: CGPoint(x: xi - 13, y: y)) == .in)
    #expect(L.handle(at: CGPoint(x: xi + 5, y: y)) == .in)
    #expect(L.handle(at: CGPoint(x: xi + 6, y: y)) == nil)
    #expect(L.handle(at: CGPoint(x: xi - 14, y: y)) == nil)
    #expect(L.handle(at: CGPoint(x: xo + 6, y: y)) == .out)
    #expect(L.handle(at: CGPoint(x: xo - 5, y: y)) == .out)
    #expect(L.handle(at: CGPoint(x: (xi + xo) / 2, y: y)) == nil)
    #expect(L.handle(at: CGPoint(x: xi - 6, y: DeckLayout.height + 1)) == nil, "below the deck")
    // A tiny span: the nearer tab wins.
    var tiny = Self.clip()
    tiny.outTime = tiny.inTime + RationalTime(1, 10)
    let T = DeckLayout(clip: tiny, width: 1240, zoom: 1, offset: .zero)
    let mid = (T.x(forSource: tiny.inTime) + T.x(forSource: tiny.outTime)) / 2
    #expect(T.handle(at: CGPoint(x: mid - 2, y: y)) == .in)
    #expect(T.handle(at: CGPoint(x: mid + 2, y: y)) == .out)
  }

  /// v1 T20: frame level is 8 px per frame.
  @Test func maxZoomIsFrameLevel() {
    let c = Self.clip()
    let L = DeckLayout(clip: c, width: 1240, zoom: 1, offset: .zero)
    let want = 23.6 / Self.fps.seconds * 8 / 1200
    #expect(abs(L.maxZoom - want) < 1e-9)
    #expect(DeckLayout(clip: c, width: 1240, zoom: 99, offset: .zero).zoom == L.maxZoom)
    let deep = DeckLayout(clip: c, width: 1240, zoom: L.maxZoom, offset: .zero)
    let px = deep.x(forSource: Self.fps) - deep.x(forSource: .zero)
    #expect(abs(px - 8) < 1e-6, "one frame is 8 px at the ceiling: \(px)")
    // A clip shorter than the canvas at 8 px a frame can't zoom at all.
    #expect(DeckLayout(clip: Self.clip(duration: RationalTime(3, 1)), width: 1240, zoom: 1, offset: .zero).maxZoom == 1)
    #expect(!L.overviewVisible)
    #expect(DeckLayout(clip: c, width: 1240, zoom: 2, offset: .zero).overviewVisible)
  }

  // MARK: zoom (model)

  @Test func zoomResetsOnSelect() async throws {
    let h = try await StageViewTests.reel()
    let ids = try #require(h.model.reel?.clips.map(\.id))
    h.model.deckResized(width: 1240)
    h.model.deckZoom = 4
    h.model.select(ids[3], extend: false, toggle: false)
    #expect(h.model.deckZoom == 4, "the same clip keeps its zoom")
    h.model.select(ids[5], extend: false, toggle: false)
    #expect(h.model.deckZoom == 1)
    #expect(h.model.deckOffset == .zero)
    h.model.deckZoom = 3
    h.model.command(.selectNext)
    #expect(h.model.deckZoom == 1, "↑ / ↓ too")
  }

  @Test func zoomStepsStopAtFrameLevel() async throws {
    let h = try await StageViewTests.reel()
    h.model.deckResized(width: 1240)
    let ceiling = try #require(h.model.deckLayout()).maxZoom
    for _ in 0..<20 { h.model.deckZoomStep(1) }
    #expect(abs(h.model.deckZoom - ceiling) < 1e-9)
    #expect(h.model.deckLayout()?.overviewVisible == true)
    for _ in 0..<20 { h.model.deckZoomStep(-1) }
    #expect(h.model.deckZoom == 1)
    #expect(h.model.deckLayout()?.overviewVisible == false)
  }

  /// Pinch and ⌘-scroll keep the source time under the pointer where it is.
  @Test func zoomKeepsTheAnchor() async throws {
    let h = try await StageViewTests.reel()
    h.model.deckResized(width: 1240)
    let before = try #require(h.model.deckLayout())
    let t = before.source(at: 300)
    h.model.zoomDeck(by: 2, around: 300)
    let after = try #require(h.model.deckLayout())
    #expect(abs(after.zoom - 2) < 1e-9)
    #expect(abs(after.x(forSource: t) - 300) < 0.01)
    // A resize that lowers the ceiling clamps the zoom to it.
    h.model.deckZoom = after.maxZoom
    h.model.deckResized(width: 2480)
    #expect(h.model.deckZoom == h.model.deckLayout()?.maxZoom)
  }

  /// The app's one scroll monitor hands the deck its events: only inside the deck's frame, no modal on top.
  @Test func scrollWheelOnlyOverTheDeck() async throws {
    let h = try await StageViewTests.reel()
    h.model.deckResized(width: 1240)
    h.model.deckFrameChanged(CGRect(x: 0, y: 730, width: 1240, height: 122))
    #expect(!h.model.deckScrollWheel(dx: 0, dy: 50, command: true, precise: true, at: CGPoint(x: 400, y: 700)))
    #expect(h.model.deckZoom == 1)
    #expect(h.model.deckScrollWheel(dx: 0, dy: 50, command: true, precise: true, at: CGPoint(x: 400, y: 780)))
    #expect(h.model.deckZoom > 1)
    let start = try #require(h.model.deckLayout()).visibleStart
    #expect(h.model.deckScrollWheel(dx: -40, dy: 0, command: false, precise: true, at: CGPoint(x: 400, y: 780)))
    #expect(try #require(h.model.deckLayout()).visibleStart > start, "zoomed, a swipe pans")
    h.model.deckZoom = 1
    #expect(!h.model.deckScrollWheel(dx: -40, dy: 0, command: false, precise: true, at: CGPoint(x: 400, y: 780)),
            "at 1× a plain scroll isn't ours")
    h.model.deckFrameChanged(nil)
    #expect(!h.model.deckScrollWheel(dx: 0, dy: 50, command: true, precise: true, at: CGPoint(x: 400, y: 780)))
  }

  // MARK: media

  /// Peaks (and keyframes, for Quick only) come through `url(for:)`, once each; failures don't repeat forever.
  @Test func deckMediaFetchedOnceThroughTheModel() async throws {
    let h = try await StageViewTests.reel()
    h.media.answerPeaks([0.25, 0.5, 1])
    h.media.answerKeyframes([.zero, RationalTime(1, 1), RationalTime(3, 1)])
    let clip = try #require(h.model.deckClip)
    h.model.requestDeckMedia()
    h.model.requestDeckMedia()
    await h.model.pendingDeckMedia?.value
    #expect(h.media.peakRequests == [try #require(h.model.url(for: clip.id)).path])
    #expect(h.model.deckPeaks[clip.source] == [0.25, 0.5, 1])
    #expect(h.media.keyframeRequests.isEmpty, "Exact needs no keyframes")
    #expect(h.model.keyframeHint == nil)
    var spec = try #require(h.model.reel?.export)
    spec.cut = .quick
    h.model.perform(.setExport(spec), coalesce: nil, record: false)
    h.model.requestDeckMedia()
    h.model.requestDeckMedia()
    await h.model.pendingDeckMedia?.value
    #expect(h.media.keyframeRequests.count == 1)
    #expect(h.media.peakRequests.count == 1)
    #expect(h.model.keyframeHint == "starts at 1.00 s, keyframe", "In is 0:01.21; the cut lands on 1 s")
  }

  @Test func failedDeckMediaRetriesOnceThenStops() async throws {
    let h = try await StageViewTests.reel()
    h.media.answerKeyframes(nil)
    var spec = try #require(h.model.reel?.export)
    spec.cut = .quick
    h.model.perform(.setExport(spec), coalesce: nil, record: false)
    for _ in 0..<4 {
      h.model.requestDeckMedia()
      await h.model.pendingDeckMedia?.value
    }
    #expect(h.media.keyframeRequests.count == EditorModel.deckMediaAttempts)
    #expect(h.model.keyframeHint == nil)
  }

  // MARK: drawing

  static func state(_ c: ReelClip, playhead: RationalTime?, grabbed: DeckLayout.Handle? = nil,
                    keyframes: [RationalTime]? = nil) -> DeckState {
    DeckState(playhead: playhead, grabbed: grabbed, removeAudio: false, keyframes: keyframes,
              keyframeLanding: keyframes.map { KeyframeIndex(times: $0).snappedIn(c.inTime) },
              framesLoading: false, peaksLoading: false, missing: false)
  }

  static func render(_ canvas: DeckCanvas, width: CGFloat = 1240, scale: CGFloat = 2) throws -> CGImage {
    let r = ImageRenderer(content: canvas.frame(width: width, height: DeckCanvas.height).background(Tokens.bg1))
    r.scale = scale
    return try #require(r.cgImage)
  }

  static func close(_ a: [UInt8], _ b: [UInt8], within lsb: Int = 1) -> Bool {
    zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= lsb }
  }

  @Test func pixelColours() throws {
    let c = Self.clip()
    let L = DeckLayout(clip: c, width: 1240, zoom: 1, offset: .zero)
    let peaks = [Float16](repeating: 0.5, count: 1180)
    let image = try Self.render(DeckCanvas(layout: L, sprite: StripLayoutTests.syntheticSprite(), peaks: peaks,
                                           state: Self.state(c, playhead: Self.s(4))))
    let px = try StageViewTests.pixels(image)
    func at(_ x: CGFloat, _ y: CGFloat) -> [UInt8] { StageViewTests.rgb(px, image, x: Int(x * 2), y: Int(y * 2)) }
    let xi = L.x(forSource: c.inTime).rounded(), xo = L.x(forSource: c.outTime).rounded()
    let xp = L.x(forSource: Self.s(4)).rounded()
    let mid = DeckLayout.cap + 30
    #expect(Self.close(at(xi - 2, mid), [0xC9, 0xA8, 0x6A]), "In bracket \(at(xi - 2, mid))")
    #expect(Self.close(at(xo + 1, mid), [0xC9, 0xA8, 0x6A]), "Out bracket")
    #expect(Self.close(at(xp, mid), [0xF2, 0xED, 0xE4]), "playhead \(at(xp, mid))")
    #expect(Self.close(at(xp, 5), [0xF2, 0xED, 0xE4]), "playhead cap")
    #expect(Self.close(at((xi + xo) / 2, DeckLayout.cap), [0xC9, 0xA8, 0x6A]), "span top edge")
    #expect(Self.close(at((xi + xo) / 2, DeckLayout.height - 1), [0xC9, 0xA8, 0x6A]), "span bottom edge")
    #expect(Self.close(at(xi - 10, DeckLayout.cap + 61 - 9 + 1), [0xC9, 0xA8, 0x6A]), "In grab tab")
    // Outside the span sinks under --deck-out: darker than the same frame inside.
    let inside = at(xi + 30, DeckLayout.cap + 20), outside = at(xo + 30, DeckLayout.cap + 20)
    #expect(Int(outside[1]) < Int(inside[1]) / 2, "dimmed outside: \(outside) vs \(inside)")
    // The deck's sides are --bg-1; nothing draws in the rail row at 1×.
    #expect(at(5, 60) == [0x14, 0x16, 0x1A])
    #expect(at(600, DeckLayout.height + 4) == [0x14, 0x16, 0x1A])
  }

  @Test func grabGlowRailAndKeyframes() throws {
    let c = Self.clip()
    let L = DeckLayout(clip: c, width: 1240, zoom: 2, offset: Self.s(0.5))
    let kf: [RationalTime] = [.zero, RationalTime(1, 1), RationalTime(3, 1), RationalTime(5, 1)]
    let image = try Self.render(DeckCanvas(layout: L, sprite: nil, peaks: nil,
                                           state: Self.state(c, playhead: Self.s(4), grabbed: .in, keyframes: kf)))
    let px = try StageViewTests.pixels(image)
    func at(_ x: CGFloat, _ y: CGFloat) -> [UInt8] { StageViewTests.rgb(px, image, x: Int(x * 2), y: Int(y * 2)) }
    let xi = L.x(forSource: c.inTime).rounded()
    // The glow: 1 px around the grabbed bracket, gold over the deck's dark.
    let glow = at(xi - 4 + 0.25, DeckLayout.cap + 30)
    #expect(glow[0] > 0x40 && glow[0] < 0xC9, "glow beside the bar: \(glow)")
    // The rail (zoomed): the kept span runs gold in the bottom 8 px.
    let span = at(L.railX(forSource: c.inTime + RationalTime(1, 1)), DeckLayout.height + 4)
    #expect(span[0] > 0x80 && span[2] < span[0], "rail span is gold: \(span)")
    // Quick: the landing keyframe (1 s) is a gold tick inside the dim; another one is faint ivory.
    let land = at(L.x(forSource: RationalTime(1, 1)).rounded(), DeckLayout.cap + 40)
    #expect(land[0] > land[2] + 30, "landing tick is gold: \(land)")
    let faint = at(L.x(forSource: RationalTime(5, 1)).rounded(), DeckLayout.cap + 40)
    let beside = at(L.x(forSource: RationalTime(5, 1)).rounded() + 3, DeckLayout.cap + 40)
    #expect(Int(faint[0]) > Int(beside[0]), "a faint tick: \(faint) vs \(beside)")
  }

  /// Review M5: v1's span-change glow, ivory at 7 % over the kept span, easing out over 180 ms (1 − e²).
  @Test func spanGlow() throws {
    #expect(DeckGlow.level(elapsed: 0, reduceMotion: false) == 1)
    #expect(abs(DeckGlow.level(elapsed: 0.09, reduceMotion: false) - 0.75) < 1e-9)
    #expect(DeckGlow.level(elapsed: 0.18, reduceMotion: false) == 0)
    #expect(DeckGlow.level(elapsed: -0.01, reduceMotion: false) == 0)
    #expect(DeckGlow.level(elapsed: 0, reduceMotion: true) == 0)

    let c = Self.clip()
    let L = DeckLayout(clip: c, width: 1240, zoom: 1, offset: .zero)
    func px(glow: Double) throws -> ([UInt8], [UInt8]) {
      var state = Self.state(c, playhead: nil, grabbed: .out)
      state.spanGlow = glow
      let image = try Self.render(DeckCanvas(layout: L, sprite: nil, peaks: nil, state: state))
      let p = try StageViewTests.pixels(image)
      let xi = L.x(forSource: c.inTime).rounded(), xo = L.x(forSource: c.outTime).rounded()
      return (StageViewTests.rgb(p, image, x: Int((xi + xo)), y: Int((DeckLayout.cap + 20) * 2)),
              StageViewTests.rgb(p, image, x: Int((xo + 40) * 2), y: Int((DeckLayout.cap + 20) * 2)))
    }
    let (inOff, outOff) = try px(glow: 0)
    let (inOn, outOn) = try px(glow: 1)
    #expect(Int(inOn[0]) > Int(inOff[0]) + 8, "the span lifts: \(inOn) vs \(inOff)")
    #expect(outOn == outOff, "outside the span is untouched")
  }

  @Test func voiceOverLabels() {
    let c = Self.clip()
    #expect(DeckCanvas.value(c) == "In 0:01.21, Out 0:10.07")
  }

  /// §10: the deck draws in under 2 ms (median of ImageRenderer renders at 2×, the playhead moving).
  @Test func deckDrawUnder2ms() throws {
    let c = Self.clip()
    let L = DeckLayout(clip: c, width: 1240, zoom: 1, offset: .zero)
    let sprite = StripLayoutTests.syntheticSprite()
    let peaks = (0..<1180).map { Float16(Double($0 % 17) / 17) }
    func frame(_ k: Int) -> Double {
      let canvas = DeckCanvas(layout: L, sprite: sprite, peaks: peaks,
                              state: Self.state(c, playhead: Self.s(Double(k) / 10)))
      let r = ImageRenderer(content: canvas.frame(width: 1240, height: DeckCanvas.height))
      r.scale = 2
      let t0 = DispatchTime.now().uptimeNanoseconds
      let image = r.cgImage
      let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
      #expect(image != nil)
      return ms
    }
    for k in 0..<5 { _ = frame(k) }
    let times = (0..<31).map { frame(5 + $0) }.sorted()
    let median = times[times.count / 2]
    print(String(format: "deckDrawUnder2ms: median %.3f ms, max %.3f ms over 31 renders", median, times.last ?? 0))
    // §10's 2 ms under TRIMLAB_TIMING=1 (see `Timing`); looser in a parallel run, which loads the machine.
    let limit = Timing.strict ? 2.0 : 8.0
    #expect(median < limit, "median \(median) ms (limit \(limit))")
    // The single slowest sample only under TRIMLAB_TIMING=1 (see `Timing`).
    if Timing.strict { #expect((times.last ?? 0) < 2, "max \(times.last ?? 0) ms") }
  }
}
