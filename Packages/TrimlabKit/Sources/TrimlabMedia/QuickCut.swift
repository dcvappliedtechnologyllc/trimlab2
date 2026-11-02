import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import TrimlabModel

/// Why Quick is or isn't offered (§4.9, §5.7). The tooltip copy lives in the UI.
public enum QuickRule: Equatable, Sendable {
  case allowed, needsSingleOriginal, cantConvertHDR
}

/// §5.7. A stream-copy cut of one clip: `AVAssetExportSession` passthrough of a single-asset composition,
/// `[snappedIn, Out)`, into `<stem>.<hex>.partial.<ext>`, renamed to the destination on success. No re-encode,
/// no software fallback.
///
/// Ownership: the only mutable state is the `ExportSlot` (and the last failure's cause, behind a `Mutex`). The
/// export session itself is touched only by the export task (start) and by `cancel()`'s `cancelExport()`, which
/// AVFoundation allows from any thread.
public final class QuickCut: @unchecked Sendable {
  /// `AVAssetExportSession` isn't Sendable; this is handed to the export task and to `cancel()` only.
  struct SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
  }

  private let slot = ExportSlot<SessionBox>()
  private let cause = Mutex<ExportCause?>(nil)

  /// What the last failed cut's error was mapped from; nil when trimlab raised it itself, or nothing failed.
  public var lastFailureCause: ExportCause? { cause.withLock { $0 } }

  public init() {}

  // MARK: rules and keyframe

  public static func isAllowed(_ r: Reel) -> QuickRule {
    guard r.clips.count == 1, r.export.format == .original else { return .needsSingleOriginal }
    if r.clips[0].facts.hdr != .sdr, r.export.convertHDR { return .cantConvertHDR }
    return .allowed
  }

  /// The last keyframe at or before the clip's In: where the cut really starts, shown before export.
  public static func snappedIn(for asset: AVURLAsset, clip: ReelClip, index: KeyframeIndex) -> RationalTime {
    index.snappedIn(clip.inTime)
  }

  /// `.mov` for ProRes, `.mp4` otherwise.
  public static func fileType(for clip: ReelClip) -> AVFileType {
    clip.facts.videoCodec == "prores" ? .mov : .mp4
  }

  /// `dest` with its extension swapped to match `fileType(for:)`.
  public static func destination(for clip: ReelClip, dest: URL) -> URL {
    dest.deletingPathExtension().appendingPathExtension(fileType(for: clip) == .mov ? "mov" : "mp4")
  }

  // MARK: size

  /// Sum of the source sample sizes (bytes) in `range` (source time): video from the keyframe at `range.lowerBound`
  /// in decode order, and audio when `includeAudio`.
  public static func sampleBytes(asset: AVURLAsset, range: Range<RationalTime>, includeAudio: Bool = true) async -> Int64 {
    var total: Int64 = 0
    let kinds: [AVMediaType] = includeAudio ? [.video, .audio] : [.video]
    for kind in kinds {
      guard let tracks = try? await asset.loadTracks(withMediaType: kind) else { continue }
      for track in tracks {
        let segments = (try? await track.load(.segments)) ?? []
        var offset = CMTime.zero
        if let seg = segments.first(where: { !$0.isEmpty }) {
          offset = seg.timeMapping.target.start - seg.timeMapping.source.start
        }
        // Cursor times are media time; the range is track time.
        let start = CMTime(range.lowerBound) - offset
        let end = CMTime(range.upperBound) - offset
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: start) else { continue }
        repeat {
          if cursor.decodeTimeStamp >= end { break }
          total += Int64(cursor.currentSampleStorageRange.length)
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
      }
    }
    return total
  }

  // MARK: start / cancel

  /// Ending the stream's iteration early cancels the export. `dest`'s extension is swapped per
  /// `fileType(for:)`; the result's `url` is where the file ended up.
  public func start(clip: ReelClip, url: URL, dest: URL, removeAudio: Bool,
                    snappedIn: RationalTime) -> AsyncThrowingStream<ExportEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
    let started = slot.start { token in
      await self.run(token: token, clip: clip, url: url, dest: dest, removeAudio: removeAudio,
                     snappedIn: snappedIn, continuation: continuation)
    }
    if !started {
      continuation.finish(throwing: ExportError.other("An export is already running."))
      return stream
    }
    continuation.onTermination = { [weak self] reason in
      if case .cancelled = reason, let self { Task { await self.cancel() } }
    }
    return stream
  }

  /// Stops the export and returns once the partial is deleted and the stream has ended with `CancellationError`,
  /// or after `ExportRunner.cancelWait` if that is slower (Quit waits ≤ 3 s; the cut then finishes on its own). A
  /// no-op when nothing is running; an export already renaming isn't stopped, but is waited for.
  /// true when it stopped the cut (nothing was saved); false otherwise, as `ExportRunner.cancel`.
  @discardableResult
  public func cancel() async -> Bool {
    let outcome = await slot.cancel(upTo: ExportRunner.cancelWait, abort: { $0.session.cancelExport() })
    if outcome == .timedOut { MediaLog.note("quick: cancel still tidying up after \(ExportRunner.cancelWait); returning") }
    return outcome == .stopped
  }

  // MARK: run

  private func run(token: UUID, clip: ReelClip, url: URL, dest finalDest: URL, removeAudio: Bool,
                   snappedIn: RationalTime,
                   continuation: AsyncThrowingStream<ExportEvent, Error>.Continuation) async {
    let dest = Self.destination(for: clip, dest: finalDest)
    let partial = ExportRunner.partialURL(for: dest)
    func release() { slot.release(token) }
    func isCancelled() -> Bool { slot.isCancelled(token, ifGone: false) }
    do {
      let name = URL(filePath: clip.source.absolutePath).lastPathComponent
      guard FileManager.default.isReadableFile(atPath: url.path) else { throw ExportError.sourceUnreadable(name) }
      if FileManager.default.fileExists(atPath: dest.path) {
        throw ExportError.other("\(dest.lastPathComponent) already exists.")
      }
      let session = try await Self.makeSession(clip: clip, url: url, partial: partial, removeAudio: removeAudio,
                                               snappedIn: snappedIn, name: name)
      let box = SessionBox(session: session)
      if slot.attach(box, to: token) { throw CancellationError() }
      MediaLog.note("quick: \(name) [\(snappedIn.seconds), \(clip.outTime.seconds)) → \(dest.lastPathComponent)")

      let meter = Mutex(ProgressMeter())
      try await Self.exportReportingProgress(box, to: partial, as: Self.fileType(for: clip)) { progress in
        if let event = meter.withLock({ $0.offer(progress, now: Self.now()) }) {
          continuation.yield(.progress(event.progress, eta: event.eta))
        }
      }
      if isCancelled() { throw CancellationError() }

      let firstFrame = await Self.firstFrame(of: partial)
      guard slot.claimRename(token) else { throw CancellationError() }
      try FileManager.default.moveItem(at: partial, to: dest)
      let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
      MediaLog.note("quick: done \(dest.lastPathComponent), \(bytes) bytes")
      continuation.yield(.progress(1, eta: 0))
      release()
      continuation.yield(.done(ExportResult(url: dest, bytes: bytes, firstFrame: firstFrame,
                                            usedSoftwareEncoder: false)))
      continuation.finish()
    } catch {
      // `partial` is this export's own name, so whatever is at it is ours.
      try? FileManager.default.removeItem(at: partial)
      let cancelled = isCancelled() || error is CancellationError
      release()
      if cancelled {
        MediaLog.note("quick: cancelled \(dest.lastPathComponent)")
        continuation.finish(throwing: CancellationError())
      } else {
        let mapped = ExportError(error)
        let underlying = ExportCause(error)
        cause.withLock { $0 = underlying }
        MediaLog.note("quick: failed \(dest.lastPathComponent): \(error) → \(mapped.sentence)"
          + (underlying.map { " [\($0.domain) \($0.code)]" } ?? ""))
        continuation.finish(throwing: mapped)
      }
    }
  }

  /// Passthrough session over a composition holding only `[snappedIn, Out)` of the clip's tracks.
  private static func makeSession(clip: ReelClip, url: URL, partial: URL, removeAudio: Bool,
                                  snappedIn: RationalTime, name: String) async throws -> AVAssetExportSession {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let range = CMTimeRange(start: CMTime(snappedIn), end: CMTime(clip.outTime))
    let composition = AVMutableComposition()
    do {
      guard try await asset.load(.isReadable) else { throw ExportError.sourceUnreadable(name) }
      guard let video = try await asset.loadTracks(withMediaType: .video).first,
            let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw ExportError.sourceUnreadable(name) }
      try target.insertTimeRange(range, of: video, at: .zero)
      // Rotation lives in the track transform; a composition track doesn't inherit it.
      target.preferredTransform = try await video.load(.preferredTransform)
      if !removeAudio, let audio = try await asset.loadTracks(withMediaType: .audio).first,
         let audioTarget = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try audioTarget.insertTimeRange(range, of: audio, at: .zero)
      }
    } catch let error as ExportError {
      throw error
    } catch {
      throw ExportError.sourceUnreadable(name)
    }
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
      throw ExportError.other("The cut couldn't be set up.")
    }
    session.shouldOptimizeForNetworkUse = true
    return session
  }

  /// Runs the export (macOS 15 `export(to:as:)`) while reading `states(updateInterval: 0.1)` for progress.
  private static func exportReportingProgress(_ box: SessionBox, to partial: URL, as type: AVFileType,
                                              onProgress: @escaping @Sendable (Double) -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in box.session.states(updateInterval: 0.1) {
          if case .exporting(let progress) = state {
            onProgress(progress.fractionCompleted)
          }
        }
      }
      group.addTask { try await box.session.export(to: partial, as: type) }
      // The export ends the states sequence; either child's failure cancels the other.
      do {
        try await group.waitForAll()
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  /// Frame at the start of the written file; nil (logged) when it can't be read, which never fails the cut.
  private static func firstFrame(of file: URL) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    do {
      return try await generator.image(at: .zero).image
    } catch {
      MediaLog.note("quick: no thumbnail for \(file.lastPathComponent): \(error)")
      return nil
    }
  }

  private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
