import Foundation

public enum TCMode: String, Codable, Hashable, Sendable { case timecode, seconds }

/// User preferences. `validated` is the only way raw stored values become a `Prefs`: a bad value for one
/// key falls back to that key's default and never disturbs the others.
public struct Prefs: Codable, Hashable, Sendable {
  public var format: ExportSpec.Format
  public var quality: ExportSpec.Quality
  public var cut: ExportSpec.Cut
  public var defaultFraming: Framing
  public var removeAudioDefault: Bool
  public var loop: Bool
  public var tcMode: TCMode
  public var lastFolder: String?

  public init(
    format: ExportSpec.Format = .reel, quality: ExportSpec.Quality = .high, cut: ExportSpec.Cut = .exact,
    defaultFraming: Framing = .fill, removeAudioDefault: Bool = false, loop: Bool = true,
    tcMode: TCMode = .timecode, lastFolder: String? = nil
  ) {
    self.format = format; self.quality = quality; self.cut = cut
    self.defaultFraming = defaultFraming; self.removeAudioDefault = removeAudioDefault
    self.loop = loop; self.tcMode = tcMode; self.lastFolder = lastFolder
  }

  public static func validated(_ raw: [String: JSONValue]) -> Prefs {
    func str<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
      if case .string(let s)? = raw[key], let v = T(rawValue: s) { return v }
      return fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      if case .bool(let b)? = raw[key] { return b }
      return fallback
    }
    let d = Prefs()
    var folder: String?
    if case .string(let s)? = raw["lastFolder"], s.hasPrefix("/") { folder = s }  // absolute paths only
    return Prefs(
      format: str("format", d.format), quality: str("quality", d.quality), cut: str("cut", d.cut),
      defaultFraming: str("defaultFraming", d.defaultFraming),
      removeAudioDefault: bool("removeAudioDefault", d.removeAudioDefault), loop: bool("loop", d.loop),
      tcMode: str("tcMode", d.tcMode), lastFolder: folder)
  }
}
