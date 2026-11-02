import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import TrimlabMedia
import TrimlabModel

/// `MediaServices` over `Prober`, `Importer`, `MediaCache` and `SourceResolver`.
public struct LiveMediaServices: MediaServices {
  public let cache: MediaCache
  /// The export running now, for `cancelExport`.
  private let exports = ExportControl()
  /// The file log's last lines (`RotatingLog.tail`, through the app's `FileLog`): the Error view's Details. nil
  /// (tests, previews) reads the in-memory `MediaLog.recent` instead.
  private let logTail: (@Sendable (Int) -> [String])?
  /// Makes every `AVURLAsset` these services hand out (tests count where they are freed).
  private let makeAsset: @Sendable (_ url: URL, _ precise: Bool) -> AVURLAsset

  public init(cache: MediaCache = MediaCache(), logTail: (@Sendable (Int) -> [String])? = nil) {
    self.init(cache: cache, logTail: logTail, makeAsset: { url, precise in
      AVURLAsset(url: url, options: precise ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil)
    })
  }

  init(cache: MediaCache, logTail: (@Sendable (Int) -> [String])?,
       makeAsset: @escaping @Sendable (_ url: URL, _ precise: Bool) -> AVURLAsset) {
    self.cache = cache
    self.logTail = logTail
    self.makeAsset = makeAsset
  }

  /// For the app at launch, off the main actor: warms the GPU state the first preview and HDR frame need
  /// (`MediaWarmup.prepare`: the Metal device, `HDRToSDR`'s LUT pipeline, the compositor's context), then sweeps
  /// what a crash or force quit left behind, a day old or more: interrupted remuxes in the cache and export
  /// temporaries in `exportFolders` (`ExportSweep`), and prunes the cache to its limit, least recently used first
  /// (§4.6). Nothing is kept by name here: the Reel opened at launch prunes again with its clips kept.
  @concurrent
  public func warmUp(sweeping exportFolders: [URL] = []) async {
    await MediaWarmup.prepare()
    cache.sweepOrphans(olderThan: ExportSweep.age)
    ExportSweep.sweep(folders: exportFolders)
    await cache.prune(keeping: [])
  }

  public func importItem(_ url: URL) async -> ImportItem { await Prober.importItem(for: url) }

  public func probe(_ url: URL, ref: SourceRef) async throws -> ClipFacts {
    let playable = try await Importer.playableURL(source: url, ref: ref, ffmpeg: FFmpegLocation.find(), cache: cache)
    return try await Prober.facts(for: url, playableURL: playable)
  }

  public func sourceRef(_ url: URL, projectFolder: URL?) throws -> SourceRef {
    try Prober.sourceRef(for: url, projectFolder: projectFolder)
  }

  public func poster(_ clip: ReelClip, at url: URL) async throws -> CGImage {
    try await cache.poster(for: clip.source, asset: asset(for: clip, at: url))
  }

  public func sprite(_ clip: ReelClip, at url: URL) async throws -> Sprite {
    try await cache.sprite(for: clip.source, asset: asset(for: clip, at: url))
  }

  public func peaks(_ clip: ReelClip, at url: URL) async throws -> [Float16] {
    try await cache.peaks(for: clip.source, asset: asset(for: clip, at: url))
  }

  public func keyframes(_ clip: ReelClip, at url: URL) async throws -> KeyframeIndex {
    try await cache.keyframes(for: clip.source, asset: asset(for: clip, at: url))
  }

  public func asset(_ clip: ReelClip, at url: URL) async throws -> AVURLAsset {
    let playable = try await Importer.playableURL(source: url, ref: clip.source, ffmpeg: FFmpegLocation.find(),
                                                  cache: cache)
    return makeAsset(playable, true)
  }

  public func quickBytes(_ clip: ReelClip, at url: URL, range: Range<RationalTime>, includeAudio: Bool) async -> Int64 {
    guard let asset = try? await asset(clip, at: url) else { return 0 }
    return await QuickCut.sampleBytes(asset: asset, range: range, includeAudio: includeAudio)
  }

  public func ffmpegAvailable() -> Bool { FFmpegLocation.find() != nil }

  public func resolve(_ clip: ReelClip, projectFolder: URL?) -> URL? {
    SourceResolver.resolve(clip.source, projectFolder: projectFolder,
                           fileExists: { FileManager.default.fileExists(atPath: $0) })
  }

  @concurrent
  public func pruneCache(keeping refs: [SourceRef]) async {
    await cache.prune(keeping: Set(refs.map { cache.key(for: $0) }))
  }

  // MARK: export

