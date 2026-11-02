import CoreGraphics
import Foundation
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 33: the deck's pointer intents (§4.2, §4.4): handle drags on a draft, snap, peek and scrub, one undo step a
/// drag. The mockup's 18-clip Reel (`StageViewTests.reel()`): clip 4 (IMG_4821, 23.6 s at 29.97, kept
/// 0:01.21 – 0:10.07) is the primary, on a 1240 px deck (timeline 20 … 1220, 50.8 px a second).
@MainActor @Suite struct DeckInteractionTests {
  static let width: CGFloat = 1240
  /// The filmstrip's middle row.
  static let row = DeckLayout.cap + 30

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  private func reel() async throws -> (Harness, ReelClip) {
    let h = try await StageViewTests.reel()
    h.model.deckResized(width: Self.width)
    return (h, try #require(h.model.deckClip))
  }

  private func layout(_ h: Harness) throws -> DeckLayout { try #require(h.model.deckLayout()) }

  /// The handle's grab tab, where a press picks it up.
  private func tab(_ h: Harness, _ handle: DeckLayout.Handle) throws -> CGPoint {
    let L = try layout(h)
    let x = handle == .in ? L.x(forSource: L.inTime) - 6 : L.x(forSource: L.outTime) + 6
    return CGPoint(x: x, y: Self.row)
  }

  private func placement(_ h: Harness, _ id: UUID) throws -> Placement {
    try #require(h.model.plan?.placements.first { $0.clipID == id })
  }

  private func undoDepth(_ h: Harness) -> Int {
    var history = h.model.history
    var n = 0
    var current = (h.model.reel!, h.model.selection)
    while let step = history.undo(current: current) { current = step; n += 1 }
    return n
  }

  // MARK: the brief's eight

  /// A click past Out peeks that frame, parks the Reel playhead on the last kept frame, and O then trims to it.
  @Test func clickPastOutPeeks() async throws {
    let (h, clip) = try await reel()
    let L = try layout(h)
    let want = clip.outTime + RationalTime(2, 1)
    let p = CGPoint(x: L.x(forSource: want), y: Self.row)
    #expect(L.handle(at: p) == nil)
    h.model.deckPress(at: p)
    h.model.deckRelease()
    let peek = try #require(h.model.peek)
    #expect(peek.clipID == clip.id)
    #expect(abs((peek.sourceTime - want).seconds) <= clip.facts.frameDuration.seconds)
    #expect(peek.sourceTime == peek.sourceTime.floored(toFrame: clip.facts.frameDuration), "on a frame")
    let span = try placement(h, clip.id).reelSpan
    #expect(h.model.playhead == span.start + (clip.outTime - clip.facts.frameDuration - clip.inTime),
            "parked on the last kept frame")
    #expect(h.model.deckSourcePlayhead == peek.sourceTime, "the deck playhead is at the click")
    h.model.command(.setOut)
    #expect(h.model.reel?.clips.first { $0.id == clip.id }?.outTime == peek.sourceTime)
  }

  /// 30 drag events are one undo step, which restores the old In.
  @Test func dragIsOneUndoStep() async throws {
    let (h, clip) = try await reel()
    let depth = undoDepth(h)
    let start = try tab(h, .in)
    h.model.deckPress(at: start)
    for i in 1...30 { h.model.deckDrag(to: CGPoint(x: start.x + CGFloat(i) * 4, y: Self.row), option: true) }
    h.model.deckRelease()
    let moved = try #require(h.model.reel?.clips.first { $0.id == clip.id })
    #expect(moved.inTime > clip.inTime)
    #expect(undoDepth(h) == depth + 1)
    #expect(h.model.draftReel == nil)
    h.model.undo()
    #expect(h.model.reel?.clips.first { $0.id == clip.id }?.inTime == clip.inTime)
    // The next drag is a new step (`endGesture` after the release).
    h.model.redo()
    let again = try tab(h, .in)
    h.model.deckPress(at: again)
    h.model.deckDrag(to: CGPoint(x: again.x + 30, y: Self.row), option: true)
    h.model.deckRelease()
    #expect(undoDepth(h) == depth + 2)
  }

  /// During a drag the total, the strip and the clip read the draft; the Reel changes only on release.
  @Test func draftUpdatesTotalLive() async throws {
    let (h, clip) = try await reel()
    let before = try #require(h.model.reel)
    let total = h.model.displayTotal
    #expect(total == h.model.plan?.total)
    let start = try tab(h, .out)
    h.model.deckPress(at: start)
    #expect(h.model.deckGrab == .out)
    h.model.deckDrag(to: CGPoint(x: start.x - 100, y: Self.row), option: true)
    let draft = try #require(h.model.draftReel?.clips.first { $0.id == clip.id })
    #expect(draft.outTime < clip.outTime)
    #expect(h.model.reel == before, "nothing commits during the drag")
    #expect(h.model.displayTotal == total - (clip.outTime - draft.outTime))
    #expect(h.model.deckClip?.outTime == draft.outTime, "the deck draws the draft")
    let tile = try #require(h.model.stripLayout(width: 1240).tiles.first { $0.id == clip.id })
    let committed = StripLayout(plan: try #require(h.model.plan), clips: before.clips, width: 1240, zoom: .fit,
                                scrollX: 0, format: before.export.format)
    let old = try #require(committed.tiles.first { $0.id == clip.id })
    #expect(tile.rect.width < old.rect.width, "the strip draws the draft")
    h.model.deckRelease()
    #expect(h.model.reel?.clips.first { $0.id == clip.id }?.outTime == draft.outTime)
    #expect(h.model.displayTotal == h.model.plan?.total)
  }

  /// A handle stops at the 0.5 s minimum span and never crosses the other; no note, no throw.
  @Test func handleStopsAtMinSpan() async throws {
    let (h, clip) = try await reel()
    let fd = clip.facts.frameDuration
    let start = try tab(h, .in)
    h.model.deckPress(at: start)
    h.model.deckDrag(to: CGPoint(x: 1200, y: Self.row), option: true)
    var draft = try #require(h.model.deckClip)
    #expect(draft.outTime == clip.outTime)
    #expect(draft.outTime - draft.inTime >= Limits.minSpan)
    #expect(draft.outTime - draft.inTime < Limits.minSpan + fd)
    h.model.deckDrag(to: CGPoint(x: Self.width + 300, y: Self.row), option: true)
    #expect(h.model.deckClip == draft, "the handle stays stopped")
    h.model.deckRelease()
    #expect(h.model.notes.isEmpty)
    #expect(h.model.reel?.clips.first { $0.id == clip.id } == draft)

    let out = try tab(h, .out)
    h.model.deckPress(at: out)
    h.model.deckDrag(to: CGPoint(x: -200, y: Self.row), option: true)
    draft = try #require(h.model.deckClip)
    #expect(draft.outTime - draft.inTime >= Limits.minSpan)
    #expect(draft.outTime - draft.inTime < Limits.minSpan + fd)
    h.model.deckRelease()
    #expect(h.model.notes.isEmpty)
  }

  /// Release commits and the playhead returns to the clip's In, peek gone; a press that didn't move does too.
  @Test func releaseReturnsPlayheadToIn() async throws {
    let (h, clip) = try await reel()
    let start = try tab(h, .out)
    h.model.deckPress(at: start)
    #expect(h.model.peek != nil, "the stage shows the handle's frame")
    #expect(h.model.peek?.sourceTime == clip.outTime - clip.facts.frameDuration)
    h.model.deckDrag(to: CGPoint(x: start.x + 80, y: Self.row), option: true)
    #expect(h.model.peek?.sourceTime == (h.model.deckClip?.outTime ?? .zero) - clip.facts.frameDuration)
    h.model.deckRelease()
    #expect(h.model.peek == nil)
    #expect(h.model.deckGrab == nil)
    #expect(h.model.playhead == (try placement(h, clip.id)).reelSpan.start)
    // No movement: nothing commits, the playhead still goes to In.
    h.model.seek(reelTime: (try placement(h, clip.id)).reelSpan.start + RationalTime(2, 1))
    let depth = undoDepth(h)
    h.model.deckPress(at: try tab(h, .in))
    h.model.deckRelease()
    #expect(undoDepth(h) == depth)
    #expect(h.model.playhead == (try placement(h, clip.id)).reelSpan.start)
  }

  /// Space from peek plays from the selected clip's In.
  @Test func spaceFromPeekPlaysFromIn() async throws {
    let (h, clip) = try await reel()
    let L = try layout(h)
    h.model.deckPress(at: CGPoint(x: L.x(forSource: RationalTime(15, 1)), y: Self.row))
    h.model.deckRelease()
    #expect(h.model.peek != nil)
    #expect(h.model.handleKey(KeyChord(key: .space), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.peek == nil)
    #expect(h.model.isPlaying)
    #expect(h.model.playhead == (try placement(h, clip.id)).reelSpan.start)
  }

  /// I, O, S and the resets wait while a handle is held, and work again once it's let go.
  @Test func trimKeysWaitDuringDrag() async throws {
    let (h, clip) = try await reel()
    h.model.deckPress(at: try tab(h, .in))
    #expect(h.model.keyContext.dragging)
    let before = h.model.reel
    for c in ["i", "o", "s"] {
      #expect(h.model.handleKey(KeyChord(key: .char(Character(c))), isRepeat: false, inTextField: false) == .swallow)
    }
    #expect(h.model.reel == before)
    #expect(h.model.deckGrab == .in, "still held")
    h.model.deckRelease()
    #expect(!h.model.keyContext.dragging)
    h.model.seek(reelTime: (try placement(h, clip.id)).reelSpan.start + RationalTime(1, 1))
    _ = h.model.handleKey(KeyChord(key: .char("i")), isRepeat: false, inTextField: false)
    #expect(h.model.reel?.clips.first { $0.id == clip.id }?.inTime != clip.inTime)
  }

  /// The stage's 9:16 guide shows in peek only for a wider clip that is Fill in a Reel-format export.
  @Test func peekGuideOnlyForFillInReel() async throws {
    let h = Harness()
    var wide = StageViewTests.clip("wide.mov", duration: RationalTime(10, 1)).facts
    wide.displayWidth = 1920
    wide.displayHeight = 1080
    h.media.script("wide.mov", .facts(wide))
    await h.importAll(["wide.mov"])
    let id = try #require(h.model.reel?.clips.first?.id)
    h.model.select(id, extend: false, toggle: false)
    #expect(!h.model.stageGuideVisible, "no guide outside peek")
    h.model.peek(sourceTime: RationalTime(2, 1))
    h.model.perform(.setFraming([id], .fill), coalesce: nil)
    h.model.peek(sourceTime: RationalTime(2, 1))
    var spec = try #require(h.model.reel?.export)
    spec.format = .reel
    h.model.perform(.setExport(spec), coalesce: nil, record: false)
    #expect(h.model.stageGuideVisible, "Fill in a Reel")
    h.model.perform(.setFraming([id], .fit), coalesce: nil)
    h.model.peek(sourceTime: RationalTime(2, 1))
    #expect(!h.model.stageGuideVisible, "Fit")
    h.model.perform(.setFraming([id], .fill), coalesce: nil)
    h.model.peek(sourceTime: RationalTime(2, 1))
    spec.format = .original
    h.model.perform(.setExport(spec), coalesce: nil, record: false)
    #expect(!h.model.stageGuideVisible, "Original")
  }

  // MARK: snap, scrub, margin, cancel

  /// A handle within 6 px of the playhead lands on it; ⌥ lets it go past.
  @Test func handleSnapsToPlayhead() async throws {
    let (h, clip) = try await reel()
    let L = try layout(h)
    let playhead = try #require(h.model.deckSourcePlayhead)
    let xp = L.x(forSource: playhead)
    let start = try tab(h, .in)
    h.model.deckPress(at: start)
    #expect(h.model.deckSourcePlayhead == playhead, "the deck playhead stays put while a handle is held")
    // The pointer keeps its offset from the bar: aim the bar 4 px short of the playhead.
    let barToTab = start.x - L.x(forSource: clip.inTime)
    h.model.deckDrag(to: CGPoint(x: xp - 4 + barToTab, y: Self.row), option: false)
    #expect(h.model.deckClip?.inTime == playhead)
    h.model.deckDrag(to: CGPoint(x: xp - 4 + barToTab, y: Self.row), option: true)
    #expect(h.model.deckClip?.inTime != playhead)
    h.model.deckRelease()
  }

  /// A click inside the span moves the Reel playhead there (no peek); dragging scrubs; the selection stays.
  @Test func clickInsideSpanSeeks() async throws {
    let (h, clip) = try await reel()
    let L = try layout(h)
    let span = try placement(h, clip.id).reelSpan
    let t = clip.inTime + RationalTime(3, 1)
    h.model.play()
    h.model.deckPress(at: CGPoint(x: L.x(forSource: t), y: Self.row))
    #expect(!h.model.isPlaying, "a press pauses")
    #expect(h.model.peek == nil)
    let landed = h.model.playhead - span.start + clip.inTime
    #expect(abs((landed - t).seconds) <= clip.facts.frameDuration.seconds)
    // Scrub out past Out: peek; back in: the Reel again.
    h.model.deckDrag(to: CGPoint(x: L.x(forSource: clip.outTime + RationalTime(1, 1)), y: Self.row), option: false)
    #expect(h.model.peek != nil)
    h.model.deckDrag(to: CGPoint(x: L.x(forSource: t), y: Self.row), option: false)
    #expect(h.model.peek == nil)
    h.model.deckRelease()
    #expect(h.model.selection.primary == clip.id)
    #expect(h.model.reel?.clips.first { $0.id == clip.id } == clip, "a scrub trims nothing")
  }

  /// Ruling (v1 wins): the 20 px margins belong to the deck. A handle at the clip's very start owns its tab there;
  /// elsewhere a press in the margin goes to the nearest end of the source.
  @Test func marginBelongsToTheDeck() async throws {
    let (h, clip) = try await reel()
    h.model.perform(.resetIn(clip.id), coalesce: nil)
    #expect(try layout(h).handle(at: CGPoint(x: 10, y: Self.row)) == .in, "In at 0: its tab sits in the margin")
    h.model.deckPress(at: CGPoint(x: Self.width - 4, y: Self.row))
    h.model.deckRelease()
    let fd = clip.facts.frameDuration
    let floor = clip.facts.duration.floored(toFrame: fd)
    let last = floor < clip.facts.duration ? floor : floor - fd
    #expect(h.model.peek?.sourceTime == last, "the last source frame, on the frame grid")
  }

  /// Esc during a handle drag drops the draft: nothing commits.
  @Test func escapeCancelsADrag() async throws {
    let (h, clip) = try await reel()
    let depth = undoDepth(h)
    let start = try tab(h, .in)
    h.model.deckPress(at: start)
    h.model.deckDrag(to: CGPoint(x: start.x + 60, y: Self.row), option: true)
    #expect(h.model.command(.escape))
    #expect(h.model.draftReel == nil)
    #expect(h.model.deckGrab == nil)
    h.model.deckRelease()
    #expect(undoDepth(h) == depth)
    #expect(h.model.reel?.clips.first { $0.id == clip.id } == clip)
  }

  /// A clip still loading can't be trimmed: its handles don't pick up, with the loading note.
  @Test func loadingClipHandlesWait() async throws {
    let h = Harness()
    h.media.hold()
    let task = h.model.importURLs([Harness.url("slow.mov")], at: nil)
    #expect(await h.media.waitForProbes(1))
    let id = try #require(h.model.reel?.clips.first?.id)
    #expect(h.model.loadingClipIDs.contains(id))
    h.model.select(id, extend: false, toggle: false)
    h.model.deckResized(width: Self.width)
    h.model.deckPress(at: try tab(h, .in))
    #expect(h.model.deckGrab == nil)
    #expect(h.model.draftReel == nil)
    #expect(h.noteTexts.last == "Wait for slow.mov to finish loading.")
    h.model.deckRelease()
    h.media.release()
    await task.value
  }

  /// The floating timecode reads the held handle's time.
  @Test func floatingTimecode() async throws {
    let (h, clip) = try await reel()
    #expect(h.model.deckHandleTimecode == nil)
    h.model.deckPress(at: try tab(h, .in))
    #expect(h.model.deckHandleTimecode == "0:01.21")
    h.model.deckRelease()
    h.model.deckPress(at: try tab(h, .out))
    #expect(h.model.deckHandleTimecode == Formatting.timecode(clip.outTime, frame: clip.facts.frameDuration))
    h.model.deckRelease()
  }

  // MARK: Task 33 review fixes

  /// Another primary mid-drag drops the press and its draft: nothing commits, trim keys work again.
  @Test func selectionChangeMidDragClearsTheDraft() async throws {
    let (h, clip) = try await reel()
    let depth = undoDepth(h)
    let start = try tab(h, .in)
    h.model.deckPress(at: start)
    h.model.deckDrag(to: CGPoint(x: start.x + 60, y: Self.row), option: true)
    #expect(h.model.draftReel != nil)
    h.model.command(.selectNext)
    #expect(h.model.draftReel == nil)
    #expect(h.model.deckGrab == nil)
    #expect(!h.model.keyContext.dragging)
    h.model.deckRelease()
    #expect(undoDepth(h) == depth)
    #expect(h.model.reel?.clips.first { $0.id == clip.id } == clip)
  }

  /// A change to the Reel mid-drag (here a join elsewhere) shows up in the draft, which keeps the held trim.
  @Test func reelChangeMidDragRefreshesTheDraft() async throws {
    let (h, clip) = try await reel()
    let ids = try #require(h.model.reel?.clips.map(\.id))
    let start = try tab(h, .in)
    h.model.deckPress(at: start)
    h.model.deckDrag(to: CGPoint(x: start.x + 60, y: Self.row), option: true)
    let held = try #require(h.model.deckClip)
    #expect(held.inTime > clip.inTime)
    h.model.perform(.setJoin(ids[1], .crossfade(Limits.shortFade)), coalesce: nil, record: false)
    let draft = try #require(h.model.draftReel)
    #expect(draft.clips[1].join == .crossfade(Limits.shortFade), "the draft has the new join")
    #expect(draft.clips.first { $0.id == clip.id }?.inTime == held.inTime, "and still the held In")
    #expect(h.model.displayTotal == Planner.plan(draft, missing: h.model.missing).total)
    h.model.deckRelease()
    #expect(h.model.reel?.clips.first { $0.id == clip.id }?.inTime == held.inTime)
    #expect(h.model.reel?.clips[1].join == .crossfade(Limits.shortFade))
  }

  /// Space (and J / L) do nothing while a handle is held.
  @Test func spaceIgnoredDuringGrab() async throws {
    let (h, _) = try await reel()
    h.model.deckPress(at: try tab(h, .out))
    let peek = h.model.peek
    _ = h.model.handleKey(KeyChord(key: .space), isRepeat: false, inTextField: false)
    h.model.command(.shuttle(.forward))
    #expect(!h.model.isPlaying)
    #expect(h.model.peek == peek, "the stage still shows the handle's frame")
    h.model.deckRelease()
    h.model.command(.playPause)
    #expect(h.model.isPlaying)
  }

  /// The Out handle peeks at the last kept frame, also when Out is the duration off the frame grid.
  @Test func outHandlePeeksLastKeptFrame() async throws {
    let (h, clip) = try await reel()
    h.model.perform(.resetOut(clip.id), coalesce: nil)
    let fd = clip.facts.frameDuration
    h.model.deckPress(at: try tab(h, .out))
    let floor = clip.facts.duration.floored(toFrame: fd)
    #expect(floor < clip.facts.duration, "23.6 s is off the 29.97 grid")
    #expect(h.model.peek?.sourceTime == floor)
    h.model.deckRelease()
  }

  // MARK: Task 32 review carries

  /// At frame level x ↔ source round-trips to the frame, and zooming all the way back is the whole clip again.
  @Test func maxZoomRoundTrip() async throws {
    let (h, _) = try await reel()
    for _ in 0..<30 { h.model.deckZoomStep(1) }
    let deep = try layout(h)
    #expect(abs(deep.zoom - deep.maxZoom) < 1e-9)
    for x in stride(from: CGFloat(20), through: 1220, by: 97) {
      #expect(abs(deep.x(forSource: deep.source(at: x)) - x) < 0.01)
    }
    let t = deep.visibleStart + deep.frameDuration * 3
    #expect(abs(deep.source(at: deep.x(forSource: t)).seconds - t.seconds) < 1e-4)
    for _ in 0..<30 { h.model.deckZoomStep(-1) }
    let back = try layout(h)
    #expect(back.zoom == 1)
    #expect(back.visibleStart == .zero)
    #expect(h.model.deckOffset == .zero)
    #expect(abs(back.visibleDuration - back.duration.seconds) < 1e-9)
  }

  /// The waveform is `--wave` at 85 %; Remove audio drops it to 20 %, through the model.
  @Test func waveformDimsWithRemoveAudio() async throws {
    let (h, clip) = try await reel()
    h.model.deckPeaks[clip.source] = [Float16](repeating: 1, count: 1180)
    func brightest() throws -> Int {
      let image = try DeckLayoutTests.render(TrimDeckView.canvas(h.model, width: Self.width))
      let px = try StageViewTests.pixels(image)
      // Inside the kept span (x 300 – 320), 10 px above the waveform's centre line.
      let y = Int((DeckLayout.cap + DeckLayout.film + DeckLayout.gap + DeckLayout.wave / 2 - 10) * 2)
      return (600..<640).map { StageViewTests.rgb(px, image, x: $0, y: y).map(Int.init).max() ?? 0 }.max() ?? 0
    }
    let on = try brightest()
    #expect(TrimDeckView.canvas(h.model, width: Self.width).state.removeAudio == false)
    h.model.toggleRemoveAudio()
    #expect(TrimDeckView.canvas(h.model, width: Self.width).state.removeAudio == true)
    let off = try brightest()
    h.model.deckPeaks[clip.source] = [Float16](repeating: 0, count: 1180)
    let bg = try brightest()  // silence: only the baseline, so the body under the waveform
    #expect(on > off + 40, "85 % vs 20 %: \(on) vs \(off)")
    #expect(off > bg, "still drawn at 20 %: \(off)")
  }

  /// Exact (the default cut) draws no keyframe ticks even with keyframes in, zoomed or not.
  @Test func exactDrawsNoTicks() async throws {
    let (h, clip) = try await reel()
    h.model.deckKeyframes[clip.source] = KeyframeIndex(times: [.zero, RationalTime(1, 1), RationalTime(5, 1)])
    h.model.deckZoom = 2
    #expect(h.model.reel?.export.cut != .quick)
    let canvas = TrimDeckView.canvas(h.model, width: Self.width)
    #expect(canvas.state.keyframes == nil)
    #expect(canvas.state.keyframeLanding == nil)
    // Drawn with no media (nothing loading, so no shimmer), the model's Exact state has no tick where a Quick
    // state with the same keyframes draws one.
    let L = try layout(h)
    var exact = canvas.state
    exact.framesLoading = false
    exact.peaksLoading = false
    var quick = exact
    quick.keyframes = [.zero, RationalTime(1, 1), RationalTime(5, 1)]
    quick.keyframeLanding = .zero
    func pixel(_ state: DeckState, x: CGFloat) throws -> [UInt8] {
      let image = try DeckLayoutTests.render(DeckCanvas(layout: L, sprite: nil, peaks: nil, state: state))
      return StageViewTests.rgb(try StageViewTests.pixels(image), image, x: Int(x * 2),
                                y: Int((DeckLayout.cap + 40) * 2))
    }
    let x = L.x(forSource: RationalTime(5, 1)).rounded()
    #expect(x > 20 && x < 1220, "the tick's time is in view")
    #expect(try pixel(quick, x: x) != pixel(quick, x: x + 3), "Quick draws a tick there")
    #expect(try pixel(exact, x: x) == pixel(exact, x: x + 3), "Exact draws none")
  }

  /// ⌘-scroll over the deck zooms the deck and leaves the strip's zoom alone.
  @Test func deckScrollLeavesStripZoom() async throws {
    let (h, _) = try await reel()
    h.model.stripResized(width: 1240)
    h.model.stripFrameChanged(CGRect(x: 0, y: 600, width: 1240, height: 80))
    h.model.deckFrameChanged(CGRect(x: 0, y: 730, width: 1240, height: 130))
    let p = CGPoint(x: 400, y: 780)
    #expect(!h.model.stripScrollWheel(dx: 0, dy: 50, command: true, precise: true, at: p))
    #expect(h.model.deckScrollWheel(dx: 0, dy: 50, command: true, precise: true, at: p))
    #expect(h.model.deckZoom > 1)
    #expect(h.model.stripZoom == .fit)
    #expect(h.model.stripScrollX == 0)
  }

  /// Review M4: a drag peeks on every event; the hidden Reel player seeks only when the parked frame moves.
  @Test func peekSeeksOnlyWhenParkedFrameMoves() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    let id = try #require(h.model.reel?.clips.first?.id)
    h.model.select(id, extend: false, toggle: false)
    h.model.perform(.setOut(id, RationalTime(5, 1)), coalesce: nil)
    h.model.peek(sourceTime: RationalTime(6, 1))  // past Out: parked on the last kept frame
    await h.model.pendingSeek?.value
    let seeks = h.preview.seeks.count
    h.model.peek(sourceTime: RationalTime(7, 1))  // still past Out: the same parked frame
    h.model.peek(sourceTime: RationalTime(8, 1))
    await h.model.pendingSeek?.value
    #expect(h.preview.seeks.count == seeks)
    h.model.peek(sourceTime: RationalTime(2, 1))  // inside: the parked frame moves
    await h.model.pendingSeek?.value
    #expect(h.preview.seeks.count == seeks + 1)
    #expect(h.preview.seeks.last == h.model.playhead)
  }
}
