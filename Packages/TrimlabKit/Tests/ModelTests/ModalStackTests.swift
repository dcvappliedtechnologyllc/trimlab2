import Testing
@testable import TrimlabModel

@Suite struct ModalStackTests {
  @Test func topIsMostRecentlyOpened() {
    var s = ModalStack()
    #expect(s.top == nil)
    s.open(.keyMap)
    s.open(.exportSheet)
    #expect(s.top == .exportSheet)
    s.open(.keyMap)
    #expect(s.top == .keyMap)
    #expect(s.close(.keyMap) == nil)
    #expect(s.top == .exportSheet)
  }

  @Test func closeReturnsOpener() {
    var s = ModalStack()
    s.open(.exportSheet, opener: "export-button")
    #expect(s.close(.exportSheet) == "export-button")
    #expect(s.top == nil)
  }

  @Test func closeOfNotOpenModalIsNoOp() {
    var s = ModalStack()
    s.open(.keyMap, opener: "k")
    #expect(s.close(.exportSheet) == nil)
    #expect(s.top == .keyMap)
  }

  @Test func closingNonTopKeepsTop() {
    var s = ModalStack()
    s.open(.keyMap, opener: "k")
    s.open(.exportSheet, opener: "e")
    #expect(s.close(.keyMap) == "k")
    #expect(s.top == .exportSheet)
  }

  @Test func reopenKeepsOriginalOpener() {
    var s = ModalStack()
    s.open(.keyMap, opener: "first")
    s.open(.exportSheet)
    s.open(.keyMap, opener: "second")
    #expect(s.close(.keyMap) == "first")
  }

  @Test func tabTrapCycles() {
    var s = ModalStack()
    s.register(["a", "b", "c"], for: .exportSheet)
    s.register(["x", "y"], for: .keyMap)
    s.open(.keyMap)
    s.open(.exportSheet)
    #expect(s.tabOrder(for: .exportSheet) == ["a", "b", "c"])
    #expect(s.next(after: "c", backwards: false) == "a")
    #expect(s.next(after: "a", backwards: true) == "c")
    #expect(s.next(after: "a", backwards: false) == "b")
    // Never leaves the top modal's controls.
    #expect(s.next(after: "x", backwards: false) == "a")
    #expect(s.next(after: "x", backwards: true) == "c")
    #expect(s.next(after: nil, backwards: false) == "a")
    #expect(s.next(after: nil, backwards: true) == "c")
  }

  @Test func nextIsNilWithoutModalOrControls() {
    var s = ModalStack()
    #expect(s.next(after: "a", backwards: false) == nil)
    s.open(.keyMap)
    #expect(s.next(after: nil, backwards: false) == nil)
    #expect(s.tabOrder(for: .keyMap) == [])
  }

  @Test func passKeysFollowTop() {
    var s = ModalStack()
    #expect(s.passKeys.isEmpty)
    s.open(.keyMap, passKeys: [.keyMap, .escape])
    s.open(.exportSheet)
    #expect(s.passKeys.isEmpty)
    s.open(.ffmpegCard, passKeys: [.undo])
    #expect(s.passKeys == [.undo])
    _ = s.close(.ffmpegCard)
    _ = s.close(.exportSheet)
    #expect(s.passKeys == [.keyMap, .escape])
  }
}
