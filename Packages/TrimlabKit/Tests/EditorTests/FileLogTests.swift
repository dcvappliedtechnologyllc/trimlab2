import Foundation
import Testing
@testable import TrimlabEditor

/// `RotatingLog`: the file behind `~/Library/Logs/trimlab 2/trimlab.log` (§2 logs, 1 MB × 3) and the export Error
/// view's last 30 lines. File I/O only, in a fresh temporary folder per test.
@Suite struct FileLogTests {
  private func freshDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rotatinglog-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func exists(_ dir: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: dir.appending(path: name).path)
  }

  private func size(_ dir: URL, _ name: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: dir.appending(path: name).path))?[.size] as? Int) ?? -1
  }

  @Test func rotatesAt1MB() {
    let dir = freshDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    // 25 000 lines of 100 bytes (99 + the newline): 2.5 MB.
    let body = String(repeating: "x", count: 93)
    for i in 0..<25_000 { log.append(String(format: "%05d ", i % 100_000) + body) }
    #expect(exists(dir, "trimlab.log"))
    #expect(exists(dir, "trimlab.log.1"))
    #expect(exists(dir, "trimlab.log.2"))
    #expect(!exists(dir, "trimlab.log.3"))
    for name in ["trimlab.log", "trimlab.log.1", "trimlab.log.2"] { #expect(size(dir, name) <= 1_000_000) }
    #expect(size(dir, "trimlab.log") == 500_000)
    // The newest line is in the current file; the oldest 0.5 MB fell off the end.
    #expect(log.tail(1).last?.hasPrefix("24999 ") == true)
  }

  @Test func tailReturnsLastN() {
    let dir = freshDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    for i in 0..<100 { log.append("line \(i)") }
    let tail = log.tail(30)
    #expect(tail.count == 30)
    #expect(tail.first == "line 70")
    #expect(tail.last == "line 99")
  }

  @Test func tailReachesIntoTheRotatedFile() {
    let dir = freshDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 10-byte lines, 100-byte files: every 10th line starts a new file.
    let log = RotatingLog(dir: dir, name: "trimlab.log", limit: 100, keep: 3)
    for i in 0..<25 { log.append(String(format: "line %04d", i)) }
    #expect(log.tail(30).count == 25)
    #expect(log.tail(12) == (13..<25).map { String(format: "line %04d", $0) })
  }

  @Test func tailOfNothingIsEmpty() {
    let dir = freshDir()
    let log = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    #expect(log.tail(30).isEmpty)
    #expect(log.tail(0).isEmpty)
  }

  @Test func appendsToAnExistingFile() {
    let dir = freshDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3).append("first run")
    let again = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    again.append("second run")
    #expect(again.tail(30) == ["first run", "second run"])
  }

  /// Two copies of the app on one file (O_APPEND): each line lands whole at the end, none overwrites another.
  @Test func twoWritersOnOneFileInterleaveWholeLines() {
    let dir = freshDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    let b = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    a.append("a1")
    b.append("b1")
    a.append("a2")
    b.append("b2")
    #expect(a.tail(30) == ["a1", "b1", "a2", "b2"])
  }

  @Test func concurrentAppendsKeepWholeLines() async {
    let dir = freshDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = RotatingLog(dir: dir, name: "trimlab.log", limit: 1_000_000, keep: 3)
    await withTaskGroup(of: Void.self) { group in
      for t in 0..<8 {
        group.addTask { for i in 0..<200 { log.append("t\(t) line \(i)") } }
      }
    }
    let all = log.tail(10_000)
    #expect(all.count == 1600)
    #expect(all.allSatisfy { $0.hasPrefix("t") && $0.contains(" line ") })
  }
}
