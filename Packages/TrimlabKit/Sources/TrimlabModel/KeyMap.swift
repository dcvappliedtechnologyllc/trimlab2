// KeyMap: the §4.7 key table as a pure function. No AppKit.
//
// Dispatch contract (honoured by whoever feeds this: KeyMonitor, the menu bar):
// - While a text field has focus the dispatcher sets `KeyContext.inTextField`; only Esc, Tab and Return then map,
//   everything else must reach the field untouched.
// - Build chords with `KeyChord.normalised(characters:mods:)` from the *produced* character
//   (`charactersIgnoringModifiers`), never from key codes, so `?` and `\` work on every keyboard layout.
// - `normalised` is for printable keys only. Space, Esc, Tab, Return, Delete, forward Delete, arrows and
//   Home/End come from key codes and are built directly as `Key` cases; never send them through `normalised`.

public struct Mods: OptionSet, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let shift = Mods(rawValue: 1 << 0)
  public static let option = Mods(rawValue: 1 << 1)
  public static let command = Mods(rawValue: 1 << 2)
  public static let control = Mods(rawValue: 1 << 3)
}

public enum Key: Hashable, Sendable {
  case char(Character)
  case space, left, right, up, down, home, end, delete, forwardDelete, escape, tab, returnKey
}

public struct KeyChord: Hashable, Sendable {
  public var key: Key
  public var mods: Mods
  public init(key: Key, mods: Mods = []) { self.key = key; self.mods = mods }

  /// Normalises what AppKit reports (F26). Letters become lower case and keep Shift (⇧⌘Z arrives as "Z"
  /// plus shift, and is the chord ⇧⌘z). Other printable characters drop Shift, because the produced
  /// character already carries it (`?` is "?", not ⇧"/" or ⇧"?").
  public static func normalised(characters: String, mods: Mods) -> KeyChord {
    guard characters.count == 1, let ch = characters.first else {
      return KeyChord(key: .char(characters.lowercased().first ?? " "), mods: mods)
    }
    if ch.isLetter {
      return KeyChord(key: .char(Character(ch.lowercased())), mods: mods)
    }
    // US layout: ⌘+ is Shift+= and arrives as "+"; fold it onto the "=" binding.
    if ch == "+" && mods.contains(.command) {
      return KeyChord(key: .char("="), mods: mods.subtracting(.shift))
    }
    return KeyChord(key: .char(ch), mods: mods.subtracting(.shift))
  }
}

extension KeyChord {
  /// The chord as a key cap shows it: modifiers in Apple's order (⌃⌥⇧⌘), then the key ("⇧⌘Z", "⌥⌘−", "Space").
  public var display: String {
    var out = ""
    if mods.contains(.control) { out += "⌃" }
    if mods.contains(.option) { out += "⌥" }
    if mods.contains(.shift) { out += "⇧" }
    if mods.contains(.command) { out += "⌘" }
    switch key {
    case .char("-"): out += "−"
    case .char(let ch): out += ch.uppercased()
    case .space: out += "Space"
    case .left: out += "←"
    case .right: out += "→"
    case .up: out += "↑"
    case .down: out += "↓"
    case .home: out += "Home"
    case .end: out += "End"
    case .delete: out += "⌫"
    case .forwardDelete: out += "⌦"
    case .escape: out += "Esc"
    case .tab: out += "Tab"
    case .returnKey: out += "Return"
    }
    return out
  }
}

public enum ShuttleDir: Hashable, Sendable { case back, stop, forward }

public enum Command: Hashable, Sendable {
  case playPause, step(Int), jump(Int), selectPrev, selectNext, moveSelection(Int), shuttle(ShuttleDir)
  case toIn, toLastKept, toReelStart, toReelEnd
  case setIn, setOut, resetIn, resetOut, split, toggleJoin, toggleFraming
  case deleteSelection, selectAll, toggleRemoveAudio, toggleLoop
  case newReel, open, export, undo, redo
  case deckZoom(Int), stripZoom(Int), stripZoomFit
  case keyMap, escape, focusNext(backwards: Bool), activate
}

public struct KeyContext: Sendable {
  public var hasClip: Bool
  public var dragging: Bool
  public var inTextField: Bool
  public var topModal: ModalID?
  public var passKeys: Set<Command>
  public init(hasClip: Bool, dragging: Bool, inTextField: Bool, topModal: ModalID?, passKeys: Set<Command>) {
    self.hasClip = hasClip; self.dragging = dragging; self.inTextField = inTextField
    self.topModal = topModal; self.passKeys = passKeys
  }
  /// A Reel with clips open, nothing held, no field focused, no modal.
  public static let editing = KeyContext(hasClip: true, dragging: false, inTextField: false, topModal: nil, passKeys: [])
}

public enum KeyMap {
  static func c(_ s: Character, _ m: Mods = []) -> KeyChord { KeyChord(key: .char(s), mods: m) }
  static func k(_ key: Key, _ m: Mods = []) -> KeyChord { KeyChord(key: key, mods: m) }

