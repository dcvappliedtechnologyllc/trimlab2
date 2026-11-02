import Foundation
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 26: edit intents, undo and selection (§4.3, §4.8).
@MainActor @Suite struct EditTests {
  private func ids(_ h: Harness) -> [UUID] { h.model.reel?.clips.map(\.id) ?? [] }

  @Test func splitTooCloseNote() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    let before = try #require(h.model.reel)
    let ok = h.model.perform(.split(before.clips[0].id, atSource: RationalTime(1, 5)), coalesce: nil)
    #expect(!ok)
    #expect(h.noteTexts == ["Too close to the clip's edge to split."])
    #expect(h.model.notes.first?.kind == .quiet)
    #expect(h.model.reel == before)
    h.model.undo()  // the only step is still the import
    #expect(h.model.reel?.clips.isEmpty == true)
    #expect(!h.model.history.canUndo)
  }

  @Test func splitRecordsOneStep() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    let id = try #require(h.model.reel?.clips.first?.id)
    #expect(h.model.perform(.split(id, atSource: RationalTime(5, 1)), coalesce: nil))
    #expect(h.model.reel?.clips.count == 2)
    h.model.undo()
    #expect(h.model.reel?.clips.count == 1)
  }

  @Test func deleteMovesSelectionToNext() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov", "c.mov"])
    var clips = ids(h)
    h.model.select(clips[1], extend: false, toggle: false)
    h.model.perform(.delete([clips[1]]), coalesce: nil)
    #expect(h.model.selection.primary == clips[2])
    #expect(h.model.selection.all == [clips[2]])

    clips = ids(h)
    h.model.select(clips[1], extend: false, toggle: false)
    h.model.perform(.delete([clips[1]]), coalesce: nil)
    #expect(h.model.selection.primary == clips[0])

    h.model.perform(.delete(Set(ids(h))), coalesce: nil)
    #expect(h.model.reel != nil)
    #expect(h.model.reel?.clips.isEmpty == true)
    #expect(h.model.selection.primary == nil)
    #expect(h.model.selection.all.isEmpty)
  }

  @Test func undoRestoresSelection() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    let clips = ids(h)
    h.model.select(clips[1], extend: false, toggle: false)
    h.model.perform(.delete([clips[1]]), coalesce: nil)
    h.model.undo()
    #expect(h.model.selection.primary == clips[1])
  }

  /// Task 13 ruling: undo and redo never roll back the export settings.
  @Test func undoKeepsExportSettings() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.perform(.delete([ids(h)[0]]), coalesce: nil)
    var spec = try #require(h.model.reel?.export)
    spec.quality = .standard
    spec.fileName = "mine.mp4"
    h.model.perform(.setExport(spec), coalesce: nil, record: false)
    h.model.undo()
    #expect(h.model.reel?.clips.count == 2)
    #expect(h.model.reel?.export == spec)
    h.model.redo()
    #expect(h.model.reel?.export == spec)
  }

  @Test func gestureCoalescesUntilEnd() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    let id = try #require(h.model.reel?.clips.first?.id)
    for s in 1...4 {
      h.model.perform(.setIn(id, RationalTime(Int64(s), 1)), coalesce: "deck.in.\(id)")
    }
    let afterGesture = h.model.reel?.clips.first?.inTime
    h.model.endGesture()
    h.model.perform(.setIn(id, RationalTime(6, 1)), coalesce: "deck.in.\(id)")
    h.model.undo()
    #expect(h.model.reel?.clips.first?.inTime == afterGesture)
    h.model.undo()
    #expect(h.model.reel?.clips.first?.inTime == .zero)
  }

  @Test func planFollowsEdits() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    #expect(h.model.plan?.total == RationalTime(20, 1))
    h.model.perform(.delete([ids(h)[0]]), coalesce: nil)
    #expect(h.model.plan?.total == RationalTime(10, 1))
    h.model.undo()
    #expect(h.model.plan?.total == RationalTime(20, 1))
  }

  @Test func selectExtendToggleAll() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov", "c.mov", "d.mov"])
    let c = ids(h)
    h.model.select(c[1], extend: false, toggle: false)
    h.model.select(c[3], extend: true, toggle: false)
    #expect(h.model.selection.all == [c[1], c[2], c[3]])
    #expect(h.model.selection.primary == c[3])
    h.model.select(c[2], extend: false, toggle: true)
    #expect(h.model.selection.all == [c[1], c[3]])
    h.model.select(c[0], extend: false, toggle: true)
    #expect(h.model.selection.all == [c[0], c[1], c[3]])
    #expect(h.model.selection.primary == c[0])
    h.model.collapseSelection()
    #expect(h.model.selection.all == [c[0]])
    h.model.selectAll()
    #expect(h.model.selection.all == Set(c))
    #expect(h.model.selection.primary == c[0])
  }

  @Test func newReelClears() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.model.newReel()
    #expect(h.model.reel == nil)
    #expect(h.model.plan == nil)
    #expect(!h.model.history.canUndo)
    #expect(h.model.selection == Selection())
  }

  /// Review I2: trims and splits wait for the clip's real facts; structure edits don't.
  @Test func probingTileRefusesTrims() async throws {
    let h = Harness()
    h.media.hold()
    let task = h.model.importURLs([Harness.url("a.mov"), Harness.url("b.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    let reel = try #require(h.model.reel)
    let id = reel.clips[0].id
    for edit in [ReelEdit.split(id, atSource: RationalTime(1, 2)), .setIn(id, RationalTime(1, 10)),
                 .setOut(id, RationalTime(1, 2)), .resetIn(id), .resetOut(id)] {
      #expect(!h.model.perform(edit, coalesce: nil))
    }
    #expect(h.noteTexts == Array(repeating: "Wait for a.mov to finish loading.", count: 5))
    #expect(h.model.reel == reel)
    h.model.undo()  // still only the import step
    #expect(h.model.reel?.clips.isEmpty == true)
    h.model.redo()
    #expect(h.model.perform(.setFraming([id], .fit), coalesce: nil))
    #expect(h.model.perform(.move([id], toGap: 2), coalesce: nil))
    #expect(h.model.perform(.rename("x"), coalesce: nil))
    #expect(h.model.perform(.delete([id]), coalesce: nil))
    h.media.release()
    await task.value
    #expect(h.names == ["b.mov"])
  }

  @Test func editsWithoutReelDoNothing() {
    let h = Harness()
    #expect(!h.model.perform(.rename("x"), coalesce: nil))
    h.model.undo()
    #expect(h.model.reel == nil)
    #expect(h.model.notes.isEmpty)
  }
}
