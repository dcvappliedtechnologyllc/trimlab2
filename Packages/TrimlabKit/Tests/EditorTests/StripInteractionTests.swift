import CoreGraphics
import Foundation
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 29: the strip's pointer intents (§4.3.2–4.3.5), hit-tested in the model. Five 10 s clips a…e at 29.97 on a
/// 1000 px strip unless a test says otherwise: in Fit each tile is 198.4 px with 2 px gaps.
@MainActor @Suite struct StripInteractionTests {
  static let row = Tokens.Layout.stripCap + Tokens.Layout.stripTile / 2

  private func five(width: CGFloat = 1000) async throws -> (Harness, [UUID]) {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov", "c.mov", "d.mov", "e.mov"])
    await h.model.pendingPreview?.value
    h.model.stripResized(width: width)
    let ids = try #require(h.model.reel?.clips.map(\.id))
    try #require(ids.count == 5)
    return (h, ids)
  }

  private func centre(_ h: Harness, _ i: Int) -> CGPoint {
    let r = h.model.stripLayout().tiles[i].rect
    return CGPoint(x: r.midX, y: Self.row)
  }

  /// The middle of the gap (or overlap) before tile `i`.
  private func join(_ h: Harness, _ i: Int) -> CGPoint {
    let tiles = h.model.stripLayout().tiles
    let t = tiles[i]
    if t.overlapLeft > 0 { return CGPoint(x: t.rect.minX + t.overlapLeft / 2, y: Self.row) }
    return CGPoint(x: (tiles[i - 1].rect.maxX + t.rect.minX) / 2, y: Self.row)
  }

  private func drag(_ h: Harness, from a: CGPoint, to b: CGPoint, extend: Bool = false, toggle: Bool = false) {
    h.model.stripPress(at: a, extend: extend, toggle: toggle)
    h.model.stripDrag(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    h.model.stripDrag(to: b)
    h.model.stripRelease()
  }

  private func undoDepth(_ h: Harness) -> Int {
    var history = h.model.history
    var n = 0
    var current = (h.model.reel!, h.model.selection)
    while let step = history.undo(current: current) { current = step; n += 1 }
    return n
  }

  // MARK: click and select

  @Test func pressUnderThresholdIsClick() async throws {
    let (h, ids) = try await five()
    let before = h.model.reel
    let depth = undoDepth(h)
    let p = centre(h, 2)
    h.model.stripPress(at: p, extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: p.x + 3, y: p.y))
    #expect(h.model.activeDrag == nil, "3 px is under the 4 px threshold")
    h.model.stripRelease()
    #expect(h.model.selection == Selection(primary: ids[2], all: [ids[2]]))
    #expect(h.model.playhead == RationalTime(20, 1), "the playhead goes to the clip's In")
    #expect(h.model.reel == before)
    #expect(undoDepth(h) == depth)
  }

  @Test func shiftClickExtendsCmdClickToggles() async throws {
    let (h, ids) = try await five()
    func click(_ i: Int, extend: Bool = false, toggle: Bool = false) {
      h.model.stripPress(at: centre(h, i), extend: extend, toggle: toggle)
      h.model.stripRelease()
    }
    click(1)
    click(3, extend: true)
    #expect(h.model.selection.all == Set(ids[1...3]))
    #expect(h.model.selection.primary == ids[3])
    click(2, toggle: true)
    #expect(h.model.selection.all == [ids[1], ids[3]])
    click(4, toggle: true)
    #expect(h.model.selection.all == [ids[1], ids[3], ids[4]])
    #expect(h.model.selection.primary == ids[4])
    #expect(h.model.playhead == RationalTime(40, 1))
  }

  // MARK: reorder

