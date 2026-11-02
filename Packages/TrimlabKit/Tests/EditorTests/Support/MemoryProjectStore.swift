import Foundation
import Synchronization
import TrimlabEditor
import TrimlabModel

/// `ProjectStore` over a dictionary of path → bytes. A folder exists when some file lies under it.
final class MemoryProjectStore: ProjectStore {
  let files = Mutex<[String: Data]>([:])
  let readOnlyFolders = Mutex<Set<String>>([])
  /// Folders that exist even with nothing in them.
  let emptyFolders = Mutex<Set<String>>([])

  init(files paths: [String] = []) {
    files.withLock { f in for p in paths { f[p] = Data() } }
  }

  func add(_ path: String, _ data: Data = Data()) { files.withLock { $0[path] = data } }
  func addFolder(_ path: String) { emptyFolders.withLock { _ = $0.insert(path) } }

  /// Paths whose writes fail as a disk error would (`ProjectWriteError.failed`), though their folder is writable.
  let failing = Mutex<Set<String>>([])
  /// Every successful write's path, in order.
  let writes = Mutex<[String]>([])
  /// Folders `makeFolder` was asked for.
  let madeFolders = Mutex<[String]>([])

  /// While held, every write waits at its start (off the main actor) until `releaseWrites()`: a slow disk.
  private let gate = Mutex<(held: Bool, started: Int, waiting: Int)>((false, 0, 0))
  private let opened = DispatchSemaphore(value: 0)

  func holdWrites() { gate.withLock { $0.held = true } }
  func releaseWrites() {
    let waiting = gate.withLock { g -> Int in
      g.held = false
      defer { g.waiting = 0 }
      return g.waiting
    }
    for _ in 0..<waiting { opened.signal() }
  }

  /// Returns once `n` writes have reached the store; false after `timeout` (a failing test, not a hang).
  func waitForWriteStarted(_ n: Int, timeout: Duration = .seconds(20)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while gate.withLock({ $0.started }) < n {
      if ContinuousClock.now > deadline { return false }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return true
  }

  /// The Reel name in each successful write, in order.
  var savedNames: [String] {
    names.withLock { $0 }
  }
  private let names = Mutex<[String]>([])

  /// As `ProjectFile.write`: an existing file is replaced only if it decodes and holds the same Reel.
  func write(_ data: Data, to url: URL, reelID: UUID) throws {
    let wait = gate.withLock { g -> Bool in
      g.started += 1
      if g.held { g.waiting += 1 }
      return g.held
    }
    if wait { opened.wait() }
    if failing.withLock({ $0.contains(url.path) }) { throw ProjectWriteError.failed("stub: disk error") }
    if let existing = files.withLock({ $0[url.path] }) {
      guard let reel = try? ProjectCodec.decode(existing) else { throw ProjectWriteError.wouldReplaceRefusedFile }
      guard reel.id == reelID else { throw ProjectWriteError.wouldReplaceAnotherReel }
    }
    files.withLock { $0[url.path] = data }
    writes.withLock { $0.append(url.path) }
    if let reel = try? ProjectCodec.decode(data) { names.withLock { $0.append(reel.name) } }
  }

  func makeFolder(_ url: URL) throws {
    madeFolders.withLock { $0.append(url.path) }
    addFolder(url.path)
  }

  /// Every successful move, in order, as `from → to`.
  let moves = Mutex<[String]>([])

  /// Paths whose moves fail as a read-only folder would (`ProjectMoveError.failed`).
  let failingMoves = Mutex<Set<String>>([])

  /// As `ProjectFile.move`: anything at `to` (a file, a folder, any case) refuses, unless it's `from` itself; a file
  /// at `from` holding another Reel (or one that can't be read) isn't moved.
  func move(_ from: URL, to: URL, reelID: UUID) throws(ProjectMoveError) {
    let (a, b) = (from.path, to.path)
    if failingMoves.withLock({ $0.contains(a) }) { throw .failed("stub: read-only") }
    if let data = files.withLock({ $0[a] }), (try? ProjectCodec.decode(data))?.id != reelID { throw .anotherReel }
    let lower = b.lowercased()
    let takenByFile = files.withLock { f in f.keys.contains { $0.lowercased() == lower || $0.lowercased().hasPrefix(lower + "/") } }
    let takenByFolder = emptyFolders.withLock { $0.contains { $0.lowercased() == lower } }
    if (takenByFile || takenByFolder) && a.lowercased() != lower { throw .taken }
    let moved = files.withLock { f -> Bool in
      guard let data = f.removeValue(forKey: a) else { return false }
      f[b] = data
      return true
    }
    guard moved else { throw .noFile }
    moves.withLock { $0.append("\(a) → \(b)") }
  }

  var writeLog: [String] { writes.withLock { $0 } }
  func data(_ path: String) -> Data? { files.withLock { $0[path] } }

  func read(_ url: URL) throws -> Data {
    let path = url.standardizedFileURL.path  // as the disk would: `day2/../x` is `x`
    guard let data = files.withLock({ $0[path] }) else { throw CocoaError(.fileReadNoSuchFile) }
    return data
  }

  func isWritable(_ folder: URL) -> Bool { !readOnlyFolders.withLock { $0.contains(folder.path) } }

  func exists(_ url: URL) -> Bool {
    let path = url.path
    return files.withLock { f in f[path] != nil || f.keys.contains { $0.hasPrefix(path + "/") } }
  }

  func isFolder(_ url: URL) -> Bool {
    let path = url.path
    return emptyFolders.withLock { $0.contains(path) } || files.withLock { f in f.keys.contains { $0.hasPrefix(path + "/") } }
  }

  /// The names directly inside `folder`: files and subfolders.
  func list(_ folder: URL) -> [String] {
    let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
    let names = files.withLock { f in
      f.keys.compactMap { key -> String? in
        guard key.hasPrefix(prefix) else { return nil }
        return key.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
      }
    }
    return Array(Set(names)).sorted()
  }
}