  public func export(reel: Reel, dest: URL, sources: [UUID: URL], quick: RationalTime?,
                     replacing: Bool) -> AsyncThrowingStream<ExportEvent, Error> {
    let (stream, out) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
    // One at a time: an earlier export still tidying up is never orphaned by a new one.
    guard let generation = exports.begin() else {
      out.finish(throwing: ExportFailed(error: .other("An export is already running."), cause: nil))
      return stream
    }
    let cache = self.cache
    let exports = self.exports
    let task = Task {
      defer { exports.end(generation) }
      // The slot is freed before the stream ends, so whoever sees the end may start the next export at once.
      func close(_ error: (any Error)? = nil) {
        exports.end(generation)
        if let error { out.finish(throwing: error) } else { out.finish() }
      }
      // Replace never replaces a folder, whatever the sheet let through (M-4).
      if replacing, ExportPreflight.isDirectory(dest) {
        MediaLog.note("export: \(dest.lastPathComponent) is a folder; not replacing it")
        close(ExportFailed(error: .notReplaced(name: dest.lastPathComponent, oldKept: true, keptAs: nil), cause: nil))
        return
      }
      // Replace: the new file is written beside the old one and swapped in only once it's complete.
      let target = replacing ? Self.standIn(for: dest) : dest
      do {
        // The files the export reads: each clip's playable file (the cached remux for .mkv/.avi).
        var playable: [UUID: URL] = [:]
        for clip in reel.clips {
          guard let url = sources[clip.id] else { continue }
          playable[clip.id] = try await Importer.playableURL(source: url, ref: clip.source,
                                                             ffmpeg: FFmpegLocation.find(), cache: cache)
        }
        let inner: AsyncThrowingStream<ExportEvent, Error>
        let cause: @Sendable () -> ExportCause?
        if let start = quick, let clip = reel.clips.first, let url = playable[clip.id] {
          let cut = QuickCut()
          guard exports.attach(.quick(cut), generation) else { throw CancellationError() }
          inner = cut.start(clip: clip, url: url, dest: target, removeAudio: reel.export.removeAudio, snappedIn: start)
          cause = { cut.lastFailureCause }
        } else {
          let files = playable
          let runner = ExportRunner(resolve: { files[$0.id] })
          guard exports.attach(.reel(runner), generation) else { throw CancellationError() }
          inner = runner.start(reel: reel, dest: target)
          cause = { runner.lastFailureCause }
        }
        do {
          for try await event in inner {
            guard case .done(let result) = event, replacing else {
              out.yield(event)
              continue
            }
            out.yield(.done(try Self.swapIn(result, over: dest)))
          }
          close()
        } catch let error as ExportError {
          close(ExportFailed(error: error, cause: cause()))
        }
      } catch let error as ExportFailed {
        close(error)
      } catch is CancellationError {
        close(CancellationError())
      } catch let error as ExportError {
        close(ExportFailed(error: error, cause: nil))
      } catch {
        // A .mkv/.avi whose remux went missing, and anything else before the export began.
        close(ExportFailed(error: .sourceUnreadable(nil), cause: ExportCause(error)))
      }
    }
    out.onTermination = { reason in
      if case .cancelled = reason { task.cancel() }
    }
    return stream
  }

  @discardableResult
  public func cancelExport() async -> Bool { await exports.cancel() }

  public func recentLog(_ lines: Int) -> [String] { logTail?(lines) ?? MediaLog.recent(lines) }

  /// `<stem>.<8 hex>.replacing.<ext>` beside `dest`: what a Replace export writes until it's complete.
  static func standIn(for dest: URL) -> URL {
    let stem = dest.deletingPathExtension().lastPathComponent
    let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    return dest.deletingLastPathComponent().appending(path: "\(stem).\(tag).replacing.\(dest.pathExtension)")
  }

  /// Puts the finished stand-in where the old file was (or simply at `dest` if the old one has gone meanwhile). If that
  /// fails, the new file is kept beside the old one under a Keep-both name and the failure says which is where.
  static func swapIn(_ result: ExportResult, over dest: URL,
                     replace: (URL, URL) throws -> Void = { dest, new in
                       _ = try FileManager.default.replaceItemAt(dest, withItemAt: new)
                     }) throws -> ExportResult {
    let fm = FileManager.default
    do {
      if ExportPreflight.isDirectory(dest) { throw CocoaError(.fileWriteFileExists) }  // a folder appeared meanwhile
      if fm.fileExists(atPath: dest.path) { try replace(dest, result.url) } else { try fm.moveItem(at: result.url, to: dest) }
      MediaLog.note("export: replaced \(dest.lastPathComponent)")
      return ExportResult(url: dest, bytes: result.bytes, firstFrame: result.firstFrame,
                          usedSoftwareEncoder: result.usedSoftwareEncoder)
    } catch {
      MediaLog.note("export: couldn't replace \(dest.lastPathComponent): \(error)")
      let folder = dest.deletingLastPathComponent()
      let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
      let keepName = Naming.keepBoth(dest.lastPathComponent, existing: existing)
      var keptAs: String?
      if (try? fm.moveItem(at: result.url, to: folder.appending(path: keepName))) != nil {
        keptAs = keepName
        MediaLog.note("export: kept the new file as \(keepName)")
      }
      let failure = ExportError.notReplaced(name: dest.lastPathComponent, oldKept: fm.fileExists(atPath: dest.path),
                                            keptAs: keptAs)
      throw ExportFailed(error: failure, cause: ExportCause(error))
    }
  }

