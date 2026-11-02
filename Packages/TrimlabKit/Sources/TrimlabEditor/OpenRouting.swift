import Foundation

/// Where Finder "Open With", a Dock drop, Open Recent and `-TLOpen` URLs go (Task 39). Pure: no AppKit.
public enum OpenRouting {
  /// `.trimlab` files (any case) are projects; everything else (movies and folders) is media, which the import
  /// pipeline classifies and skips what it can't open. Order is kept.
  public static func route(_ urls: [URL]) -> (projects: [URL], media: [URL]) {
    var projects: [URL] = []
    var media: [URL] = []
    for url in urls {
      if url.pathExtension.lowercased() == "trimlab" { projects.append(url) } else { media.append(url) }
    }
    return (projects, media)
  }

  /// The paths after `-TLOpen`, up to the next argument that starts with `-` (the smoke test's way in).
  public static func launchURLs(arguments: [String]) -> [URL] {
    guard let flag = arguments.firstIndex(of: "-TLOpen") else { return [] }
    return arguments[(flag + 1)...].prefix(while: { !$0.hasPrefix("-") }).map { URL(filePath: $0) }
  }

  /// The folder after `-TLExportFolder`: where a new Reel's exports go, instead of its first clip's folder. The smoke
  /// test's way to keep its output out of the fixtures; nil without the flag, or with no path after it.
  public static func exportFolderOverride(arguments: [String]) -> String? {
    guard let flag = arguments.firstIndex(of: "-TLExportFolder"), flag + 1 < arguments.count else { return nil }
    let path = arguments[flag + 1]
    return path.hasPrefix("-") || path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path
  }
}

/// A FIFO of open events that arrived before the model existed (Finder launches the app with the file, so
/// `application(_:open:)` can run before the window does). Never dropped (Task 27 ruling): `attach` delivers
/// everything queued as ONE batch (so "last project, then media" holds across the backlog), once; later events go
/// straight to the handler. Before attach, a URL already pending is not queued twice (`-TLOpen` plus the same
/// path arriving as an open event during launch).
@MainActor
public final class OpenBacklog {
  private var pending: [[URL]] = []
  private var deliver: (([URL]) -> Void)?

  public init() {}

  public func enqueue(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    if let deliver { deliver(urls); return }
    let known = Set(pending.joined().map { $0.standardizedFileURL.path })
    let fresh = urls.filter { !known.contains($0.standardizedFileURL.path) }
    if !fresh.isEmpty { pending.append(fresh) }
  }

  public func attach(_ handler: @escaping ([URL]) -> Void) {
    guard deliver == nil else { return }
    deliver = handler
    let queued = Array(pending.joined())
    pending = []
    if !queued.isEmpty { handler(queued) }
  }
}
