import AVFoundation
import Foundation
import Synchronization
import TrimlabModel

public enum ImportError: Error, Equatable, Sendable {
  case needsFFmpeg
  case remuxFailed(String)
  case formatWontPlay

  /// The command shown beside the `needsFFmpeg` sentence.
  public static let needsFFmpegCommand = "brew install ffmpeg-full"

  /// `ext` is the source's extension without the dot, e.g. "mkv".
  public func sentence(ext: String) -> String {
    switch self {
    case .needsFFmpeg: "trimlab needs ffmpeg to open .mkv and .avi files. Install it with Homebrew:"
    case .remuxFailed: "Can't open this .\(ext): ffmpeg couldn't convert it."
    case .formatWontPlay: "Can't open this .\(ext): its video format won't play on a Mac."
    }
  }
}

/// Remuxes `.mkv` / `.avi` to `.mov` in the cache with `ffmpeg -c copy` (§5.6). Never re-encodes, never used for export.
public final class Importer: Sendable {
  public static let shared = Importer()

  /// Convenience for the app: shares one `Importer`, so concurrent callers coalesce.
  public static func playableURL(source: URL, ref: SourceRef, ffmpeg: FFmpegLocation?,
                                 cache: MediaCache) async throws -> URL {
    try await shared.playableURL(source: source, ref: ref, ffmpeg: ffmpeg, cache: cache)
  }

  /// Test seams. `commandOverride` replaces the whole argv (given the real argv and the tmp output URL);
  /// `onLaunch` receives the child's pid; `onValidate` runs just before the tmp file is checked for playback.
  typealias CommandOverride = @Sendable (_ argv: [String], _ tmp: URL) -> [String]
  private let commandOverride: CommandOverride?
  private let onLaunch: (@Sendable (pid_t) -> Void)?
  private let onValidate: (@Sendable () async -> Void)?
  private let launches = Mutex(0)
  /// Test hook: how many child processes this importer has launched.
  var launchCount: Int { launches.withLock { $0 } }

  private struct Flight {
    let token: UUID
    let task: Task<URL, any Error>
    var awaiters: Int
  }
  private let flights = Mutex<[String: Flight]>([:])

  public init() {
    commandOverride = nil
    onLaunch = nil
    onValidate = nil
  }

  init(commandOverride: CommandOverride? = nil, onLaunch: (@Sendable (pid_t) -> Void)? = nil,
       onValidate: (@Sendable () async -> Void)? = nil) {
    self.commandOverride = commandOverride
    self.onLaunch = onLaunch
    self.onValidate = onValidate
  }

  // MARK: playableURL

