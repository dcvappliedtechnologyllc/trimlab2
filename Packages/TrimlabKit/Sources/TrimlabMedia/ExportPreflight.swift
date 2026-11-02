import Foundation
import TrimlabModel

/// What stops (or needs a word before) an export to a destination (§4.9).
public enum PreflightIssue: Equatable, Sendable {
  /// The destination is one of the Reel's clips or its project file: "That's one of the Reel's files."
  case isReelFile
  /// A clip's source can't be found; the clip's file name.
  case missing(String)
  /// Some other file is already there (Replace / Keep both).
  case exists
  /// A folder is already there under the destination's name: never replaced.
  case isFolder
  case folderUnwritable
}

/// §4.9 destination checks, in the order the sheet shows them.
public enum ExportPreflight {
  /// Paths are compared standardised, symlink-resolved and case-insensitively (APFS's default), against every
  /// clip's resolved source (its recorded path when unresolved) and the project file. `isFolder` is asked about the
  /// destination itself, `isWritable` about its folder.
  /// about the destination's folder.
  public static func check(dest: URL, reel: Reel, projectFile: URL?, resolve: (ReelClip) -> URL?,
                           fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                           isFolder: (URL) -> Bool = { ExportPreflight.isDirectory($0) },
                           isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) })
    -> PreflightIssue?
  {
    let resolved = reel.clips.map { (clip: $0, url: resolve($0)) }
    let target = key(dest)
    let reelFiles = resolved.map { $0.url ?? URL(filePath: $0.clip.source.absolutePath) } + [projectFile].compactMap { $0 }
    if reelFiles.contains(where: { key($0) == target }) { return .isReelFile }
    if let missing = resolved.first(where: { $0.url == nil }) {
      return .missing(URL(filePath: missing.clip.source.absolutePath).lastPathComponent)
    }
    if isFolder(dest) { return .isFolder }  // before `.exists`: a folder is never offered for Replace
    if fileExists(dest) { return .exists }
    if !isWritable(dest.deletingLastPathComponent()) { return .folderUnwritable }
    return nil
  }

  /// Whether a directory (not a link to one) is at `url`.
  public static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
      .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
  }

  /// The comparable form of a file path. The folder is symlink-resolved (the file itself may not exist yet);
  /// an existing file that is itself a link resolves too.
  static func key(_ url: URL) -> String {
    let standard = url.standardizedFileURL
    let folder = standard.deletingLastPathComponent().resolvingSymlinksInPath()
    var file = folder.appending(path: standard.lastPathComponent)
    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      file = file.resolvingSymlinksInPath()
    }
    return file.path.precomposedStringWithCanonicalMapping.lowercased()
  }
}
