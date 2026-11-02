import Foundation
import TrimlabModel

/// The prefs (§4.11) in a `UserDefaults` domain: one plain value per field, under the field's name, so
/// `defaults read com.dcv.trimlab2` shows them. Reading goes only through `Prefs.validated` (Task 16 carry): a bad
/// stored value falls back to that key's default and never disturbs the others. The app's `PrefsStore` passes its
/// own domain; tests pass a throwaway suite.
public struct PrefsDefaults {
  public static let keys = ["format", "quality", "cut", "defaultFraming", "removeAudioDefault", "loop", "tcMode",
                            "lastFolder"]
  let defaults: UserDefaults

  public init(defaults: UserDefaults) { self.defaults = defaults }

  public func load() -> Prefs {
    var raw: [String: JSONValue] = [:]
    for key in Self.keys {
      if let value = defaults.object(forKey: key).flatMap(Self.json) { raw[key] = value }
    }
    return Prefs.validated(raw)
  }

  /// Writes every field (nil `lastFolder` removes its key).
  public func save(_ prefs: Prefs) {
    defaults.set(prefs.format.rawValue, forKey: "format")
    defaults.set(prefs.quality.rawValue, forKey: "quality")
    defaults.set(prefs.cut.rawValue, forKey: "cut")
    defaults.set(prefs.defaultFraming.rawValue, forKey: "defaultFraming")
    defaults.set(prefs.removeAudioDefault, forKey: "removeAudioDefault")
    defaults.set(prefs.loop, forKey: "loop")
    defaults.set(prefs.tcMode.rawValue, forKey: "tcMode")
    if let folder = prefs.lastFolder { defaults.set(folder, forKey: "lastFolder") } else {
      defaults.removeObject(forKey: "lastFolder")
    }
  }

  /// A stored property-list value as JSON: strings, real booleans (not 0/1 numbers) and numbers; anything else nil.
  static func json(_ value: Any) -> JSONValue? {
    if let s = value as? String { return .string(s) }
    if let n = value as? NSNumber {
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
      return .number(n.doubleValue)
    }
    return nil
  }
}
