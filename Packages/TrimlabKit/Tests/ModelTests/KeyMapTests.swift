import Testing
@testable import TrimlabModel

@Suite struct KeyMapTests {
  typealias Row = (KeyChord, Command)

  static func c(_ s: Character, _ m: Mods = []) -> KeyChord { KeyChord(key: .char(s), mods: m) }
  static func k(_ key: Key, _ m: Mods = []) -> KeyChord { KeyChord(key: key, mods: m) }

  /// Every §4.7 row: `KeyMap.rows`, the one table the dispatcher and the key map overlay both read (Task 37).
  static let table: [Row] = KeyMap.rows.map { ($0.0, $0.1) }

  /// The §4.7 rows written out independently of the implementation, so a row dropped or changed still fails.
  static let expected: [Row] = [
    (k(.space), .playPause),
    (k(.left), .step(-1)), (k(.right), .step(1)),
    (k(.left, .shift), .jump(-1)), (k(.right, .shift), .jump(1)),
    (k(.up), .selectPrev), (k(.down), .selectNext),
    (k(.left, .option), .moveSelection(-1)), (k(.right, .option), .moveSelection(1)),
    (c("j"), .shuttle(.back)), (c("k"), .shuttle(.stop)), (c("l"), .shuttle(.forward)),
    (k(.home), .toIn), (k(.end), .toLastKept),
    (k(.home, .shift), .toReelStart), (k(.end, .shift), .toReelEnd),
    (c("i"), .setIn), (c("o"), .setOut), (c("i", .option), .resetIn), (c("o", .option), .resetOut),
    (c("s"), .split), (c("x"), .toggleJoin), (c("f"), .toggleFraming),
    (k(.delete), .deleteSelection), (k(.forwardDelete), .deleteSelection),
    (c("a", .command), .selectAll), (c("a"), .toggleRemoveAudio), (c("\\"), .toggleLoop),
    (c("n", .command), .newReel), (c("o", .command), .open), (c("e", .command), .export),
    (c("z", .command), .undo), (c("z", [.shift, .command]), .redo),
    (c("=", .command), .deckZoom(1)), (c("-", .command), .deckZoom(-1)),
    (c("=", [.option, .command]), .stripZoom(1)), (c("-", [.option, .command]), .stripZoom(-1)),
    (c("0", [.option, .command]), .stripZoomFit),
    (c("?"), .keyMap), (k(.escape), .escape),
    (k(.tab), .focusNext(backwards: false)), (k(.tab, .shift), .focusNext(backwards: true)),
    (k(.returnKey), .activate),
  ]

  @Test func tableHasEveryChordOnce() {
    #expect(Self.table.map(\.0) == Self.expected.map(\.0))
    #expect(Self.table.map(\.1) == Self.expected.map(\.1))
    #expect(Set(Self.table.map(\.0)).count == Self.table.count, "a chord listed twice")
    #expect(KeyMap.bindings.count == Self.table.count)
    #expect(KeyMap.rows.allSatisfy { !$0.2.isEmpty })
  }

  @Test func chordDisplay() {
    #expect(Self.c("z", [.shift, .command]).display == "⇧⌘Z")
    #expect(Self.c("-", [.option, .command]).display == "⌥⌘−")
    #expect(Self.k(.space).display == "Space")
    #expect(Self.k(.left, .shift).display == "⇧←")
    #expect(Self.c("\\").display == "\\")
    #expect(Self.c("?").display == "?")
  }

  @Test(arguments: KeyMapTests.table) func everyRow(_ row: Row) {
    #expect(KeyMap.command(for: row.0, context: .editing) == row.1)
  }

  @Test func modalSwallowsAllButPassKeys() {
    var ctx = KeyContext.editing
    ctx.topModal = .exportSheet
    #expect(KeyMap.command(for: Self.c("i"), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.k(.space), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.k(.escape), context: ctx) == .escape)
    #expect(KeyMap.command(for: Self.k(.tab), context: ctx) == .focusNext(backwards: false))
    #expect(KeyMap.command(for: Self.k(.tab, .shift), context: ctx) == .focusNext(backwards: true))
    #expect(KeyMap.command(for: Self.k(.returnKey), context: ctx) == .activate)
    #expect(KeyMap.command(for: Self.c("?"), context: ctx) == nil)
  }

  @Test func modalPassKeysReach() {
    var ctx = KeyContext.editing
    ctx.topModal = .keyMap
    ctx.passKeys = [.keyMap]
    #expect(KeyMap.command(for: Self.c("?"), context: ctx) == .keyMap)
    #expect(KeyMap.command(for: Self.c("i"), context: ctx) == nil)
  }

