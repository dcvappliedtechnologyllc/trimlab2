import Foundation
import TrimlabMedia

/// The launch sweep of export temporaries a crash or force quit left behind (Task 23 and Task 36 carries), in the
/// folders trimlab has exported to: the last export's (`Prefs.lastFolder`) and the open Reel's. The remux cache has
/// its own sweep (`MediaCache.sweepOrphans`). Only regular files whose names match exactly, and only once they're a
/// day old (an export may be running in another copy of the app): anything else is never touched.
///
/// The names, `<8 hex>` being the lower-case tag `ExportRunner.partialURL` and `LiveMediaServices.standIn` pick:
/// - `<stem>.<8 hex>.partial.<ext>`: a Reel or Quick export being written;
/// - `<stem>.<8 hex>.replacing.<ext>`: a Replace export's finished stand-in, not yet swapped in;
/// - `<stem>.<8 hex>.replacing.<8 hex>.partial.<ext>`: the stand-in being written (the first form's stem ends in
///   `.replacing`);
/// - either partial form followed by `.sb-<letters, digits, hyphens>`: the temporary the writer's network-use pass
///   (`shouldOptimizeForNetworkUse`) makes beside a partial, left if the app quit during that pass.
public enum ExportSweep {
  public static let age: TimeInterval = 86_400

  /// Whether `name` is one of the forms above. The stem must be non-empty; `ext` is letters and digits.
  public static func isOrphan(_ name: String) -> Bool {
    isOrphan(name, pattern: makePattern())
  }

  private static func isOrphan(_ name: String, pattern: Regex<Substring>) -> Bool {
    name.wholeMatch(of: pattern) != nil
  }

  /// A fresh matcher for every caller: a `Regex` isn't `Sendable` and two sweeps can run at once (the launch warm-up
  /// and a Reel opened from Finder), so none is shared.
  private static func makePattern() -> Regex<Substring> {
    /.+\.[0-9a-f]{8}\.(?:partial\.[A-Za-z0-9]{1,8}(?:\.sb-[A-Za-z0-9-]+)?|replacing\.[A-Za-z0-9]{1,8})/
  }

  /// The folders to sweep: `lastFolder` (an absolute path) and the Reel's export folder, each once.
  public static func folders(lastFolder: String?, reelFolder: URL?) -> [URL] {
    var out: [URL] = []
    var seen: Set<String> = []
    var candidates: [URL] = []
    if let lastFolder, lastFolder.hasPrefix("/") { candidates.append(URL(filePath: lastFolder, directoryHint: .isDirectory)) }
    if let reelFolder, reelFolder.isFileURL, reelFolder.path.hasPrefix("/") { candidates.append(reelFolder) }
    for url in candidates {
      let clean = url.standardizedFileURL
      var path = clean.path
      while path.count > 1, path.hasSuffix("/") { path.removeLast() }
      guard seen.insert(path).inserted else { continue }
      out.append(URL(filePath: path, directoryHint: .isDirectory))
    }
    return out
  }

  /// Removes the orphans older than `age` seconds directly in each folder (not in subfolders); how many went.
  @discardableResult
  public static func sweep(folders: [URL], olderThan age: TimeInterval = age) -> Int {
    let fm = FileManager.default
    let cutoff = Date(timeIntervalSinceNow: -age)
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
    var seen: Set<String> = []
    var removed = 0
    let pattern = makePattern()
    for folder in folders {
      guard seen.insert(folder.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { continue }
      guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else {
        continue
      }
      for file in entries where isOrphan(file.lastPathComponent, pattern: pattern) {
        guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true,
              values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff
        else { continue }
        do {
          try fm.removeItem(at: file)
          removed += 1
          MediaLog.note("sweep: removed \(file.lastPathComponent) in \(folder.lastPathComponent)")
        } catch {
          MediaLog.note("sweep: couldn't remove \(file.lastPathComponent) in \(folder.lastPathComponent): \(error)")
        }
      }
    }
    return removed
  }
}