  /// The clip's playable asset (a cached remux for .mkv/.avi).
  private func asset(for clip: ReelClip, at url: URL) async throws -> AVURLAsset {
    let playable = try await Importer.playableURL(source: url, ref: clip.source, ffmpeg: FFmpegLocation.find(),
                                                  cache: cache)
    return makeAsset(playable, false)
  }
}

/// The real preview (§5.3).
extension PreviewEngine: PreviewDriving {}

/// `ProjectStore` on the disk; writes go through `ProjectFile.write` (atomic, refuses to replace another Reel).
public struct LiveProjectStore: ProjectStore {
  public init() {}

  public func write(_ data: Data, to url: URL, reelID: UUID) throws {
    try ProjectFile.write(data, to: url, reelID: reelID)
  }

  public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

  public func isWritable(_ folder: URL) -> Bool { FileManager.default.isWritableFile(atPath: folder.path) }

  public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  public func isFolder(_ url: URL) -> Bool {
    var folder: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
  }

  public func list(_ folder: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
  }

  public func makeFolder(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  public func move(_ from: URL, to: URL, reelID: UUID) throws(ProjectMoveError) {
    try ProjectFile.move(from, to: to, reelID: reelID)
  }
}

/// The one export `LiveMediaServices` runs at a time, so `cancelExport` reaches it. A cancel that arrives before the
/// runner exists (while the sources are resolved) stops it as it's attached.
///
/// Ownership: all state behind one `Mutex`.
final class ExportControl: Sendable {
  enum Running: Sendable {
    case reel(ExportRunner), quick(QuickCut)
  }

  private struct State {
    var generation = 0
    var running: Running?
    /// From `begin` until `end`: an export is live even before its runner exists.
    var starting = false
    var cancelled = false
  }

  private let state = Mutex(State())

  /// Longest `cancel` waits, after the runner has answered, for the export to let go of the slot (the same 2.5 s as
  /// `ExportRunner.cancelWait`, which is internal to the media layer).
  static let freeWait = Duration.milliseconds(2500)

  /// A new export: its generation, which every later call names. nil while an earlier one is still running.
  func begin() -> Int? {
    state.withLock { s -> Int? in
      guard s.running == nil, !s.starting else { return nil }
      s.starting = true
      s.generation += 1
      s.running = nil
      s.cancelled = false
      return s.generation
    }
  }

  /// false when this export was cancelled (or replaced) before its runner existed.
  func attach(_ running: Running, _ generation: Int) -> Bool {
    state.withLock { s in
      guard s.generation == generation, !s.cancelled else { return false }
      s.running = running
      return true
    }
  }

  func end(_ generation: Int) {
    state.withLock { s in
      guard s.generation == generation else { return }
      s.running = nil
      s.starting = false
    }
  }

  /// Cancels the running export and waits for it (at most `ExportRunner.cancelWait`); true if it stopped it. A cancel
  /// before the runner exists stops the export as it's attached, which counts as stopped. Either way it returns only
  /// once the export has let go of the slot (`end`), so a new export started on the answer is never refused as
  /// "already running"; false if that takes longer than `freeWait` after the runner's own wait.
  func cancel() async -> Bool {
    let (running, live, generation) = state.withLock { s -> (Running?, Bool, Int) in
      if s.starting { s.cancelled = true }
      return (s.running, s.starting, s.generation)
    }
    let deadline = ContinuousClock.now + Self.freeWait
    let stopped: Bool
    switch running {
    case .reel(let runner)?: stopped = await runner.cancel()
    case .quick(let cut)?: stopped = await cut.cancel()
    case nil: stopped = live
    }
    guard live else { return stopped }
    while isLive(generation), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    return stopped && !isLive(generation)
  }

  /// Whether export `generation` has not yet ended.
  private func isLive(_ generation: Int) -> Bool {
    state.withLock { $0.generation == generation && $0.starting }
  }
}
