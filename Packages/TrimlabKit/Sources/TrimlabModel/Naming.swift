import Foundation

/// Default file names (§4.9, §8.2).
public enum Naming {
  /// One clip: v1's `<stem>_<in>-<out>.mp4` (`IMG_4821_0m03s-0m18s.mp4`). Otherwise `<Reel name>.mp4`.
  public static func exportFileName(_ r: Reel) -> String {
    guard r.clips.count == 1, let clip = r.clips.first else { return "\(r.name).mp4" }
    let stem = URL(filePath: clip.source.absolutePath, directoryHint: .notDirectory).deletingPathExtension().lastPathComponent
    return "\(stem)_\(stamp(clip.inTime))-\(stamp(clip.outTime)).mp4"
  }

  /// `~/Movies/trimlab 2/`: where a Reel is saved, and an export goes by default, when the clips' folder is read-only.
  public static let fallbackFolder = URL.moviesDirectory.appending(path: "trimlab 2", directoryHint: .isDirectory)

  /// v1's `MAX_STEM_BYTES`: 255 is the APFS name limit, and the stem also has to fit the export's partial file and a
  /// Keep-both " NN".
  public static let maxStemBytes = 220
  /// The video extensions a typed name loses (v1 `SUPPORTED_EXTS`).
  static let videoExtensions = ["mov", "mp4", "m4v", "mkv", "mts", "avi"]

  /// v1 `sanitize_filename`: a safe name ending in `ext` (".mp4"): no "/", ":" or control characters, no leading dots
  /// or spaces, a typed video extension replaced by `ext`, the stem at most 220 bytes of UTF-8 (cut at a whole
  /// character); "trimlab-export" when nothing is left.
  public static func sanitized(_ name: String, ext: String) -> String {
    (safeStem(name) ?? "trimlab-export") + ext
  }

  /// `sanitized`'s stem, or nil when nothing is left of `name` (the Reel name treats that as nothing typed).
  public static func safeStem(_ name: String) -> String? {
    var s = String(String.UnicodeScalarView(name.unicodeScalars.filter {
      $0 != "/" && $0 != ":" && $0.value >= 0x20 && $0.value != 0x7f
    }))
    s = s.trimmingCharacters(in: .whitespaces)
    s = String(s.drop { $0 == "." || $0.isWhitespace }).trimmingCharacters(in: .whitespaces)
    let lower = s.lowercased()
    if let dot = videoExtensions.first(where: { lower.hasSuffix("." + $0) }) {
      s = String(s.dropLast(dot.count + 1)).trimmingCharacters(in: .whitespaces)
    }
    guard !s.isEmpty else { return nil }
    var stem = ""
    var bytes = 0
    for ch in s {
      let n = String(ch).utf8.count
      if bytes + n > maxStemBytes { break }
      stem.append(ch)
      bytes += n
    }
    let out = stem.trimmingCharacters(in: .whitespaces)
    return out.isEmpty ? nil : out
  }

  /// `<folder name>.trimlab`, then `<folder name> 2.trimlab`, `… 3.trimlab`.
  public static func projectFileName(folder: URL, existing: Set<String>) -> String {
    keepBoth("\(folder.lastPathComponent).trimlab", existing: existing)
  }

  /// `name` if it's free, else the first free `<stem> N<.ext>` from 2 up. Case-insensitive, like APFS by default.
  public static func keepBoth(_ name: String, existing: Set<String>) -> String {
    let taken = Set(existing.map { $0.lowercased() })
    if !taken.contains(name.lowercased()) { return name }
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var n = 2
    while true {
      let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
      if !taken.contains(candidate.lowercased()) { return candidate }
      n += 1
    }
  }

  /// v1 `fmt_stamp`: whole seconds floored, `<m>m<ss>s`.
  static func stamp(_ t: RationalTime) -> String {
    let whole = max(t.floored(toFrame: RationalTime(1, 1)).value, 0)
    let seconds = whole % 60
    return "\(whole / 60)m\(seconds < 10 ? "0" : "")\(seconds)s"
  }
}
