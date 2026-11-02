import Foundation
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 30: every `Command` dispatched to the intents, the key context, and what the key monitor does with a chord
/// (§4.7, §4.10). Three 10 s clips at 29.97 unless a test says otherwise, so a, b and c sit at 0, 10 and 20 s.
@MainActor @Suite struct CommandTests {
  private func seconds(_ s: Int64) -> RationalTime { RationalTime(s, 1) }

  private func clips(_ names: [String] = ["a.mov", "b.mov", "c.mov"]) async throws -> (Harness, [UUID]) {
    let h = Harness()
    await h.importAll(names)
    await h.model.pendingPreview?.value
    let ids = try #require(h.model.reel?.clips.map(\.id))
    try #require(ids.count == names.count)
    return (h, ids)
  }

  private func order(_ h: Harness) -> [UUID] { h.model.reel?.clips.map(\.id) ?? [] }
  private func clip(_ h: Harness, _ id: UUID) throws -> ReelClip {
    try #require(h.model.reel?.clips.first { $0.id == id })
  }

  // MARK: playback and seeking

  @Test func arrowsStepFrames() async throws {
    let (h, _) = try await clips()
    let fd = try #require(h.model.plan?.frameDuration)
    h.model.command(.step(1))
    #expect(h.model.playhead == fd)
    h.model.command(.step(-1))
    #expect(h.model.playhead == .zero)
    h.model.command(.jump(1))
    #expect(h.model.playhead == seconds(1))
  }

  @Test func spaceAndShuttle() async throws {
    let (h, _) = try await clips()
    h.model.command(.playPause)
    #expect(h.model.playState == .playing(rate: 1))
    h.model.command(.shuttle(.forward))
    #expect(h.model.playState == .playing(rate: 2))
    h.model.command(.shuttle(.stop))
    #expect(h.model.playState == .paused)
    h.model.command(.playPause)
    h.model.command(.playPause)
    #expect(h.model.playState == .paused)
  }

