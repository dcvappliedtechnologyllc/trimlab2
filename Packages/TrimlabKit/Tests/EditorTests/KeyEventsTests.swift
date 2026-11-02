import Testing
import TrimlabModel
@testable import TrimlabEditor

/// Task 30 review: raw key events to chords (the rules `KeyMonitor` relies on).
@Suite struct KeyEventsTests {
  typealias F = KeyEvents.Flag
  private func chord(_ code: UInt16, _ chars: String?, _ flags: UInt = 0, plain: String? = nil) -> KeyChord? {
    KeyEvents.chord(keyCode: code, characters: chars, charactersIgnoringModifiers: plain ?? chars, flags: flags)
  }

  @Test func questionMarkWithShift() {
    #expect(chord(44, "?", F.shift) == KeyChord(key: .char("?")))
  }

  @Test func shiftCommandZ() {
    #expect(chord(6, "Z", F.shift | F.command) == KeyChord(key: .char("z"), mods: [.shift, .command]))
  }

  @Test func commandPlusFoldsOntoEquals() {
    #expect(chord(24, "+", F.shift | F.command) == KeyChord(key: .char("="), mods: .command))
  }

  @Test func capsLockIsStripped() {
    #expect(chord(1, "S", F.capsLock) == KeyChord(key: .char("s")))
    #expect(chord(49, " ", F.capsLock) == KeyChord(key: .space))
  }

  @Test func fnArrowsAndHomeEnd() {
    #expect(chord(123, nil, F.function | F.numericPad) == KeyChord(key: .left))
    #expect(chord(115, nil, F.function) == KeyChord(key: .home))
    #expect(chord(119, nil, F.function | F.shift) == KeyChord(key: .end, mods: .shift))
    #expect(chord(76, nil, F.numericPad) == KeyChord(key: .returnKey), "keypad Enter")
  }

  @Test func cyrillicCommandChordFallsBackToLatin() {
    #expect(chord(6, "я", F.command) == KeyChord(key: .char("z"), mods: .command))  // ⌘Я is ⌘Z's key
    #expect(chord(6, "я", F.command | F.shift) == KeyChord(key: .char("z"), mods: [.command, .shift]))
    // Without ⌘ the produced character stands.
    #expect(chord(6, "я") == KeyChord(key: .char("я")))
  }

  @Test func optionLettersReachResetInAndOut() {
    #expect(chord(34, "ˆ", F.option, plain: "i") == KeyChord(key: .char("i"), mods: .option))
    #expect(chord(34, "ˆ", F.option, plain: "ˆ") == KeyChord(key: .char("i"), mods: .option), "dead key")
    #expect(chord(31, "ø", F.option, plain: "") == KeyChord(key: .char("o"), mods: .option), "empty")
    #expect(KeyMap.command(for: chord(34, "ˆ", F.option, plain: "ˆ")!, context: .editing) == .resetIn)
    #expect(KeyMap.command(for: chord(31, "ø", F.option, plain: "")!, context: .editing) == .resetOut)
  }

  @Test func functionKeysHaveNoChord() {
    #expect(chord(122, "\u{F704}") == nil)
  }
}
