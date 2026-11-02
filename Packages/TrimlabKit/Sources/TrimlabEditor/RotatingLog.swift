import Foundation
import Synchronization

/// The file log (§2 Logs): `dir/name`, and when it would pass `limit` bytes it becomes `name.1` (`name.1` becomes
/// `name.2` and so on) and a new one starts, so at most `keep` files exist: `trimlab.log`, `.1`, `.2` at 1 MB × 3.
/// `tail` reads the last lines back across the files (the export Error view's Details). File I/O only; any thread.
/// A log that can't be written drops the line: logging never fails anything.
///
/// Ownership: copies share one open file behind one `Mutex`, so appends and rotation never interleave.
public struct RotatingLog: Sendable {
  public let dir: URL
  public let name: String
  public let limit: Int
  public let keep: Int
  private let state: Shared

  public init(dir: URL, name: String = "trimlab.log", limit: Int = 1_000_000, keep: Int = 3) {
    self.dir = dir
    self.name = name
    self.limit = max(limit, 1)
    self.keep = max(keep, 1)
    state = Shared()
  }

  /// The current file.
  public var url: URL { file(0) }

  /// `name` for 0, else `name.<index>` (older as the index grows).
  func file(_ index: Int) -> URL {
    dir.appending(path: index == 0 ? name : "\(name).\(index)", directoryHint: .notDirectory)
  }

  /// Writes `line` and a newline. A line that would carry the file past `limit` goes into a fresh one.
  public func append(_ line: String) {
    let bytes = Data((line + "\n").utf8)
    state.open.withLock { open in
      if open == nil { open = opened() }
      guard var current = open else { return }
      if current.size > 0, current.size + bytes.count > limit {
        try? current.handle.close()
        rotate()
        open = opened()
        guard let fresh = open else { return }
        current = fresh
      }
      do {
        try current.handle.write(contentsOf: bytes)
        current.size += bytes.count
        open = current
      } catch {
        // The file went away or the disk is full: reopen next time.
        try? current.handle.close()
        open = nil
      }
    }
  }

  /// The last `n` lines, oldest first, reaching back into the rotated files when the current one has fewer.
  public func tail(_ n: Int) -> [String] {
    guard n > 0 else { return [] }
    return state.open.withLock { _ in
      var lines: [String] = []
      for index in 0..<keep where lines.count < n {
        guard let data = try? Data(contentsOf: file(index)) else { continue }
        var own = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
          .map(String.init)
        if own.last == "" { own.removeLast() }
        lines = own.suffix(n - lines.count) + lines
      }
      return lines
    }
  }

  // MARK: files (called under the lock)

  private struct Open {
    let handle: FileHandle
    var size: Int
  }

  private final class Shared: Sendable {
    let open = Mutex<Open?>(nil)
  }

  private func opened() -> Open? {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // O_APPEND: every write lands at the end as one piece, so two copies of the app writing the same file
    // interleave whole lines instead of overwriting each other.
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      close(fd)
      return nil
    }
    return Open(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), size: Int(info.st_size))
  }

  /// Drops the oldest file and moves each of the others one place older; the current file becomes `.1`.
  private func rotate() {
    let fm = FileManager.default
    try? fm.removeItem(at: file(keep - 1))
    guard keep > 1 else { return }
    for index in stride(from: keep - 2, through: 0, by: -1) {
      try? fm.moveItem(at: file(index), to: file(index + 1))
    }
  }
}
