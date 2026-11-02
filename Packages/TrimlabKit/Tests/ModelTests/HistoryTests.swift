import Foundation
import Testing
@testable import TrimlabModel

@Suite struct HistoryTests {
  private func state(_ name: String) -> (Reel, Selection) {
    (Builders.reel([1], name: name), Selection())
  }

  @Test func undoRestoresReelAndSelection() {
    var h = History()
    let a = Builders.reel([1, 2], name: "A")
    let sel = Selection(primary: a.clips[1].id, all: [a.clips[1].id])
    h.record(a, sel, coalesce: nil)
    let b = Builders.reel([1], name: "B")
    let restored = h.undo(current: (b, Selection()))
    #expect(restored?.0 == a)
    #expect(restored?.1 == sel)
    #expect(!h.canUndo)
    #expect(h.canRedo)
  }

  @Test func undoOnEmptyReturnsNil() {
    var h = History()
    #expect(h.undo(current: state("x")) == nil)
    #expect(h.redo(current: state("x")) == nil)
  }

  @Test func redoAfterUndo() {
    var h = History()
    let a = Builders.reel([1], name: "A"), b = Builders.reel([2], name: "B")
    h.record(a, Selection(), coalesce: nil)
    _ = h.undo(current: (b, Selection()))
    let redone = h.redo(current: (a, Selection()))
    #expect(redone?.0 == b)
    #expect(h.canUndo)
    #expect(!h.canRedo)
  }

  @Test func newEditClearsRedo() {
    var h = History()
    h.record(Builders.reel([1], name: "A"), Selection(), coalesce: nil)
    _ = h.undo(current: state("B"))
    #expect(h.canRedo)
    h.record(Builders.reel([1], name: "C"), Selection(), coalesce: nil)
    #expect(!h.canRedo)
  }

  @Test func coalescedGestureIsOneStep() {
    var h = History()
    let id = UUID()
    let first = Builders.reel([1], name: "first")
    h.record(first, Selection(), coalesce: "drag.in.\(id)")
    for i in 1..<10 { h.record(Builders.reel([1], name: "n\(i)"), Selection(), coalesce: "drag.in.\(id)") }
    #expect(h.undo(current: state("end"))?.0 == first)
    #expect(!h.canUndo)
  }

  @Test func endGestureSplitsSteps() {
    var h = History()
    h.record(Builders.reel([1], name: "1"), Selection(), coalesce: "k")
    h.endGesture()
    h.record(Builders.reel([1], name: "2"), Selection(), coalesce: "k")
    #expect(h.undo(current: state("end"))?.0.name == "2")
    #expect(h.undo(current: state("x"))?.0.name == "1")
    #expect(!h.canUndo)
  }

  @Test func differentKeysDontMerge() {
    var h = History()
    h.record(Builders.reel([1], name: "1"), Selection(), coalesce: "a")
    h.record(Builders.reel([1], name: "2"), Selection(), coalesce: "b")
    #expect(h.undo(current: state("end"))?.0.name == "2")
    #expect(h.undo(current: state("x"))?.0.name == "1")
  }

  @Test func nilKeyNeverMerges() {
    var h = History()
    h.record(Builders.reel([1], name: "1"), Selection(), coalesce: nil)
    h.record(Builders.reel([1], name: "2"), Selection(), coalesce: nil)
    #expect(h.undo(current: state("end"))?.0.name == "2")
    #expect(h.canUndo)
  }

  @Test func undoThenSameKeyRecords() {
    var h = History()
    h.record(Builders.reel([1], name: "1"), Selection(), coalesce: "k")
    _ = h.undo(current: state("after"))
    h.record(Builders.reel([1], name: "2"), Selection(), coalesce: "k")
    #expect(h.canUndo)
    #expect(h.undo(current: state("end"))?.0.name == "2")
  }

  @Test func redoThenSameKeyRecords() {
    var h = History()
    h.record(Builders.reel([1], name: "1"), Selection(), coalesce: "k")
    h.endGesture()
    h.record(Builders.reel([1], name: "2"), Selection(), coalesce: "j")
    _ = h.undo(current: state("a"))
    _ = h.redo(current: state("b"))
    h.record(Builders.reel([1], name: "3"), Selection(), coalesce: "j")
    #expect(h.undo(current: state("end"))?.0.name == "3")
    #expect(h.undo(current: state("x"))?.0.name == "b")
  }

  @Test func limit200DropsOldest() {
    var h = History()
    for i in 0..<205 { h.record(Builders.reel([1], name: "\(i)"), Selection(), coalesce: nil) }
    var count = 0
    var oldest = ""
    while let r = h.undo(current: state("cur")) { count += 1; oldest = r.0.name }
    #expect(count == History.limit)
    #expect(oldest == "5")
  }

  @Test func resetClearsEverything() {
    var h = History()
    h.record(Builders.reel([1], name: "1"), Selection(), coalesce: "k")
    _ = h.undo(current: state("a"))
    h.reset()
    #expect(!h.canUndo)
    #expect(!h.canRedo)
    h.record(Builders.reel([1], name: "2"), Selection(), coalesce: "k")
    #expect(h.canUndo)
  }
}
