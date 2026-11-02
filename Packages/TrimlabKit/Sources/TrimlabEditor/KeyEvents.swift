import TrimlabModel

/// A key event as raw values, to a `KeyChord`. No AppKit: the app's `KeyMonitor` passes what the key event reports, so the
/// routing rules are tested here.
public enum KeyEvents {
  /// The key event's modifier-flag bits (device-independent part).
  public enum Flag {
    public static let capsLock: UInt = 1 << 16
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
    public static let numericPad: UInt = 1 << 21
    public static let function: UInt = 1 << 23
  }

  /// Key codes (the physical key, whatever the layout) for the keys that aren't printable.
  private static let special: [UInt16: Key] = [
    49: .space, 36: .returnKey, 76: .returnKey,  // 76 is keypad Enter
    48: .tab, 51: .delete, 117: .forwardDelete, 53: .escape,
    123: .left, 124: .right, 125: .down, 126: .up, 115: .home, 119: .end,
  ]

  /// The Latin letter, digit or mark a key code stands for on a US layout.
  private static let latin: [UInt16: Character] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
    14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
    26: "7", 27: "-", 28: "8", 29: "0", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 41: ";",
    42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
  ]

  /// Only Shift, Option, Command and Control count: CapsLock, Fn and the numeric-pad flag (which every arrow key
  /// carries) are dropped.
  public static func mods(_ flags: UInt) -> Mods {
    var out: Mods = []
    if flags & Flag.shift != 0 { out.insert(.shift) }
    if flags & Flag.option != 0 { out.insert(.option) }
    if flags & Flag.command != 0 { out.insert(.command) }
    if flags & Flag.control != 0 { out.insert(.control) }
    return out
  }

  /// Non-printable keys are built from the key code; the rest go through `KeyChord.normalised` with the character the
  /// key produced. ⌘ chords on a non-Latin layout, and ⌥ chords whose produced character is a dead key or a symbol
  /// instead of the letter, fall back to the key code's Latin character. Nil for a key with no character (F-keys).
  public static func chord(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
                           flags: UInt) -> KeyChord? {
    let mods = mods(flags)
    if let key = special[keyCode] { return KeyChord(key: key, mods: mods) }
    var text = charactersIgnoringModifiers ?? ""
    if text.isEmpty, let c = characters { text = c }
    if let first = text.unicodeScalars.first, (0xF700...0xF8FF).contains(first.value) { return nil }
    let isLatin = text.count == 1 && (text.unicodeScalars.first?.isASCII ?? false)
    if let ch = latin[keyCode] {
      if mods.contains(.command), !isLatin { text = String(ch) }
      else if mods.contains(.option), ch.isLetter, text.lowercased() != String(ch), !isLatin || text.isEmpty {
        text = String(ch)
      }
    }
    guard !text.isEmpty else { return nil }
    return KeyChord.normalised(characters: text, mods: mods)
  }
}