  /// Every key, in §4.7's order, with the words of its §4.7 row (Tab and Return, from §4.10, close the list). Chords
  /// that share a row share its words, so the key map overlay draws one line per row from this one table.
  public static let rows: [(KeyChord, Command, String)] = {
    let play = "Play / pause the Reel"
    let stepText = "Step one frame (Reel time; source time in peek)"
    let jumpText = "Jump 1 s"
    let clipText = "Previous / next clip (select, playhead to its In)"
    let moveText = "Move the selected clips one place earlier / later"
    let shuttleText = "Shuttle back / stop / forward (repeat for 2×, 4×)"
    let homeText = "Playhead to the clip's In / last kept frame (Out exclusive) · Reel start / last frame"
    let trimText = "Set In / Out at the deck playhead · reset In to source start / Out to source end"
    let audioLoop = "Toggle remove audio / loop"
    let files = "New Reel / Open clips or a Reel… / Export…"
    let undoText = "Undo / redo (whole Reel)"
    let stripText = "Strip zoom in / out / fit"
    let tabText = "Next / previous control"
    return [
      (k(.space), .playPause, play),
      (k(.left), .step(-1), stepText), (k(.right), .step(1), stepText),
      (k(.left, .shift), .jump(-1), jumpText), (k(.right, .shift), .jump(1), jumpText),
      (k(.up), .selectPrev, clipText), (k(.down), .selectNext, clipText),
      (k(.left, .option), .moveSelection(-1), moveText), (k(.right, .option), .moveSelection(1), moveText),
      (c("j"), .shuttle(.back), shuttleText), (c("k"), .shuttle(.stop), shuttleText),
      (c("l"), .shuttle(.forward), shuttleText),
      (k(.home), .toIn, homeText), (k(.end), .toLastKept, homeText),
      (k(.home, .shift), .toReelStart, homeText), (k(.end, .shift), .toReelEnd, homeText),
      (c("i"), .setIn, trimText), (c("o"), .setOut, trimText),
      (c("i", .option), .resetIn, trimText), (c("o", .option), .resetOut, trimText),
      (c("s"), .split, "Split at playhead"),
      (c("x"), .toggleJoin, "Toggle crossfade into the clip"),
      (c("f"), .toggleFraming, "Toggle Fill / Fit on the selection"),
      (k(.delete), .deleteSelection, "Delete the selected clips"),
      (k(.forwardDelete), .deleteSelection, "Delete the selected clips"),
      (c("a", .command), .selectAll, "Select all clips"),
      (c("a"), .toggleRemoveAudio, audioLoop), (c("\\"), .toggleLoop, audioLoop),
      (c("n", .command), .newReel, files), (c("o", .command), .open, files), (c("e", .command), .export, files),
      (c("z", .command), .undo, undoText), (c("z", [.shift, .command]), .redo, undoText),
      (c("=", .command), .deckZoom(1), "Deck zoom"), (c("-", .command), .deckZoom(-1), "Deck zoom"),
      (c("=", [.option, .command]), .stripZoom(1), stripText), (c("-", [.option, .command]), .stripZoom(-1), stripText),
      (c("0", [.option, .command]), .stripZoomFit, stripText),
      (c("?"), .keyMap, "Key map overlay"),
      (k(.escape), .escape, "Close the top overlay or sheet; cancel a drag; clear a multi-selection"),
      (k(.tab), .focusNext(backwards: false), tabText), (k(.tab, .shift), .focusNext(backwards: true), tabText),
      (k(.returnKey), .activate, "Press the focused control"),
    ]
  }()

  static let bindings: [KeyChord: Command] = Dictionary(rows.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

  /// Commands that work with an empty Reel.
  static func needsClip(_ cmd: Command) -> Bool {
    switch cmd {
    case .newReel, .open, .undo, .redo, .keyMap, .escape, .focusNext, .activate: false
    default: true
    }
  }

  static func isTrimKey(_ cmd: Command) -> Bool {
    switch cmd {
    case .setIn, .setOut, .resetIn, .resetOut, .split: true
    default: false
    }
  }

  public static func command(for chord: KeyChord, context: KeyContext) -> Command? {
    guard let cmd = bindings[chord] else { return nil }
    if let _ = context.topModal {
      switch cmd {
      case .escape, .focusNext, .activate: return cmd
      default: return context.passKeys.contains(cmd) ? cmd : nil
      }
    }
    if context.inTextField {
      switch cmd {
      case .escape, .focusNext, .activate: return cmd
      default: return nil
      }
    }
    if context.dragging && isTrimKey(cmd) { return nil }
    if !context.hasClip && needsClip(cmd) { return nil }
    return cmd
  }

  /// Held-key repeat: arrows, undo/redo, zoom (§4.7).
  public static func repeats(_ cmd: Command) -> Bool {
    switch cmd {
    case .step, .jump, .selectPrev, .selectNext, .moveSelection, .undo, .redo, .deckZoom, .stripZoom: true
    default: false
    }
  }
}