  @Test func textFieldTypes() {
    var ctx = KeyContext.editing
    ctx.inTextField = true
    #expect(KeyMap.command(for: Self.c("a"), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.c("s"), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.k(.space), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.c("z", .command), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.k(.escape), context: ctx) == .escape)
    #expect(KeyMap.command(for: Self.k(.tab), context: ctx) == .focusNext(backwards: false))
    #expect(KeyMap.command(for: Self.k(.returnKey), context: ctx) == .activate)
  }

  @Test func trimKeysWaitWhileDragging() {
    var ctx = KeyContext.editing
    ctx.dragging = true
    for chord in [Self.c("i"), Self.c("o"), Self.c("i", .option), Self.c("o", .option), Self.c("s")] {
      #expect(KeyMap.command(for: chord, context: ctx) == nil)
    }
    #expect(KeyMap.command(for: Self.k(.left), context: ctx) == .step(-1))
  }

  @Test func noClipNoClipCommands() {
    var ctx = KeyContext.editing
    ctx.hasClip = false
    #expect(KeyMap.command(for: Self.c("i"), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.k(.space), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.c("e", .command), context: ctx) == nil)
    #expect(KeyMap.command(for: Self.c("o", .command), context: ctx) == .open)
    #expect(KeyMap.command(for: Self.c("n", .command), context: ctx) == .newReel)
    #expect(KeyMap.command(for: Self.c("?"), context: ctx) == .keyMap)
    #expect(KeyMap.command(for: Self.k(.escape), context: ctx) == .escape)
  }

  @Test func repeatsOnlyListed() {
    for cmd: Command in [.step(1), .jump(-1), .selectPrev, .selectNext, .moveSelection(1),
                         .undo, .redo, .deckZoom(1), .stripZoom(-1)] {
      #expect(KeyMap.repeats(cmd))
    }
    for cmd: Command in [.split, .playPause, .setIn, .toggleLoop, .stripZoomFit, .shuttle(.forward)] {
      #expect(!KeyMap.repeats(cmd))
    }
  }

  // F26: normalisation of what AppKit reports.
  @Test func normalisedQuestionMark() {
    // Shift+/ on US layout: "?" with shift reported.
    let a = KeyChord.normalised(characters: "?", mods: [.shift])
    #expect(a == Self.c("?"))
    // A layout where ? is produced another way (e.g. option or no shift): same chord.
    #expect(KeyChord.normalised(characters: "?", mods: []) == Self.c("?"))
    #expect(KeyMap.command(for: a, context: .editing) == .keyMap)
  }

  @Test func normalisedRedo() {
    let r = KeyChord.normalised(characters: "Z", mods: [.shift, .command])
    #expect(r == Self.c("z", [.shift, .command]))
    #expect(KeyMap.command(for: r, context: .editing) == .redo)
  }

  @Test func normalisedOptionLetters() {
    #expect(KeyChord.normalised(characters: "i", mods: [.option]) == Self.c("i", .option))
    #expect(KeyChord.normalised(characters: "O", mods: [.option]) == Self.c("o", .option))
    #expect(KeyMap.command(for: .normalised(characters: "i", mods: .option), context: .editing) == .resetIn)
    #expect(KeyMap.command(for: .normalised(characters: "o", mods: .option), context: .editing) == .resetOut)
  }

  @Test func normalisedBackslashAndPunctuation() {
    #expect(KeyChord.normalised(characters: "\\", mods: []) == Self.c("\\"))
    #expect(KeyChord.normalised(characters: "|", mods: [.shift]) == Self.c("|"))
    #expect(KeyChord.normalised(characters: "=", mods: [.command]) == Self.c("=", .command))
    #expect(KeyMap.command(for: .normalised(characters: "\\", mods: []), context: .editing) == .toggleLoop)
  }

  @Test func plainShiftedLetterKeepsShift() {
    // Shift+S is not Split.
    let s = KeyChord.normalised(characters: "S", mods: [.shift])
    #expect(s == Self.c("s", .shift))
    #expect(KeyMap.command(for: s, context: .editing) == nil)
  }

  @Test func commandPlusZooms() {
    // US keyboard: Shift+= reports "+" with shift held.
    func cmd(_ ch: String, _ m: Mods) -> Command? {
      KeyMap.command(for: .normalised(characters: ch, mods: m), context: .editing)
    }
    #expect(cmd("+", [.shift, .command]) == .deckZoom(1))
    #expect(cmd("+", [.shift, .option, .command]) == .stripZoom(1))
    #expect(cmd("=", [.command]) == .deckZoom(1))
    #expect(cmd("=", [.option, .command]) == .stripZoom(1))
    #expect(cmd("-", [.command]) == .deckZoom(-1))
    // Plain "+" without command is not bound.
    #expect(cmd("+", [.shift]) == nil)
  }
}
