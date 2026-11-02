import CryptoKit
import Foundation
import Testing

/// Generated media fixtures (git-ignored) under `Packages/TrimlabKit/Tests/Fixtures/`.
/// The first call per process runs `scripts/make-fixtures.sh` when `.recipe-sha` is missing or stale.
enum Fixtures {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// Packages/TrimlabKit/Tests/Fixtures
  static let dir: URL = packageRoot.appending(path: "Tests/Fixtures", directoryHint: .isDirectory)

  private static let packageRoot: URL = {
    // .../Packages/TrimlabKit/Tests/MediaTests/Support/Fixtures.swift
    var url = URL(filePath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url
  }()

  private static var script: URL {
    packageRoot.deletingLastPathComponent().deletingLastPathComponent().appending(path: "scripts/make-fixtures.sh")
  }

  /// `static let` gives thread-safe one-time initialisation of the task; parallel tests `await` its
  /// value (suspended, not blocked) until the script finishes. Result `nil` means ready, otherwise
  /// the script's stderr. The script runs on its own thread, never a cooperative-pool thread.
  private static let prepared: Task<String?, Never> = Task { await OffPool.run { prepare() } }

  static func url(_ name: String) async throws -> URL {
    if let message = await prepared.value {
      Issue.record("make-fixtures.sh failed:\n\(message)")
      throw Failure(description: message)
    }
    let file = dir.appending(path: name)
    try #require(FileManager.default.fileExists(atPath: file.path), "missing fixture \(name)")
    return file
  }

  private static let required = [
    "portrait_hevc.mov", "rotated.mov", "landscape.mp4", "hlg.mov", "noaudio.mp4", "vfr.mp4",
    "odd.mp4", "over3.mp4", "spaced é/clip é 1.mov", "sixty.mp4", "mono44k.mov", "sample.mkv",
    "sample.avi", "theora.mkv", "keyframes.mp4", "tiny.mp4", "corrupt.mov", "notes.txt", "still.jpg", "dark.mp4",
    "bright.mp4", "tone660.mov", "shortaudio.mp4", "lateaudio.mp4", "bright60.mp4", "grain.mp4", "hlgbright.mov",
    "hlgramp.mov", "pqramp.mov",
  ]

  private static func isCurrent() -> Bool {
    guard let stamp = try? String(contentsOf: dir.appending(path: ".recipe-sha"), encoding: .utf8),
      let source = try? Data(contentsOf: script)
    else { return false }
    guard stamp == sha256Hex(source) else { return false }
    return required.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
  }

  private static func prepare() -> String? {
    if isCurrent() { return nil }
    let process = Process()
    process.executableURL = script
    process.arguments = []
    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return "could not run \(script.path): \(error)"
    }
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let text = String(decoding: err, as: UTF8.self)
      return text.isEmpty ? "exit status \(process.terminationStatus)" : text
    }
    return nil
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