  @Test func upDownSelectAndSeek() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.command(.selectNext)
    #expect(h.model.selection.primary == ids[1])
    #expect(h.model.playhead == seconds(10))
    h.model.command(.selectNext)
    h.model.command(.selectNext)  // already last: stays
    #expect(h.model.selection.primary == ids[2])
    #expect(h.model.playhead == seconds(20))
    h.model.command(.selectPrev)
    #expect(h.model.selection.primary == ids[1])
    #expect(h.model.playhead == seconds(10))
    h.model.command(.selectPrev)
    h.model.command(.selectPrev)
    #expect(h.model.selection.primary == ids[0])
    #expect(h.model.playhead == .zero)
  }

  @Test func homeEndLastKeptFrame() async throws {
    let (h, ids) = try await clips()
    let fd = try #require(h.model.plan?.frameDuration)
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.command(.toLastKept)
    #expect(h.model.playhead == seconds(20) - fd, "Out is exclusive: the last kept frame is one frame short")
    h.model.command(.toIn)
    #expect(h.model.playhead == seconds(10))
    h.model.command(.toReelEnd)
    #expect(h.model.playhead == seconds(30) - fd)
    h.model.command(.toReelStart)
    #expect(h.model.playhead == .zero)
  }

  // MARK: edits

  @Test func iAndOAtDeckPlayhead() async throws {
    let (h, ids) = try await clips()
    let fd = try clip(h, ids[0]).facts.frameDuration
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.peek(sourceTime: RationalTime(9, 1) + fd.halved())  // between frames
    h.model.command(.setOut)
    #expect(try clip(h, ids[0]).outTime == (RationalTime(9, 1) + fd.halved()).floored(toFrame: fd))

    // Not in peek: the deck playhead is the Reel playhead mapped into the primary clip's source.
    h.model.select(ids[1], extend: false, toggle: false)
    let start = try #require(h.model.plan?.placements[1].reelSpan.start)  // a is shorter now
    h.model.seek(reelTime: start + seconds(3))
    let expected = seconds(3).floored(toFrame: fd)
    h.model.command(.setIn)
    #expect(try clip(h, ids[1]).inTime == expected)
  }

  @Test func resetInAndOut() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.peek(sourceTime: seconds(2))
    h.model.command(.setIn)
    #expect(try clip(h, ids[0]).inTime > .zero)
    h.model.command(.resetIn)
    #expect(try clip(h, ids[0]).inTime == .zero)
    h.model.peek(sourceTime: seconds(8))
    h.model.command(.setOut)
    h.model.command(.resetOut)
    #expect(try clip(h, ids[0]).outTime == seconds(10))
  }

  @Test func splitAtPlayheadSelectsSecondHalf() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.seek(reelTime: seconds(4))
    h.model.command(.split)
    #expect(h.model.reel?.clips.count == 4)
    #expect(h.model.reel?.clips[1].inTime == h.model.reel?.clips[0].outTime)
    #expect(h.model.selection.primary == h.model.reel?.clips[1].id, "B is selected")
    h.model.undo()
    #expect(h.model.reel?.clips.count == 3)
  }

  @Test func splitTooCloseIsNoted() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.seek(reelTime: .zero)
    h.model.command(.split)
    #expect(h.model.reel?.clips.count == 3)
    #expect(h.noteTexts == ["Too close to the clip's edge to split."])
  }

  @Test func xCyclesJoin() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.command(.toggleJoin)
    #expect(try clip(h, ids[1]).join == .crossfade(Limits.shortFade))
    h.model.command(.toggleJoin)
    #expect(try clip(h, ids[1]).join == .crossfade(Limits.longFade))
    h.model.command(.toggleJoin)
    #expect(try clip(h, ids[1]).join == .cut)
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.command(.toggleJoin)  // nothing joins into the first clip
    #expect(try clip(h, ids[0]).join == .cut)
  }

  @Test func fTogglesOppositeOfPrimary() async throws {
    let h = Harness()
    var wide = StubMedia.facts()
    wide.displayWidth = 1920
    wide.displayHeight = 1080
    h.media.script("w1.mov", .facts(wide))
    h.media.script("w2.mov", .facts(wide))
    await h.importAll(["w1.mov", "w2.mov", "p.mov"])
    let ids = try #require(["w1.mov", "w2.mov", "p.mov"].map { name in
      h.model.reel?.clips.first { $0.source.absolutePath.hasSuffix(name) }?.id
    } as? [UUID])
    #expect(try clip(h, ids[0]).framing == .fill)
    // Primary fill, selection mixed: everything goes to fit.
    h.model.perform(.setFraming([ids[1]], .fit), coalesce: nil)
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.select(ids[0], extend: true, toggle: false)
    #expect(h.model.selection.primary == ids[0])
    #expect(h.model.selection.all == [ids[0], ids[1]])
    h.model.command(.toggleFraming)
    #expect(try clip(h, ids[0]).framing == .fit)
    #expect(try clip(h, ids[1]).framing == .fit)
    h.model.command(.toggleFraming)
    #expect(try clip(h, ids[0]).framing == .fill)
    #expect(try clip(h, ids[1]).framing == .fill)

    // A 9:16 primary: no-op, no undo step.
    h.model.select(ids[2], extend: false, toggle: false)
    let before = h.model.reel
    h.model.command(.toggleFraming)
    #expect(h.model.reel == before)
  }

  @Test func deleteSelectionAndUndoRedo() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.command(.deleteSelection)
    #expect(order(h) == [ids[0], ids[2]])
    #expect(h.model.selection.primary == ids[2])
    h.model.command(.undo)
    #expect(order(h) == ids)
    h.model.command(.redo)
    #expect(order(h) == [ids[0], ids[2]])
    h.model.command(.selectAll)
    #expect(h.model.selection.all.count == 2)
  }

  @Test func switches() async throws {
    let (h, _) = try await clips()
    h.model.command(.toggleRemoveAudio)
    #expect(h.model.reel?.export.removeAudio == true)
    let loop = h.model.prefs.loop
    h.model.command(.toggleLoop)
    #expect(h.model.prefs.loop == !loop)
  }

  @Test func newReelAndOpen() async throws {
    let (h, _) = try await clips()
    h.platform.state.withLock { $0.panelAnswer = [Harness.url("d.mov")] }
    await h.model.openFiles().value
    #expect(try #require(h.model.reel).clips.count == 4)
    #expect(h.names == ["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.command(.newReel)
    #expect(h.model.reel == nil)
    #expect(!h.model.hasClips)
  }

  // MARK: ⌥← / ⌥→

  @Test func optionArrowMovesOnePlace() async throws {
    let (h, ids) = try await clips(["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.select(ids[0], extend: false, toggle: false)
    for _ in 0..<3 { h.model.command(.moveSelection(1)) }  // a held ⌥→
    #expect(order(h) == [ids[1], ids[2], ids[3], ids[0]])
    h.model.command(.moveSelection(1))  // at the end: nothing, and nothing recorded
    #expect(order(h) == [ids[1], ids[2], ids[3], ids[0]])
    h.model.endGesture()  // key up
    h.model.undo()
    #expect(order(h) == ids, "one gesture, one undo step")

    h.model.command(.moveSelection(-1))  // already first
    #expect(order(h) == ids)
    h.model.endGesture()
    h.model.select(ids[2], extend: false, toggle: false)
    h.model.command(.moveSelection(-1))
    #expect(order(h) == [ids[0], ids[2], ids[1], ids[3]])
    h.model.endGesture()
    h.model.command(.moveSelection(-1))
    h.model.endGesture()
    h.model.undo()
    #expect(order(h) == [ids[0], ids[2], ids[1], ids[3]], "a second press is a second step")
  }

  @Test func moveSelectionMovesTheWholeSelection() async throws {
    let (h, ids) = try await clips(["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.select(ids[2], extend: true, toggle: false)
    h.model.command(.moveSelection(-1))
    #expect(order(h) == [ids[1], ids[2], ids[0], ids[3]])
    h.model.command(.moveSelection(1))
    #expect(order(h) == [ids[0], ids[1], ids[2], ids[3]])
  }

  // MARK: escape, zoom, modals

  @Test func escCollapsesSelection() async throws {
    let (h, ids) = try await clips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.select(ids[2], extend: true, toggle: false)
    #expect(h.model.selection.all.count == 3)
    #expect(h.model.command(.escape))
    #expect(h.model.selection.all == [ids[2]])
    #expect(!h.model.command(.escape), "nothing left to clear: the key goes on")
  }

  @Test func escCancelsAStripDragFirst() async throws {
    let (h, ids) = try await clips()
    h.model.stripResized(width: 1000)
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.select(ids[1], extend: true, toggle: false)
    let r = h.model.stripLayout().tiles[0].rect
    let p = CGPoint(x: r.midX, y: Tokens.Layout.stripCap + Tokens.Layout.stripTile / 2)
    h.model.stripPress(at: p, extend: false, toggle: false)
    h.model.stripDrag(to: CGPoint(x: p.x + 40, y: p.y))
    h.model.stripDrag(to: CGPoint(x: p.x + 80, y: p.y))
    #expect(h.model.activeDrag != nil)
    #expect(h.model.keyContext.dragging)
    #expect(h.model.command(.escape))
    #expect(h.model.activeDrag == nil)
    #expect(h.model.selection.all.count == 2, "the drag ended; the selection waits for the next Esc")
    #expect(!h.model.keyContext.dragging)
  }

  @Test func escClosesTopModal() async throws {
    let (h, _) = try await clips()
    h.model.modals.open(.keyMap, opener: "help")
    h.model.modals.open(.exportSheet, opener: "export")
    h.model.command(.escape)
    #expect(h.model.modals.top == .keyMap)
    h.model.command(.escape)
    #expect(h.model.modals.top == nil)
    #expect(h.model.focusedControl == "help", "closing returns focus to the opener")
  }

  @Test func zoomCommands() async throws {
    let (h, _) = try await clips()
    h.model.stripResized(width: 1000)
    h.model.command(.stripZoom(1))
    guard case .pxPerSecond = h.model.stripZoom else { Issue.record("zoomed in expected"); return }
    h.model.command(.stripZoomFit)
    #expect(h.model.stripZoom == .fit)
    h.model.command(.deckZoom(1))
    #expect(h.model.deckZoom > 1)
    h.model.command(.deckZoom(-1))
    h.model.command(.deckZoom(-1))
    #expect(h.model.deckZoom == 1, "never below 1×")
  }

  @Test func menuDisabledUnderModal() async throws {
    let (h, _) = try await clips()
    #expect(h.model.menuEnabled)
    h.model.modals.open(.keyMap)
    #expect(!h.model.menuEnabled)
    h.model.modals.close(.keyMap)
    #expect(h.model.menuEnabled)
  }

  @Test func keyContextFollowsTheModel() async throws {
    let h = Harness()
    #expect(!h.model.keyContext.hasClip)
    await h.importAll(["a.mov"])
    let ctx = h.model.keyContext
    #expect(ctx.hasClip && !ctx.dragging && !ctx.inTextField && ctx.topModal == nil)
    h.model.modals.open(.exportSheet, passKeys: [.undo])
    #expect(h.model.keyContext.topModal == .exportSheet)
    #expect(h.model.keyContext.passKeys == [.undo])
  }

  // MARK: what the key monitor does with a chord

  private func key(_ k: Key, _ m: Mods = []) -> KeyChord { KeyChord(key: k, mods: m) }
  private func ch(_ s: Character, _ m: Mods = []) -> KeyChord { KeyChord(key: .char(s), mods: m) }

  @Test func plainKeysAreSwallowedAndRun() async throws {
    let (h, _) = try await clips()
    #expect(h.model.handleKey(key(.right), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.playhead > .zero)
    #expect(h.model.handleKey(key(.space), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.isPlaying)
    #expect(h.model.handleKey(ch("?"), isRepeat: false, inTextField: false) == .swallow)
  }

  @Test func repeatOnlyWhereTheTableAllows() async throws {
    let (h, _) = try await clips()
    #expect(h.model.handleKey(key(.right), isRepeat: true, inTextField: false) == .swallow)
    #expect(h.model.playhead > .zero, "arrows repeat")
    h.model.seek(reelTime: seconds(5))
    #expect(h.model.handleKey(ch("s"), isRepeat: true, inTextField: false) == .swallow)
    #expect(h.model.reel?.clips.count == 3, "S held does not split again")
    #expect(h.model.handleKey(key(.space), isRepeat: true, inTextField: false) == .swallow)
    #expect(!h.model.isPlaying)
  }

  @Test func commandChordsGoToTheMenus() async throws {
    let (h, _) = try await clips()
    #expect(h.model.handleKey(ch("n", .command), isRepeat: false, inTextField: false) == .pass)
    #expect(h.model.handleKey(ch("z", .command), isRepeat: false, inTextField: false) == .pass)
    #expect(h.model.reel?.clips.count == 3, "the menu item does the work, not the monitor")
  }

  @Test func textFieldKeepsItsKeys() async throws {
    let (h, _) = try await clips()
    for k in [ch("a"), ch("s"), key(.space), key(.left), key(.delete), ch("?")] {
      #expect(h.model.handleKey(k, isRepeat: false, inTextField: true) == .pass)
    }
    #expect(h.model.reel?.clips.count == 3)
    #expect(h.model.handleKey(key(.escape), isRepeat: false, inTextField: true) == .pass, "the field owns Esc")
    // No command matches ⌘Z in a field, so the field's responder gets it.
    #expect(h.model.handleKey(ch("z", .command), isRepeat: false, inTextField: true) == .sendToField(.undo))
    #expect(h.model.handleKey(ch("z", [.command, .shift]), isRepeat: false, inTextField: true) == .sendToField(.redo))
    #expect(h.model.handleKey(ch("a", .command), isRepeat: false, inTextField: true) == .sendToField(.selectAll))
    #expect(h.model.handleKey(ch("c", .command), isRepeat: false, inTextField: true) == .pass)
  }

  @Test func modalOwnsTheKeyboard() async throws {
    let (h, _) = try await clips()
    h.model.modals.open(.exportSheet, opener: "export")
    h.model.modals.register(["a", "b"], for: .exportSheet)
    // Bound keys that don't pass are swallowed, so the deck and strip can't move.
    #expect(h.model.handleKey(key(.right), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.playhead == .zero)
    // Space and an unbound key reach the focused control or field.
    #expect(h.model.handleKey(key(.space), isRepeat: false, inTextField: false) == .pass)
    #expect(h.model.handleKey(ch("q"), isRepeat: false, inTextField: false) == .pass)
    // Tab cycles inside the modal.
    #expect(h.model.handleKey(key(.tab), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.focusedControl == "a")
    #expect(h.model.handleKey(key(.tab, .shift), isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.focusedControl == "b")
    // ⌘ combos keep their system meaning.
    #expect(h.model.handleKey(ch("c", .command), isRepeat: false, inTextField: false) == .pass)
    // Esc closes it.
    #expect(h.model.handleKey(key(.escape), isRepeat: false, inTextField: true) == .swallow)
    #expect(h.model.modals.top == nil)
  }

  @Test func tabAndReturnBelongToTheSystemOutsideModals() async throws {
    let (h, _) = try await clips()
    #expect(h.model.handleKey(key(.tab), isRepeat: false, inTextField: false) == .pass)
    #expect(h.model.handleKey(key(.returnKey), isRepeat: false, inTextField: false) == .pass)
  }

  @Test func keysWithNothingToDoDontBeep() async throws {
    let h = Harness()
    #expect(h.model.handleKey(ch("s"), isRepeat: false, inTextField: false) == .swallow, "bound, but no clip")
    #expect(h.model.handleKey(ch("q"), isRepeat: false, inTextField: false) == .pass, "not a key we use")
  }

  @Test func keyUpEndsTheMoveGesture() async throws {
    let (h, ids) = try await clips(["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.select(ids[0], extend: false, toggle: false)
    _ = h.model.handleKey(key(.right, .option), isRepeat: false, inTextField: false)
    _ = h.model.handleKey(key(.right, .option), isRepeat: true, inTextField: false)
    h.model.handleKeyUp(key(.right, .option))
    _ = h.model.handleKey(key(.right, .option), isRepeat: false, inTextField: false)
    #expect(order(h) == [ids[1], ids[2], ids[3], ids[0]])
    h.model.undo()
    #expect(order(h) == [ids[1], ids[2], ids[0], ids[3]], "the second press is its own step")
    h.model.undo()
    #expect(order(h) == ids)
  }

  @Test func lostKeyUpDoesNotMergeMoves() async throws {
    let (h, ids) = try await clips(["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.select(ids[0], extend: false, toggle: false)
    _ = h.model.handleKey(key(.right, .option), isRepeat: false, inTextField: false)
    _ = h.model.handleKey(key(.right, .option), isRepeat: false, inTextField: false)  // no key-up between
    #expect(order(h) == [ids[1], ids[2], ids[0], ids[3]])
    h.model.undo()
    #expect(order(h) == [ids[1], ids[0], ids[2], ids[3]], "two presses, two steps")
  }

  @Test func resignEndsTheMoveGesture() async throws {
    let (h, ids) = try await clips(["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.command(.moveSelection(1))
    h.model.endKeyGesture()
    h.model.command(.moveSelection(1))
    h.model.undo()
    #expect(order(h) == [ids[1], ids[0], ids[2], ids[3]])
  }

  @Test func plainArrowKeyUpLeavesAMouseGestureAlone() async throws {
    let (h, ids) = try await clips(["a.mov", "b.mov", "c.mov", "d.mov"])
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.perform(.move([ids[0]], toGap: 2), coalesce: "drag")  // a mouse gesture, in progress
    h.model.handleKeyUp(key(.left))
    h.model.perform(.move([ids[0]], toGap: 3), coalesce: "drag")
    h.model.undo()
    #expect(order(h) == ids, "still one step")
  }
}