  /// The URL AVFoundation should open for the clip at `source` (the resolved file; `ref` only keys the cache, so
  /// a stale `ref.absolutePath` after a project move doesn't matter). Anything but .mkv/.avi comes back as `source`.
  /// Throws only `ImportError` or, when the caller is cancelled, `CancellationError`; the child ffmpeg is then
  /// terminated and its partial output deleted.
  public func playableURL(source: URL, ref: SourceRef, ffmpeg: FFmpegLocation?,
                          cache: MediaCache) async throws -> URL {
    guard Prober.remuxExtensions.contains(source.pathExtension.lowercased()) else { return source }
    try Task.checkCancellation()

    let output = cache.remuxURL(for: ref)
    if FileManager.default.fileExists(atPath: output.path) {
      cache.touch(ref)
      return output
    }
    guard let ffmpeg else { throw ImportError.needsFFmpeg }

    let id = output.path
    // The task is created inside the lock and only when no flight exists, so a losing caller starts nothing.
    let flight = flights.withLock { table -> Flight in
      if var existing = table[id] {
        existing.awaiters += 1
        table[id] = existing
        return existing
      }
      let token = UUID()
      let task = Task<URL, any Error> {
        defer { self.flights.withLock { if $0[id]?.token == token { $0[id] = nil } } }
        return try await self.remux(source: source, output: output, ffmpeg: ffmpeg)
      }
      let fresh = Flight(token: token, task: task, awaiters: 1)
      table[id] = fresh
      return fresh
    }

    do {
      let url = try await withTaskCancellationHandler {
        try await flight.task.value
      } onCancel: {
        self.leave(id, token: flight.token)
      }
      try Task.checkCancellation()
      return url
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  /// The last awaiter to leave cancels the shared remux.
  private func leave(_ id: String, token: UUID) {
    let doomed: Task<URL, any Error>? = flights.withLock { table in
      guard var flight = table[id], flight.token == token else { return nil }
      flight.awaiters -= 1
      if flight.awaiters <= 0 {
        table[id] = nil
        return flight.task
      }
      table[id] = flight
      return nil
    }
    doomed?.cancel()
  }

  // MARK: remux

  /// ffmpeg → a hidden tmp file → checked for playback → renamed to `remux.mov`, so `remux.mov` only ever holds a
  /// remux that plays.
  private func remux(source: URL, output: URL, ffmpeg: FFmpegLocation) async throws -> URL {
    let fm = FileManager.default
    let dir = output.deletingLastPathComponent()
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      MediaLog.note("import: could not make the cache folder \(dir.path): \(error)")
      throw ImportError.remuxFailed("Couldn't make the cache folder: \(error.localizedDescription)")
    }
    if fm.fileExists(atPath: output.path) { return output }  // another process finished it

    let tmp = dir.appending(path: ".remux.\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).mov")
    var argv = [ffmpeg.ffmpeg.path, "-hide_banner", "-y", "-i", source.path, "-c", "copy", "-map", "0",
                "-movflags", "+faststart", tmp.path]
    if let commandOverride { argv = commandOverride(argv, tmp) }
    MediaLog.note("import: \(argv.joined(separator: " "))")

    do {
      let (status, stderr) = try await run(argv)
      try Task.checkCancellation()
      guard status == 0 else { throw ImportError.remuxFailed(stderr) }
      await onValidate?()
      let plays = await Self.isPlayable(tmp)
      // A cancelled check reads as "doesn't play"; it must end as a cancel, not as a broken file.
      try Task.checkCancellation()
      guard plays else {
        MediaLog.note("import: \(source.lastPathComponent) remuxed but does not play")
        throw ImportError.formatWontPlay
      }
      guard rename(tmp.path, output.path) == 0 else {
        throw ImportError.remuxFailed("could not move the remuxed file into the cache (errno \(errno))")
      }
    } catch {
      try? fm.removeItem(at: tmp)
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      if let error = error as? ImportError { throw error }
      MediaLog.note("import: \(source.lastPathComponent) failed: \(error)")
      throw ImportError.remuxFailed(error.localizedDescription)
    }
    return output
  }

  private static func isPlayable(_ url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    guard let playable = try? await asset.load(.isPlayable), playable else { return false }
    guard let video = try? await asset.loadTracks(withMediaType: .video), !video.isEmpty else { return false }
    return true
  }

  // MARK: process

  private struct RunState {
    var process: Process?
    var cancelled = false
  }

  /// Runs `argv` (no shell), draining stderr as it arrives. On task cancel: SIGTERM, then SIGKILL after 1 s.
  /// A program that isn't there or can't be run is `needsFFmpeg`; any other launch failure is `remuxFailed`.
  private func run(_ argv: [String]) async throws -> (status: Int32, stderr: String) {
    try Task.checkCancellation()
    guard FileManager.default.isExecutableFile(atPath: argv[0]) else {
      MediaLog.note("import: \(argv[0]) is missing or not executable")
      throw ImportError.needsFFmpeg
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardError = pipe

    let state = Mutex(RunState())
    let reader = pipe.fileHandleForReading

    return try await withTaskCancellationHandler {
      // Drain on its own thread until EOF so a chatty child can never fill the pipe.
      async let tail: String = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          var buffer = Data()
          while case let chunk = reader.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            if buffer.count > 128 * 1024 { buffer = buffer.suffix(64 * 1024) }
          }
          continuation.resume(returning: Self.lastLines(buffer, 30))
        }
      }
      let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
          try state.withLock { s in
            if s.cancelled { throw CancellationError() }
            try process.run()
            s.process = process
          }
          launches.withLock { $0 += 1 }
          onLaunch?(process.processIdentifier)
        } catch {
          try? pipe.fileHandleForWriting.close()  // lets the reader hit EOF
          if error is CancellationError {
            continuation.resume(throwing: error)
          } else {
            MediaLog.note("import: could not launch \(argv[0]): \(error)")
            let ns = error as NSError
            let missing = ns.domain == NSCocoaErrorDomain
              && [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadNoPermissionError].contains(ns.code)
            continuation.resume(throwing: missing ? ImportError.needsFFmpeg
                                                  : ImportError.remuxFailed(error.localizedDescription))
          }
        }
      }
      return (status, await tail)
    } onCancel: {
      state.withLock { s in
        s.cancelled = true
        if let p = s.process, p.isRunning { Self.terminate(p) }
      }
    }
  }

  private static func terminate(_ process: Process) {
    process.terminate()
    let pid = process.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
      if process.isRunning { kill(pid, SIGKILL) }
    }
  }

  static func lastLines(_ data: Data, _ count: Int) -> String {
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return lines.suffix(count).joined(separator: "\n")
  }
}
