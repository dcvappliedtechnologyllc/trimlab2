import Foundation

/// Finds a clip's file again on reopen (§7.1, §8.2).
public enum SourceResolver {
  /// The relative path first (against the `.trimlab` file's folder), then the absolute path, then the file name in
  /// the project folder (ruling: recovers a moved project folder whose clips had no relative path). Nil when none
  /// exists, which makes the clip "Missing". Pure path work: the only disk access is `fileExists`.
  public static func resolve(_ ref: SourceRef, projectFolder: URL?,
                             fileExists: (String) -> Bool) -> URL? {
    if let relative = ref.relativePath, !relative.isEmpty, let folder = projectFolder {
      let url = folder.appending(path: relative, directoryHint: .notDirectory).standardizedFileURL
      if fileExists(url.path) { return url }
    }
    if !ref.absolutePath.isEmpty, fileExists(ref.absolutePath) {
      return URL(filePath: ref.absolutePath, directoryHint: .notDirectory).standardizedFileURL
    }
    if let folder = projectFolder, !ref.absolutePath.isEmpty {
      let fileName = URL(filePath: ref.absolutePath, directoryHint: .notDirectory).lastPathComponent
      let url = folder.appending(path: fileName, directoryHint: .notDirectory).standardizedFileURL
      if fileExists(url.path) { return url }
    }
    return nil
  }
}

extension Reel {
  /// Every clip's `relativePath` measured again from `folder` (the one the project file is written to); nil for a
  /// clip outside it. Path work only; the disk is read just to resolve symlinks. `saveNow` calls it on every write.
  public func rebasingRelativePaths(to folder: URL) -> Reel {
    // Normalised as `Prober.sourceRef` does, so /var and /private/var (or any symlinked folder) agree.
    let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
    let prefix = base.hasSuffix("/") ? base : base + "/"
    var out = self
    for i in out.clips.indices {
      let file = URL(filePath: out.clips[i].source.absolutePath, directoryHint: .notDirectory)
        .resolvingSymlinksInPath().standardizedFileURL.path
      out.clips[i].source.relativePath = file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : nil
    }
    return out
  }
}
