import Foundation
import ImageIO
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 34: the deck's caption row (§4.4, §4.3.4): the clip's name and place, Framing Fill | Fit, Crossfade in
/// Cut | Short | Long and the focusable segmented control that carries them.
@MainActor @Suite struct CaptionRowTests {
  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  private func wide() -> ClipFacts {
    var f = StubMedia.facts()
    f.displayWidth = 1920
    f.displayHeight = 1080
    return f
  }

  private func id(_ h: Harness, _ name: String) throws -> UUID {
    try #require(h.model.reel?.clips.first { $0.source.absolutePath.hasSuffix("/" + name) }?.id)
  }

  private func clip(_ h: Harness, _ id: UUID) throws -> ReelClip {
    try #require(h.model.reel?.clips.first { $0.id == id })
  }

  @Test func framingShownOnlyForNon916InReel() async throws {
    let h = Harness()
    h.media.script("w.mov", .facts(wide()))
    await h.importAll(["p.mov", "w.mov"])
    h.model.select(try id(h, "p.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.framing == nil)  // 1080×1920
    h.model.select(try id(h, "w.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.framing == .fill)  // 1920×1080 in Reel
    var spec = try #require(h.model.reel?.export)
    spec.format = .original
    h.model.perform(.setExport(spec), coalesce: nil)
    #expect(h.model.caption?.framing == nil)  // Original
  }

  @Test func crossfadeHiddenOnFirstClip() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.select(try id(h, "a.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.join == nil)
    h.model.select(try id(h, "b.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.join == .cut)
  }

  @Test func tooltipShowsEffective() async throws {
    #expect(CaptionModel.joinTooltip(.cut, effective: .zero) == "Cut")
    #expect(CaptionModel.joinTooltip(.crossfade(Limits.longFade), effective: RationalTime(3, 5))
      == "Crossfade, 0.6\u{00A0}s (clip is short)")
    #expect(CaptionModel.joinTooltip(.crossfade(Limits.longFade), effective: Limits.longFade) == "Crossfade, 1\u{00A0}s")
    // 0.995 s of a Long fade reads "1 s": it doesn't call itself short.
    #expect(CaptionModel.joinTooltip(.crossfade(Limits.longFade), effective: RationalTime(199, 200))
      == "Crossfade, 1\u{00A0}s")
    #expect(CaptionModel.joinTooltip(.crossfade(Limits.shortFade), effective: Limits.shortFade)
      == "Crossfade, 0.25\u{00A0}s")

    // Through the model: Long into a 1.2 s clip, then into an 8 s one.
    let h = Harness()
    h.media.script("short.mov", .facts(StubMedia.facts(RationalTime(6, 5))))
    h.media.script("long.mov", .facts(StubMedia.facts(RationalTime(8, 1))))
    await h.importAll(["a.mov", "short.mov", "long.mov"])
    for name in ["short.mov", "long.mov"] {
      h.model.perform(.setJoin(try id(h, name), .crossfade(Limits.longFade)), coalesce: nil)
    }
    h.model.select(try id(h, "short.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.joinTip == "Crossfade, 0.6\u{00A0}s (clip is short)")
    #expect(h.model.caption?.join == .long)
    h.model.select(try id(h, "long.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.joinTip == "Crossfade, 1\u{00A0}s")
  }

  @Test func segmentedSetsJoin() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    let b = try id(h, "b.mov")
    h.model.select(b, extend: false, toggle: false)
    h.model.captionSetJoin(.short)
    #expect(try clip(h, b).join == .crossfade(RationalTime(1, 4)))
    #expect(h.model.caption?.join == .short)
    h.model.captionSetJoin(.long)
    #expect(try clip(h, b).join == .crossfade(Limits.longFade))
    // Choosing what is already chosen records nothing.
    h.model.captionSetJoin(.long)
    h.model.undo()
    #expect(try clip(h, b).join == .crossfade(Limits.shortFade))
    h.model.undo()
    #expect(try clip(h, b).join == .cut)
  }

  @Test func framingAppliesToSelection() async throws {
    let h = Harness()
    h.media.script("w1.mov", .facts(wide()))
    h.media.script("w2.mov", .facts(wide()))
    await h.importAll(["w1.mov", "w2.mov", "w3.mov"])
    let (w1, w2, w3) = (try id(h, "w1.mov"), try id(h, "w2.mov"), try id(h, "w3.mov"))
    h.model.select(w1, extend: false, toggle: false)
    h.model.select(w2, extend: false, toggle: true)
    h.model.captionSetFraming(.fit)
    #expect(try clip(h, w1).framing == .fit)
    #expect(try clip(h, w2).framing == .fit)
    #expect(try clip(h, w3).framing == .fill)
    #expect(h.model.caption?.framing == .fit)
    h.model.undo()  // one step
    #expect(try clip(h, w1).framing == .fill)
    #expect(try clip(h, w2).framing == .fill)
  }

  @Test func countHiddenForOneClip() async throws {
    let h = Harness()
    await h.importAll(["IMG_4821.MOV"])
    let one = try #require(h.model.caption)
    #expect(one.name == "IMG_4821")
    #expect(one.position == nil)
    #expect(one.selected == nil)
    #expect(one.join == nil)

    await h.importAll(["b.mov", "c.mov", "d.mov"])
    h.model.select(try id(h, "c.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.position == "clip 3 of 4")
    #expect(h.model.caption?.selected == nil)
    h.model.select(try id(h, "d.mov"), extend: true, toggle: false)
    #expect(h.model.caption?.position == "clip 4 of 4")
    #expect(h.model.caption?.selected == "2 clips selected")
  }

  @Test func noCaptionWithoutClips() {
    #expect(Harness().model.caption == nil)
  }

  /// A clip still probing has placeholder facts: its framing and its effective fade aren't known yet.
  @Test func loadingClipGuarded() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.media.script("w.mov", .facts(wide()))
    h.media.hold()
    let task = h.model.importURLs([Harness.url("w.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    let w = try id(h, "w.mov")
    h.model.select(w, extend: false, toggle: false)
    #expect(h.model.loading[w] == .probing)
    h.model.captionSetJoin(.long)  // allowed while loading (Task 26 ruling)
    let loading = try #require(h.model.caption)
    #expect(loading.framing == nil)
    #expect(loading.join == .long)
    #expect(loading.joinTip == "Crossfade, 1\u{00A0}s")  // not "0.5 s (clip is short)" from the 1 s placeholder
    h.media.release()
    await task.value
    #expect(h.model.caption?.framing == .fill)
  }

  /// Review M2: re-picking the shown Framing unifies a mixed selection.
  @Test func framingRepickUnifiesSelection() async throws {
    let h = Harness()
    h.media.script("w1.mov", .facts(wide()))
    h.media.script("w2.mov", .facts(wide()))
    await h.importAll(["w1.mov", "w2.mov"])
    let (w1, w2) = (try id(h, "w1.mov"), try id(h, "w2.mov"))
    h.model.perform(.setFraming([w1], .fit), coalesce: nil)
    h.model.select(w2, extend: false, toggle: false)
    h.model.select(w1, extend: false, toggle: true)  // w1 (Fit) primary, w2 (Fill) also selected
    #expect(h.model.selection.primary == w1)
    #expect(h.model.caption?.framing == .fit)
    h.model.captionSetFraming(.fit)  // the segment already shown
    #expect(try clip(h, w2).framing == .fit)
    // Now uniform: picking it again records nothing.
    h.model.captionSetFraming(.fit)
    h.model.undo()
    #expect(try clip(h, w2).framing == .fill)
    #expect(try clip(h, w1).framing == .fit)
  }

  /// Review I1: a focused control that is hidden (↑ to clip 1 hides Crossfade in) gives the arrows back.
  @Test func hiddenControlGivesArrowsBack() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.select(try id(h, "b.mov"), extend: false, toggle: false)
    h.model.controlFocus(CaptionModel.joinControl, focused: true)
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .pass)
    h.model.select(try id(h, "a.mov"), extend: false, toggle: false)
    #expect(h.model.caption?.join == nil)
    let before = h.model.playhead
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.playhead != before)
    #expect(h.model.arrowControls.isEmpty, "the stale name is dropped")
  }

  /// Review I1: a press on the strip, deck or stage takes focus from the caption controls.
  @Test func pointerPressTakesFocusAway() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.select(try id(h, "b.mov"), extend: false, toggle: false)
    for press in [{ h.model.stripPress(at: CGPoint(x: -100, y: -100)) },
                  { h.model.deckPress(at: CGPoint(x: -100, y: -100)) },
                  { h.model.pointerPressed() }] {
      h.model.controlFocus(CaptionModel.joinControl, focused: true)
      let token = h.model.focusResetToken
      press()
      _ = h.model.stripCancel()
      _ = h.model.deckCancel()
      #expect(h.model.focusResetToken == token + 1)
      let before = h.model.playhead
      #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .swallow)
      #expect(h.model.playhead != before)
      h.model.command(.toReelStart)
    }
  }

  /// Review M1: no pass-through while a strip press or a handle is held.
  @Test func noArrowPassDuringPress() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.selectAndSeek(try id(h, "b.mov"), extend: false, toggle: false)
    h.model.stripResized(width: 1000)
    let b = try #require(h.model.stripLayout().tiles.last?.rect)
    h.model.stripPress(at: CGPoint(x: b.midX, y: b.midY), extend: false, toggle: false)
    h.model.controlFocus(CaptionModel.joinControl, focused: true)
    #expect(h.model.stripPressed != nil)
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) != .pass)
    _ = h.model.stripCancel()
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .pass)
  }

  // MARK: TLSegmented

  @Test func segmentedNeighbourStopsAtEnds() {
    let values: [JoinChoice] = [.cut, .short, .long]
    #expect(TLSegmented<JoinChoice>.neighbour(of: .cut, in: values, by: 1) == .short)
    #expect(TLSegmented<JoinChoice>.neighbour(of: .short, in: values, by: -1) == .cut)
    #expect(TLSegmented<JoinChoice>.neighbour(of: .long, in: values, by: 1) == nil)
    #expect(TLSegmented<JoinChoice>.neighbour(of: .cut, in: values, by: -1) == nil)
  }

  /// ←/→ go to a focused segmented control instead of stepping the playhead; other keys are unchanged.
  @Test func arrowsGoToFocusedSegmented() async throws {
    let h = Harness()
    h.media.script("b.mov", .facts(wide()))
    await h.importAll(["a.mov", "b.mov"])
    h.model.selectAndSeek(try id(h, "b.mov"), extend: false, toggle: false)  // both controls shown
    h.model.controlFocus("caption.join", focused: true)
    let before = h.model.playhead
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .pass)
    #expect(h.model.handleKey(KeyChord(key: .left), isRepeat: true, inTextField: false) == .pass)
    #expect(h.model.playhead == before)
    // ⇧→ still jumps, ↑ still selects: only the plain arrows belong to the control.
    #expect(h.model.handleKey(KeyChord(key: .right, mods: .shift), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.playhead != before)
    // Focus moving between the two controls keeps the arrows; losing it gives them back.
    h.model.controlFocus("caption.framing", focused: true)
    h.model.controlFocus("caption.join", focused: false)
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .pass)
    h.model.controlFocus("caption.framing", focused: false)
    let at = h.model.playhead
    #expect(h.model.handleKey(KeyChord(key: .right), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.playhead != at)
  }

  /// The caption's compact size: a 22 px well, 2 px padding, 52 px segments (the sheet's: 28 px, 90 px).
  @Test func segmentedSizes() throws {
    func size(_ s: TLSegmented<JoinChoice>.Size) throws -> (Int, Int) {
      let view = TLSegmented(options: [(JoinChoice.cut, "Cut"), (.short, "Short"), (.long, "Long")],
                             selection: .short, size: s, onSelect: { _ in }).fixedSize()
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      let image = try #require(renderer.cgImage)
      return (image.width, image.height)
    }
    #expect(try size(.compact) == (2 * (3 * 52 + 4), 2 * 22))
    #expect(try size(.regular) == (2 * (3 * 90 + 4), 2 * 28))
  }

  /// The row renders at 28 px with every control in (a wide clip 2 of 2, Long into it).
  @Test func rowRenders() async throws {
    let h = Harness()
    h.media.script("w.mov", .facts(wide()))
    await h.importAll(["IMG_4821.MOV", "w.mov"])
    let w = try id(h, "w.mov")
    h.model.select(w, extend: false, toggle: false)
    h.model.captionSetJoin(.long)
    let renderer = ImageRenderer(content: CaptionRow(model: h.model).padding(.horizontal, 20)
      .frame(width: 1240, height: 28).background(Tokens.bg1))
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    #expect(image.width == 2480 && image.height == 56)
    if let out = ProcessInfo.processInfo.environment["TRIMLAB_CAPTION_PNG"],
       let dest = CGImageDestinationCreateWithURL(URL(filePath: out) as CFURL, "public.png" as CFString, 1, nil) {
      CGImageDestinationAddImage(dest, image, nil)
      CGImageDestinationFinalize(dest)
    }
  }
}