  @Test func dragReordersSelection() async throws {
    let (h, ids) = try await five()
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.select(ids[3], extend: false, toggle: true)
    let depth = undoDepth(h)
    let a = centre(h, 1)
    h.model.stripPress(at: a, extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: 6, y: Self.row))
    let drag = try #require(h.model.activeDrag)
    #expect(drag.kind == .reorder([ids[1], ids[3]]))
    #expect(drag.caretGap == 0)
    h.model.stripRelease()
    #expect(h.model.reel?.clips.map(\.id) == [ids[1], ids[3], ids[0], ids[2], ids[4]])
    #expect(h.model.activeDrag == nil)
    #expect(undoDepth(h) == depth + 1, "a move is one step")
    h.model.undo()
    #expect(h.model.reel?.clips.map(\.id) == ids)
  }

  @Test func dragUnselectedTileMovesItAlone() async throws {
    let (h, ids) = try await five()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.select(ids[1], extend: false, toggle: true)
    drag(h, from: centre(h, 3), to: CGPoint(x: 995, y: Self.row))
    #expect(h.model.reel?.clips.map(\.id) == [ids[0], ids[1], ids[2], ids[4], ids[3]])
    #expect(h.model.selection.primary == ids[3])
  }

  @Test func dropAtStartRecordsNothing() async throws {
    let (h, ids) = try await five()
    let depth = undoDepth(h)
    let tiles = h.model.stripLayout().tiles
    // Either side of the dragged tile is where it started.
    for x in [tiles[2].rect.minX + 1, tiles[2].rect.maxX - 1, tiles[2].rect.midX] {
      h.model.stripPress(at: centre(h, 2), extend: false, toggle: false)
      h.model.stripDrag(to: CGPoint(x: centre(h, 2).x + 30, y: Self.row))
      h.model.stripDrag(to: CGPoint(x: x, y: Self.row))
      #expect(h.model.activeDrag != nil)
      h.model.stripRelease()
      #expect(h.model.reel?.clips.map(\.id) == ids)
      #expect(undoDepth(h) == depth)
    }
  }

  @Test func escCancelsDrag() async throws {
    let (h, ids) = try await five()
    h.model.stripPress(at: centre(h, 1), extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: 990, y: Self.row))
    #expect(h.model.activeDrag != nil)
    #expect(h.model.stripCancel())
    #expect(h.model.activeDrag == nil)
    h.model.stripRelease()
    #expect(h.model.reel?.clips.map(\.id) == ids)
    #expect(!h.model.stripCancel(), "nothing left to cancel")
  }

  /// T26 ruling: moves don't wait for a probe.
  @Test func moveAllowedWhileProbing() async throws {
    let h = Harness()
    h.media.hold()
    let task = h.model.importURLs(["a.mov", "b.mov", "c.mov"].map { Harness.url($0) }, at: nil)
    #expect(await h.media.waitForProbes(3))
    h.model.stripResized(width: 1000)
    let ids = try #require(h.model.reel?.clips.map(\.id))
    #expect(h.model.loadingClipIDs.count == 3)
    drag(h, from: centre(h, 2), to: CGPoint(x: 4, y: Self.row))
    #expect(h.model.reel?.clips.map(\.id) == [ids[2], ids[0], ids[1]])
    h.media.release()
    await task.value
  }

  // MARK: auto-scroll and paging

  @Test func autoScrollNearEdge() async throws {
    let (h, _) = try await five(width: 400)
    h.model.stripZoom = .pxPerSecond(100)
    #expect(h.model.stripScrollX == 0)
    h.model.stripPress(at: centre(h, 0), extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: 395, y: Self.row))
    var last = h.model.stripScrollX
    for _ in 0..<3 {
      let tick = try #require(h.model.pendingAutoScroll)
      h.clock.advance(by: StripDrag.autoScrollTick)
      await tick.value
      #expect(h.model.stripScrollX > last)
      last = h.model.stripScrollX
    }
    #expect(h.model.activeDrag?.caretGap == h.model.stripLayout().gap(at: 395))
    // Out of the edge zone the scrolling stops.
    let leaving = h.model.pendingAutoScroll
    h.model.stripDrag(to: CGPoint(x: 200, y: Self.row))
    #expect(h.model.pendingAutoScroll == nil, "out of the zone: no tick waiting")
    h.clock.advance(by: StripDrag.autoScrollTick)
    await leaving?.value  // the tick that was waiting has stood down
    #expect(h.model.stripScrollX == last)

    // Back in the zone, then released: nothing left ticking. The same after a cancel.
    h.model.stripDrag(to: CGPoint(x: 395, y: Self.row))
    #expect(h.model.pendingAutoScroll != nil)
    h.model.stripRelease()
    #expect(h.model.pendingAutoScroll == nil)
    h.model.stripPress(at: centre(h, 1), extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: 395, y: Self.row))
    let cancelled = h.model.pendingAutoScroll
    #expect(cancelled != nil)
    #expect(h.model.stripCancel())
    #expect(h.model.pendingAutoScroll == nil)
    let scrolled = h.model.stripScrollX
    h.clock.advance(by: StripDrag.autoScrollTick)
    await cancelled?.value
    #expect(h.model.stripScrollX == scrolled)
  }

  @Test func noAutoScrollInFit() async throws {
    let (h, _) = try await five()
    h.model.stripPress(at: centre(h, 0), extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: 995, y: Self.row))
    #expect(h.model.pendingAutoScroll == nil)
    h.model.stripCancel()
  }

  @Test func playbackPagesWhenZoomed() async throws {
    let (h, _) = try await five(width: 400)
    h.model.stripZoom = .pxPerSecond(100)  // 4 s across
    h.model.play()
    h.preview.onTime?(RationalTime(3, 1))
    #expect(h.model.stripScrollX == 0, "still in view")
    h.preview.onTime?(RationalTime(9, 1))
    let L = h.model.stripLayout()
    let x = L.x(for: h.model.playhead)
    #expect(x >= 0 && x < 400, "paged so the playhead is in view")
    #expect(h.model.stripScrollX > 0)
    h.model.pause()
    h.model.stripZoomFit()
    h.model.play()
    h.preview.onTime?(RationalTime(45, 1))
    #expect(h.model.stripScrollX == 0, "Fit never scrolls")
  }

  // MARK: Finder drop

  @Test func finderDropInsertsAtCaret() async throws {
    let (h, ids) = try await five()
    let x = (h.model.stripLayout().tiles[1].rect.maxX + h.model.stripLayout().tiles[2].rect.minX) / 2
    h.model.finderDragOver(at: CGPoint(x: x, y: Self.row), count: 2)
    #expect(h.model.activeDrag?.kind == .finder(count: 2))
    #expect(h.model.activeDrag?.caretGap == 2)
    #expect(!h.model.dropArmed)
    await h.model.finderDrop([Harness.url("f.mov"), Harness.url("g.mov")]).value
    #expect(h.names == ["a.mov", "b.mov", "f.mov", "g.mov", "c.mov", "d.mov", "e.mov"])
    #expect(h.model.reel?.clips.first?.id == ids[0])
    #expect(h.model.activeDrag == nil)
  }

  @Test func finderDropOutsideAppends() async throws {
    let (h, _) = try await five()
    h.model.finderDragOver(at: CGPoint(x: 100, y: Self.row), count: 1)
    h.model.finderDragOver(at: nil, count: 1)  // left the strip for the rest of the window
    #expect(h.model.dropArmed, "the armed hairline frame")
    #expect(h.model.activeDrag == nil, "no caret outside the strip")
    await h.model.finderDrop([Harness.url("f.mov")]).value
    #expect(h.names.last == "f.mov")
    #expect(!h.model.dropArmed)
  }

  @Test func finderDragLeavingClearsState() async throws {
    let (h, _) = try await five()
    h.model.finderDragOver(at: CGPoint(x: 100, y: Self.row), count: 1)
    h.model.finderDragLeft(strip: true)
    #expect(h.model.activeDrag == nil)
    h.model.finderDragOver(at: nil, count: 1)
    h.model.finderDragLeft(strip: false)
    #expect(!h.model.dropArmed)
  }

  @Test func finderDropObeysImportRules() async throws {
    let (h, _) = try await five()
    h.model.finderDragOver(at: CGPoint(x: 100, y: Self.row), count: 2)
    await h.model.finderDrop([Harness.url("f.mov"), Harness.url("notes.txt")]).value
    #expect(h.names == ["a.mov", "f.mov", "b.mov", "c.mov", "d.mov", "e.mov"])
    #expect(h.noteTexts.contains("Skipped 1 file trimlab can't open."))

    h.model.exportState = .running(progress: 0, eta: nil)
    let before = h.model.reel
    h.model.finderDragOver(at: CGPoint(x: 100, y: Self.row), count: 1)
    await h.model.finderDrop([Harness.url("g.mov")]).value
    #expect(h.model.reel == before)
    #expect(h.noteTexts.last == "Finish or cancel the export first.")
    #expect(h.model.activeDrag == nil)
  }

  // MARK: joins

  @Test func joinClickCycles() async throws {
    let (h, ids) = try await five()
    var seen: [Join] = []
    for _ in 0..<4 {
      // A click on the gap before c: the join, never a tile.
      h.model.stripPress(at: join(h, 2), extend: false, toggle: false)
      h.model.stripRelease()
      seen.append(try #require(h.model.reel?.clips[2].join))
    }
    #expect(seen == [.crossfade(Limits.shortFade), .crossfade(Limits.longFade), .cut, .crossfade(Limits.shortFade)])
    #expect(h.model.reel?.clips[2].id == ids[2])
    h.model.undo()
    #expect(h.model.reel?.clips[2].join == .cut, "each click is one step")
  }

  @Test func joinHiddenOnFirst() async throws {
    let (h, ids) = try await five()
    let before = h.model.reel
    let depth = undoDepth(h)
    h.model.clickJoin(ids[0])
    #expect(h.model.reel == before)
    #expect(undoDepth(h) == depth)
    h.model.clickJoin(ids[1])
    #expect(h.model.reel?.clips[1].join == .crossfade(Limits.shortFade))
  }

  /// Ruling: joinHit before tile(at:). In a crossfade overlap a press is a join click, never a select or drag.
  @Test func pressInOverlapIsJoin() async throws {
    let (h, ids) = try await five()
    #expect(h.model.perform(.setJoin(ids[1], .crossfade(Limits.longFade)), coalesce: nil))
    h.model.select(ids[3], extend: false, toggle: false)
    let p = join(h, 1)
    #expect(h.model.stripLayout().tile(at: p) == ids[1], "the overlap is also a tile")
    h.model.stripPress(at: p, extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: p.x + 200, y: Self.row))
    #expect(h.model.activeDrag == nil, "a join press never drags")
    h.model.stripRelease()
    #expect(h.model.reel?.clips.map(\.id) == ids)
    #expect(h.model.selection.primary == ids[3])
    #expect(h.model.reel?.clips[1].join == .crossfade(Limits.longFade), "dragged off the join, it's no click")
    h.model.stripPress(at: p, extend: false, toggle: false)
    h.model.stripRelease()
    #expect(h.model.reel?.clips[1].join == .cut, "Long → cut")
  }

  /// Ruling: ±4 px hit slop around a cut's gap.
  @Test func cutHasHitSlop() async throws {
    let (h, ids) = try await five()
    let L = h.model.stripLayout()
    let left = L.tiles[1].rect.maxX, right = L.tiles[2].rect.minX
    #expect(L.joinHit(at: CGPoint(x: left - 3.5, y: Self.row)) == ids[2])
    #expect(L.joinHit(at: CGPoint(x: right + 3.5, y: Self.row)) == ids[2])
    #expect(L.joinHit(at: CGPoint(x: left - 5, y: Self.row)) == nil)
    #expect(L.joinHit(at: CGPoint(x: right + 5, y: Self.row)) == nil)
  }

  /// Ruling: in a dense Fit (gaps 0) the slop never covers more than a third of either neighbour.
  @Test func denseSlopCappedAtThird() {
    let clips = (0..<600).map { _ in StripLayoutTests.clip(StripLayoutTests.s(1)) }
    let L = StripLayoutTests.layout(clips, width: 1200)
    let a = L.tiles[100].rect, b = L.tiles[101].rect
    #expect(a.maxX == b.minX, "no gap")
    let w = a.width
    #expect(w < 12)
    #expect(L.joinHit(at: CGPoint(x: a.midX, y: Self.row)) == nil, "the middle of a tile is the tile")
    #expect(L.joinHit(at: CGPoint(x: a.maxX - w / 3 + 0.01, y: Self.row)) == L.tiles[101].id)
    #expect(L.joinHit(at: CGPoint(x: a.maxX - w / 3 - 0.05, y: Self.row)) == nil)
    #expect(L.tile(at: CGPoint(x: a.midX, y: Self.row)) == L.tiles[100].id)
  }

  // MARK: zoom and scroll

  @Test func zoomStepsGeometricFromRealPx() async throws {
    let (h, _) = try await five()
    let fit = h.model.stripLayout().pxPerSecond
    h.model.stripZoomStep(1)
    #expect(h.model.stripZoom == .pxPerSecond(Double(fit * 1.5)))
    h.model.stripZoomStep(1)
    #expect(h.model.stripZoom == .pxPerSecond(Double(fit * 1.5 * 1.5)))
    h.model.stripZoomStep(-1)
    guard case .pxPerSecond(let p) = h.model.stripZoom else { Issue.record("zoomed"); return }
    #expect(abs(p - Double(fit * 1.5)) < 1e-9)
    h.model.stripZoomStep(-1)
    #expect(h.model.stripZoom == .fit, "back at the Fit px/s is Fit")
    h.model.stripZoomStep(-1)
    #expect(h.model.stripZoom == .fit, "out past Fit stays Fit")
    for _ in 0..<20 { h.model.stripZoomStep(1) }
    #expect(h.model.stripZoom == .pxPerSecond(200))
    h.model.stripZoomFit()
    #expect(h.model.stripZoom == .fit)
    #expect(h.model.stripScrollX == 0)
  }

  @Test func zoomAroundPointerKeepsTime() async throws {
    let (h, _) = try await five()
    let x: CGFloat = 610
    let t = h.model.stripLayout().time(at: x)
    h.model.zoomStrip(by: 3, around: x)
    let L = h.model.stripLayout()
    #expect(!L.fits)
    #expect(abs(L.x(for: t) - x) < 0.5)
    #expect(h.model.stripScrollX > 0)
    h.model.zoomStrip(by: 1.7, around: 200)
    let t2 = L.time(at: 200)
    #expect(abs(h.model.stripLayout().x(for: t2) - 200) < 0.5)
  }

  /// The strip's frame in the window, as the view reports it, for scroll-wheel events.
  static let frame = CGRect(x: 20, y: 600, width: 1000, height: Tokens.Layout.strip)
  static func inFrame(_ x: CGFloat) -> CGPoint { CGPoint(x: frame.minX + x, y: frame.midY) }

  @Test func scrollOnlyWhenZoomed() async throws {
    let (h, _) = try await five()
    h.model.stripFrameChanged(Self.frame)
    h.model.stripScroll(by: 50)
    #expect(h.model.stripScrollX == 0)
    #expect(!h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true, at: Self.inFrame(500)),
            "Fit lets the event go")
    h.model.stripZoom = .pxPerSecond(100)
    h.model.stripScroll(by: 50)
    #expect(h.model.stripScrollX == 50)
    #expect(h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true, at: Self.inFrame(500)))
    #expect(h.model.stripScrollX == 70, "fingers left scroll the Reel on")
    h.model.stripScroll(by: -500)
    #expect(h.model.stripScrollX == 0)
    h.model.stripScroll(by: 1e6)
    let L = h.model.stripLayout()
    #expect(h.model.stripScrollX == L.contentWidth - 1000, "clamped to the content")
  }

  @Test func commandScrollZoomsAroundPointer() async throws {
    let (h, _) = try await five()
    h.model.stripFrameChanged(Self.frame)
    let t = h.model.stripLayout().time(at: 300)
    #expect(h.model.stripScrollWheel(dx: 0, dy: 1, command: true, precise: false, at: Self.inFrame(300)))
    #expect(h.model.stripZoom != .fit)
    #expect(abs(h.model.stripLayout().x(for: t) - 300) < 0.5, "around the pointer, in strip coordinates")
  }

  /// Review I1: only events over the strip's reported frame, never with no frame, never under a modal.
  @Test func scrollWheelScopedToStrip() async throws {
    let (h, _) = try await five()
    h.model.stripZoom = .pxPerSecond(100)
    #expect(!h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true, at: Self.inFrame(500)),
            "no frame reported yet")
    h.model.stripFrameChanged(Self.frame)
    #expect(!h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true,
                                      at: CGPoint(x: 500, y: Self.frame.minY - 1)), "above the strip")
    #expect(!h.model.stripScrollWheel(dx: 0, dy: 1, command: true, precise: false,
                                      at: CGPoint(x: Self.frame.maxX + 1, y: Self.frame.midY)), "beside it")
    #expect(h.model.stripScrollX == 0 && h.model.stripZoom == .pxPerSecond(100))
    h.model.modals.open(.keyMap)
    #expect(!h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true, at: Self.inFrame(500)),
            "a modal is on top")
    _ = h.model.modals.close(.keyMap)
    #expect(h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true, at: Self.inFrame(500)))
    h.model.stripFrameChanged(nil)
    #expect(!h.model.stripScrollWheel(dx: -20, dy: 0, command: false, precise: true, at: Self.inFrame(500)),
            "the strip went away")
  }

  // MARK: press-time modifiers and abandoned presses

  /// Review I2: ⇧ and ⌘ are read from the platform at the moment of the press.
  @Test func pressReadsModifiersAtPressTime() async throws {
    let (h, ids) = try await five()
    h.model.stripPress(at: centre(h, 1))
    h.model.stripRelease()
    h.platform.hold(.shift)
    h.model.stripPress(at: centre(h, 3))
    h.platform.hold([])  // let go before the release: the press already knew
    h.model.stripRelease()
    #expect(h.model.selection.all == Set(ids[1...3]))
    h.platform.hold(.command)
    h.model.stripPress(at: centre(h, 2))
    h.model.stripRelease()
    #expect(h.model.selection.all == [ids[1], ids[3]])
  }

  /// Review I3: a press whose release never came (the gesture was cancelled) leaves nothing behind.
  @Test func abandonedPressIsForgotten() async throws {
    let (h, ids) = try await five()
    h.model.stripPress(at: centre(h, 1), extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: 990, y: Self.row))
    #expect(h.model.activeDrag != nil)
    // No release: a fresh press starts clean, and its click is only a click.
    h.model.stripPress(at: centre(h, 3), extend: false, toggle: false)
    #expect(h.model.activeDrag == nil)
    h.model.stripRelease()
    #expect(h.model.reel?.clips.map(\.id) == ids)
    #expect(h.model.selection == Selection(primary: ids[3], all: [ids[3]]))
    // A press that just stops (the view's gesture reset) is cancelled; a stray release then does nothing.
    h.model.stripPress(at: centre(h, 0), extend: false, toggle: false)
    #expect(h.model.stripCancel())
    h.model.stripRelease()
    #expect(h.model.selection.primary == ids[3])
  }

  // MARK: drawing

  /// The ghost: the grabbed tile at 80 % with a gold outline, at most 96 px wide, lifted 6 px, under the pointer;
  /// the caret in the gap; the dragged tiles at 35 %.
  @Test func ghostAndCaretDraw() throws {
    FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts")
    let clips = (0..<4).map { StripLayoutTests.clip(StripLayoutTests.s(10), name: "IMG_\($0).MOV") }
    let L = StripLayoutTests.layout(clips, width: 800)
    let grabbed = L.tiles[1]
    let pointer: CGFloat = 600
    let state = StripState(primary: clips[1].id, selected: [clips[1].id], dragged: [clips[1].id], caretGap: 1,
                           ghost: StripState.Ghost(id: clips[1].id, x: pointer, grabOffset: grabbed.rect.width / 2))
    let image = try StripLayoutTests.render(StripCanvas(layout: L, sprites: [:], state: state), width: 800, scale: 1)
    let px = try StageViewTests.pixels(image)
    func at(_ x: CGFloat, _ y: CGFloat) -> [UInt8] { StageViewTests.rgb(px, image, x: Int(x), y: Int(y)) }
    let top = Tokens.Layout.stripCap - Tokens.Layout.ghostLift
    let left = pointer - Tokens.Layout.ghostMaxWidth / 2
    #expect(at(left + 0.5, top + 20) == [0xC9, 0xA8, 0x6A], "ghost outline, 96 px centred on the pointer")
    #expect(at(left + Tokens.Layout.ghostMaxWidth - 1, top + 20) == [0xC9, 0xA8, 0x6A])
    #expect(at(left + Tokens.Layout.ghostMaxWidth + 3, top + 2) != [0xC9, 0xA8, 0x6A], "no wider than 96 px")
    let caret = try #require(DropCaret.centre(gap: 1, layout: L))
    #expect(at(caret, Tokens.Layout.stripCap - 2) == [0xC9, 0xA8, 0x6A], "caret proud of the row")
    #expect(at(grabbed.rect.minX + 0.5, Self.row) != [0xC9, 0xA8, 0x6A], "a dragged primary shows no outline")
  }

  /// Phase 4 review I4: a reorder drag moves the primary away from the playhead; the playhead follows it.
  @Test func reorderKeepsPlayheadOnPrimary() async throws {
    let (h, ids) = try await five()
    let end = h.model.stripLayout().tiles[4].rect.maxX
    drag(h, from: centre(h, 0), to: CGPoint(x: end - 2, y: Self.row))
    #expect(h.model.reel?.clips.last?.id == ids[0])
    #expect(h.model.selection.primary == ids[0])
    let start = try #require(h.model.plan?.placements.first { $0.clipID == ids[0] }?.reelSpan.start)
    #expect(h.model.playhead == start)
  }
}
