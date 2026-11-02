import Foundation
import OSLog
import Synchronization

/// Logging for the media layer. The app points `sink` at its `FileLog`; tests capture lines per task with
/// `capturing`, so suites running in parallel never share a sink.
public enum MediaLog {
  public static let logger = Logger(subsystem: "com.dcv.trimlab2", category: "media")
  /// `TRIMLAB_LOG_STDERR=1` also echoes every line to stderr (diagnosing test runs, where os_log isn't kept).
  static let echo = ProcessInfo.processInfo.environment["TRIMLAB_LOG_STDERR"] == "1"

  /// Set by the app's `FileLog`. Guarded by a lock so any thread can emit.
  public static let sink = Mutex<(@Sendable (String) -> Void)?>(nil)

  public static func setSink(_ new: (@Sendable (String) -> Void)?) {
    sink.withLock { $0 = new }
  }

  /// Logs to os.Logger, forwards the line to the sink and to the current task's capture, if any.
  public static func note(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    if echo { FileHandle.standardError.write(Data("medialog: \(message)\n".utf8)) }
    let forward = sink.withLock { $0 }
    forward?(message)
    capture?.append(message)
    recentLines.withLock { lines in
      lines.append(message)
      if lines.count > recentLimit { lines.removeFirst(lines.count - recentLimit) }
    }
  }

  // MARK: recent (the export Error view's Details)

  /// How many of the latest lines are kept in memory.
  static let recentLimit = 200
  private static let recentLines = Mutex<[String]>([])

  /// The last `n` lines noted anywhere in the process, oldest first.
  public static func recent(_ n: Int) -> [String] {
    recentLines.withLock { Array($0.suffix(max(n, 0))) }
  }

  // MARK: capture (tests)

  /// Lines noted by one task tree. Child tasks and `Task {}` inherit it; dispatch-queue callbacks don't.
  final class Capture: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
  }

  @TaskLocal static var capture: Capture?

  /// Runs `body`, returning its value and every line it (and the tasks it starts) noted.
  static func capturing<T>(_ body: () throws -> T) rethrows -> (T, [String]) {
    let c = Capture()
    let value = try $capture.withValue(c) { try body() }
    return (value, c.all)
  }

  static func capturing<T>(_ body: () async throws -> T) async rethrows -> (T, [String]) {
    let c = Capture()
    let value = try await $capture.withValue(c) { try await body() }
    return (value, c.all)
  }
}
