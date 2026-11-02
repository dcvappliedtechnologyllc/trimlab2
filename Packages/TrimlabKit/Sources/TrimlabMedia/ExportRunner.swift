import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Synchronization
import TrimlabModel

/// One encode attempt of an export: the first, and (after `encoderFailed`) one software retry.
struct Attempt: Sendable, Equatable {
  let number: Int
  let software: Bool
}

/// §5.5. Reel → reader (video composition + audio mix) → constant-frame-rate writer → `<dest>.partial.mp4`,
/// renamed to `dest` on success. One export at a time. An `encoderFailed` attempt is retried once with the
/// software encoder (never after any other failure, so never after `diskFull`).
///
/// Ownership: the runner's own mutable state (the active export) is its `ExportSlot`. Each export's reader,
/// writer and CFR state live in an `ExportJob`, on that job's queues (one per writer input; see `ExportJob`).
/// An export that writes nothing for `stallLimit` fails with `ExportError.stalled` rather than hang.
public final class ExportRunner: @unchecked Sendable {
  private let resolve: @Sendable (ReelClip) -> URL?
  private let audioStage: any AudioStage
  /// Test seam: called as each attempt starts writing; a non-nil error fails that attempt after its first frame
  /// as if the writer had reported it.
  private let testHook: (@Sendable (Attempt) -> ExportError?)?
  /// Test seam: false makes every attempt come back without a thumbnail.
  private let makesThumbnail: Bool
  /// An export that writes nothing for this long fails with `.stalled` instead of hanging.
  private let stallLimit: Duration
  /// Test seam: called on the video pump before each grid frame (may block, as a stuck read would).
  private let frameHook: (@Sendable (Int64) -> Void)?
  /// Test seam: handed each attempt's job as it is made.
  private let onJob: (@Sendable (ExportJob) -> Void)?
  private let slot = ExportSlot<ExportJob>()
  /// The system error behind the last export that failed (`ExportCause`), for the Details disclosure.
  private let cause = Mutex<ExportCause?>(nil)

  /// What the last failed export's error was mapped from; nil when trimlab raised it itself, or nothing failed.
  public var lastFailureCause: ExportCause? { cause.withLock { $0 } }

  /// Default for `stallLimit`. The watchdog counts every sign of life (appends, compositor requests, the file
  /// growing), so only a pipeline where nothing moves runs this long: under 12 concurrent exports, 12 spinning
  /// threads and a load average of 200 no such gap passed 3 s (hang-report.md); appends alone paused 5 s there.
  public static let defaultStallLimit = Duration.seconds(20)

  public convenience init(resolve: @escaping @Sendable (ReelClip) -> URL?,
                          audioStage: any AudioStage = IdentityAudioStage()) {
    self.init(resolve: resolve, audioStage: audioStage, testHook: nil)
  }

  init(resolve: @escaping @Sendable (ReelClip) -> URL?, audioStage: any AudioStage = IdentityAudioStage(),
       testHook: (@Sendable (Attempt) -> ExportError?)?, makesThumbnail: Bool = true,
       stallLimit: Duration = ExportRunner.defaultStallLimit, frameHook: (@Sendable (Int64) -> Void)? = nil,
       onJob: (@Sendable (ExportJob) -> Void)? = nil) {
    self.onJob = onJob
    self.resolve = resolve
    self.audioStage = audioStage
    self.testHook = testHook
    self.makesThumbnail = makesThumbnail
    self.stallLimit = stallLimit
    self.frameHook = frameHook
  }

  /// `software` asks for VideoToolbox's software encoder and is recorded in the result. Ending the stream's
  /// iteration early cancels the export.
  public func start(reel: Reel, dest: URL, software: Bool = false) -> AsyncThrowingStream<ExportEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
    let started = slot.start { token in
      await self.run(token: token, reel: reel, dest: dest, software: software, continuation: continuation)
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

  /// Longest `cancel()` waits for the export to tidy up (§4.9: Quit waits ≤ 3 s).
  static let cancelWait = Duration.milliseconds(2500)

  /// Stops the reader and writer, deletes the partial file and ends the stream with `CancellationError`.
  /// Returns once that is done, or after `cancelWait` if teardown is slower (it then finishes on its own).
  /// A no-op when nothing is running or the export is already renaming.
  /// true when it stopped the export (nothing was saved); false when nothing was running, the export had already
  /// finished writing, or teardown outlasted `cancelWait`.
  @discardableResult
  public func cancel() async -> Bool {
    let outcome = await slot.cancel(upTo: Self.cancelWait, abort: { $0.abort() })
    if outcome == .timedOut { MediaLog.note("export: cancel still tidying up after \(Self.cancelWait); returning") }
    return outcome == .stopped
  }

  // MARK: run

  private func run(token: UUID, reel: Reel, dest: URL, software: Bool,
                   continuation: AsyncThrowingStream<ExportEvent, Error>.Continuation) async {
    // A name no other file has, so everything at it is this export's own and safe to delete. Each attempt gets a
    // fresh one: a failed attempt's late teardown (`ExportJob.fail`'s backstop path) deletes its own writer's
    // files, which must never be the retry's.
    var partial = Self.partialURL(for: dest, ext: "mp4")
    let meter = Mutex(ProgressMeter())
    // Free the slot before the stream ends, so a caller may start the next export as soon as it sees the end.
    func release() { slot.release(token) }
    func removePartial() async {
      try? FileManager.default.removeItem(at: partial)
      // A cancelled or failed writer never removes its temporary itself, so there is nothing to wait for.
      await Self.clearWriterTemporaries(of: partial, waiting: false)
    }
    // Progress runs on across a retry: the second attempt's events resume once it passes the first's.
    let onProgress: @Sendable (Double) -> Void = { progress in
      if let event = meter.withLock({ $0.offer(progress, now: Self.now()) }) {
        continuation.yield(.progress(event.progress, eta: event.eta))
      }
    }
    var attempt = Attempt(number: 1, software: software)
    do {
      var firstFrame: CGImage?
      while true {
        do {
          firstFrame = try await runAttempt(attempt, token: token, reel: reel, dest: dest, partial: partial,
                                            onProgress: onProgress)
          break
        } catch ExportError.encoderFailed where !attempt.software {
          await removePartial()
          if slot.isCancelled(token, ifGone: true) { throw CancellationError() }
          MediaLog.note("export: encoder failed; retrying \(dest.lastPathComponent) with the software encoder")
          attempt = Attempt(number: attempt.number + 1, software: true)
          partial = Self.partialURL(for: dest, ext: "mp4")
        }
      }
      await Self.clearWriterTemporaries(of: partial)
      if firstFrame == nil { MediaLog.note("export: no thumbnail for \(dest.lastPathComponent); saving without one") }

      // The final 1.0 event keeps to the ≤ 10/s throttle.
      let wait = meter.withLock { $0.wait(now: Self.now()) }
      if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
      guard slot.claimRename(token) else { throw CancellationError() }
      try FileManager.default.moveItem(at: partial, to: dest)
      let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
      MediaLog.note("export: done \(dest.lastPathComponent), \(bytes) bytes, software \(attempt.software)")
      if let final = meter.withLock({ $0.final(now: Self.now()) }) {
        continuation.yield(.progress(final.progress, eta: final.eta))
      }
      release()
      continuation.yield(.done(ExportResult(url: dest, bytes: bytes, firstFrame: firstFrame,
                                            usedSoftwareEncoder: attempt.software)))
      continuation.finish()
    } catch {
      // `partial` is this export's own name; after a failed rename it still holds our file.
      await removePartial()
      let cancelled = slot.isCancelled(token, ifGone: false) || error is CancellationError
      // The system error under the failure: the job's, when its reader or writer reported one.
      let underlying = slot.handle(token)?.cause ?? ExportCause(error)
      release()
      if cancelled {
        MediaLog.note("export: cancelled \(dest.lastPathComponent)")
        continuation.finish(throwing: CancellationError())
      } else {
        let mapped = ExportError(error)
        cause.withLock { $0 = underlying }
        MediaLog.note("export: failed \(dest.lastPathComponent): \(error) → \(mapped.sentence)"
          + (underlying.map { " [\($0.domain) \($0.code)]" } ?? ""))
        continuation.finish(throwing: mapped)
      }
    }
  }

  /// One reader → writer pass into `partial`; returns grid frame 0 (nil when it couldn't be made).
  private func runAttempt(_ attempt: Attempt, token: UUID, reel: Reel, dest: URL, partial: URL,
                          onProgress: @escaping @Sendable (Double) -> Void) async throws -> CGImage? {
    if attempt.number > 1 { MediaLog.note("export: attempt \(attempt.number), software \(attempt.software)") }
    let setup = try await prepare(reel: reel, dest: dest, partial: partial, software: attempt.software)
    let job = ExportJob(setup: setup, audioStage: audioStage, injected: testHook?(attempt),
                        makesThumbnail: makesThumbnail, stallLimit: stallLimit, frameHook: frameHook,
                        onProgress: onProgress)
    onJob?(job)
    if slot.attach(job, to: token) { job.abort() }
    return try await job.run()
  }

  /// §5.5 step 1–2: freeze, plan, build, and set up the reader and writer.
  private func prepare(reel: Reel, dest: URL, partial: URL, software: Bool) async throws -> ExportJob.Setup {
    var assets: [UUID: AVURLAsset] = [:]
    var sources: [ExportJob.Source] = []
    for clip in reel.clips {
      let name = URL(filePath: clip.source.absolutePath).lastPathComponent
      guard let url = resolve(clip), FileManager.default.isReadableFile(atPath: url.path) else {
        throw ExportError.sourceUnreadable(name)
      }
      let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      do {
        guard try await asset.load(.isReadable) else { throw ExportError.sourceUnreadable(name) }
      } catch {
        throw ExportError.sourceUnreadable(name)
      }
      assets[clip.id] = asset
      if !sources.contains(where: { $0.url == url }) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        sources.append(ExportJob.Source(name: name, url: url, size: size))
      }
    }
    let plan = Planner.plan(reel)
    guard plan.total > .zero, let first = reel.clips.first else { throw ExportError.other("The Reel is empty.") }
    let built: BuiltComposition
    do {
      built = try await CompositionBuilder.build(plan, assets: assets)
    } catch let error as BuildError {
      switch error {
      case .missingAsset(let id), .noVideoTrack(let id):
        let clip = reel.clips.first { $0.id == id }
        throw ExportError.sourceUnreadable(clip.map { URL(filePath: $0.source.absolutePath).lastPathComponent })
      case .trackUnavailable:
        throw ExportError.other("The Reel couldn't be assembled.")
      }
    }

    if FileManager.default.fileExists(atPath: dest.path) {
      throw ExportError.other("\(dest.lastPathComponent) already exists.")
    }

    let audioTracks = built.composition.tracks(withMediaType: .audio)
    let withAudio = plan.hasAudioOut && !audioTracks.isEmpty
    var video = ExportPresets.video(spec: reel.export, plan: plan, firstClip: first.facts, software: software)
    MediaLog.note("export: spec \(reel.export.format.rawValue)/\(reel.export.quality.rawValue) convertHDR "
      + "\(reel.export.convertHDR) removeAudio \(reel.export.removeAudio) → \(dest.lastPathComponent)")
    MediaLog.note("export: plan \(plan.placements.count) clips, total \(plan.total.seconds) s, fd "
      + "\(plan.frameDuration.value)/\(plan.frameDuration.timescale), \(plan.renderSize.width)×"
      + "\(plan.renderSize.height), hdrOut \(plan.hdrOut), audio \(withAudio)")

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
    } catch {
      throw ExportError.other("The export file couldn't be created in \(dest.deletingLastPathComponent().path).")
    }
    writer.shouldOptimizeForNetworkUse = true
    if !writer.canApply(outputSettings: video as [String: Any], forMediaType: .video) {
      video = ExportPresets.withoutDataRateLimits(video)
      MediaLog.note("export: writer refused DataRateLimits; exporting without it")
      guard writer.canApply(outputSettings: video as [String: Any], forMediaType: .video) else {
        throw ExportError.encoderFailed
      }
    }
    MediaLog.note("export: video settings \(video)")
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video as [String: Any])
    videoInput.expectsMediaDataInRealTime = false
    // The track's timescale is the grid's, so every PTS is exact (the default 600 can't hold 1001/30000).
    videoInput.mediaTimeScale = plan.frameDuration.timescale
    writer.add(videoInput)
    var audioInput: AVAssetWriterInput?
    if withAudio {
      let settings = ExportPresets.audio()
      MediaLog.note("export: audio settings \(settings)")
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings as [String: Any])
      input.expectsMediaDataInRealTime = false
      writer.add(input)
      audioInput = input
    }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: built.composition)
    } catch {
      throw ExportError.sourceUnreadable(nil)
    }
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(plan.total))
    // nil settings: the compositor's own buffers (BGRA BT.709 or 10-bit HLG), so nothing converts them twice.
    let videoOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: nil)
    videoOutput.videoComposition = built.videoComposition
    videoOutput.alwaysCopiesSampleData = false
    reader.add(videoOutput)
    var audioOutput: AVAssetReaderAudioMixOutput?
    if withAudio {
      let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: MediaAudio.readerSettings)
      output.audioMix = built.audioMix
      output.alwaysCopiesSampleData = false
      reader.add(output)
      audioOutput = output
    }
    return ExportJob.Setup(reader: reader, videoOutput: videoOutput, audioOutput: audioOutput, writer: writer,
                           videoInput: videoInput, audioInput: audioInput, total: plan.total,
                           frameDuration: plan.frameDuration, hdrOut: plan.hdrOut, sources: sources)
  }

  /// `<stem>.<8 hex>.partial.<ext>` beside `dest`, at a name nothing is using yet. `ext` defaults to dest's.
  static func partialURL(for dest: URL, ext: String? = nil) -> URL {
    let folder = dest.deletingLastPathComponent()
    let stem = dest.deletingPathExtension().lastPathComponent
    while true {
      let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
      let url = folder.appending(path: "\(stem).\(tag).partial.\(ext ?? dest.pathExtension)")
      if !FileManager.default.fileExists(atPath: url.path) { return url }
    }
  }

  /// `shouldOptimizeForNetworkUse` rewrites the file through a `<partial>.sb-…` temporary that AVFoundation
  /// removes shortly after `finishWriting` reports completion. Give it up to 1 s (`waiting`), then remove what is
  /// left. After a cancelled or failed write nothing will remove it, so it goes at once.
  static func clearWriterTemporaries(of partial: URL, waiting: Bool = true) async {
    let folder = partial.deletingLastPathComponent()
    let prefix = partial.lastPathComponent + ".sb-"
    func leftovers() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
    }
    var tries = 0
    while waiting, tries < 50, !leftovers().isEmpty {
      try? await Task.sleep(for: .milliseconds(20))
      tries += 1
    }
    for name in leftovers() {
      MediaLog.note("export: removing writer temporary \(name)")
      try? FileManager.default.removeItem(at: folder.appending(path: name))
    }
  }

  private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

// MARK: - progress

/// §5.5 step 5: at most one event per `interval`; ETA from the moving average of the last 3 rate samples.
struct ProgressMeter {
  static let interval = 0.1
  static let window = 3

  private var last: (progress: Double, time: Double)?
  private var rates: [Double] = []

  /// The event to emit for `progress` at `now`, or nil when throttled or not an increase.
  mutating func offer(_ progress: Double, now: Double) -> (progress: Double, eta: Double?)? {
    let p = min(max(progress, 0), 1)
    if let last {
      guard now - last.time >= Self.interval, p > last.progress else { return nil }
      rates.append((p - last.progress) / (now - last.time))
      if rates.count > Self.window { rates.removeFirst() }
    }
    last = (p, now)
    guard !rates.isEmpty else { return (p, nil) }
    let rate = rates.reduce(0, +) / Double(rates.count)
    return (p, rate > 0 ? (1 - p) / rate : nil)
  }

  /// Seconds to wait before the next event may go out.
  func wait(now: Double) -> Double {
    guard let last else { return 0 }
    return max(0, Self.interval - (now - last.time))
  }

  /// The closing 1.0 event (nil if 1.0 was already sent).
  mutating func final(now: Double) -> (progress: Double, eta: Double?)? {
    if let last, last.progress >= 1 { return nil }
    last = (1, now)
    return (1, 0)
  }
}

// MARK: - job

/// One export's reader → writer pump.
///
/// Each writer input has its own serial queue, as Apple's reader/writer guidance has it: `copyNextSampleBuffer`
/// blocks until the reader has a buffer, and the writer interleaves by time (it stops taking video until enough
/// sound has arrived, or the reverse). With one queue for both, a video read that blocked would also stop the
/// sound the writer was waiting for, and the export would never end (hang-report.md).
///
/// Ownership: the video pump's state (`next`, `current`, `pending`, `readerExhausted`) is touched only on
/// `videoQueue`; the audio pump's (`audioEnd`, `audioFormat`, `audioExhausted`) only on `audioQueue`. What both
/// sides and teardown share (the continuation, the done flags, `finishing`, `firstFrame`) is behind `shared`.
/// Start, teardown (cancel reading / writing) and the stall watchdog run on `control`, so they work even while a
/// pump is blocked inside the reader.
final class ExportJob: @unchecked Sendable {
  struct Setup: @unchecked Sendable {
    let reader: AVAssetReader
    let videoOutput: AVAssetReaderVideoCompositionOutput
    let audioOutput: AVAssetReaderAudioMixOutput?
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let total, frameDuration: RationalTime
    let hdrOut: Bool
    /// Each distinct source file, as it was when the export started.
    var sources: [Source] = []
  }

  /// A source file, its clip's file name (for `ExportError.sourceUnreadable`) and its size at the start.
  struct Source: Sendable {
    let name: String
    let url: URL
    let size: Int64

    /// Still there, readable and not shorter than it was (a drive that went away, a file truncated or replaced).
    var isIntact: Bool {
      guard FileManager.default.isReadableFile(atPath: url.path),
        let now = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
      else { return false }
      return now >= size
    }
  }

  /// Longest the stall's source check may take; past it the stall is reported as `.stalled`.
  static let sourceCheckLimit = DispatchTimeInterval.seconds(2)

  private enum Side { case reader, writer }

  /// On the compositor's device (`HDRToSDR.device`), so the LUT kernel runs here too.
  private static let imageContext: CIContext = {
    let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "com.dcv.trimlab2.thumbnail"]
    if let device = HDRToSDR.device { return CIContext(mtlDevice: device, options: options) }
    return CIContext(options: options)
  }()

  private let s: Setup
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let audioStage: any AudioStage
  private let onProgress: @Sendable (Double) -> Void
  /// Test seam: fail as the writer would, after frame 0.
  private let injected: ExportError?
  /// Test seam: false leaves `firstFrame` nil.
  private let makesThumbnail: Bool
  /// Test seam: called before each grid frame on `videoQueue`.
  private let frameHook: (@Sendable (Int64) -> Void)?
  private let videoQueue = DispatchQueue(label: "com.dcv.trimlab2.export.video", qos: .userInitiated)
  private let audioQueue = DispatchQueue(label: "com.dcv.trimlab2.export.audio", qos: .userInitiated)
  private let control = DispatchQueue(label: "com.dcv.trimlab2.export.control", qos: .userInitiated)
  private let stopped = Atomic<Bool>(false)
  /// The system error the reader or writer reported, as the job mapped it to an `ExportError` (`fail`).
  private let reported = Mutex<ExportCause?>(nil)
  var cause: ExportCause? { reported.withLock { $0 } }

  /// Grid frames to write: `round(total / fd)` (§5.5 step 3).
  private let frameCount: Int64
  /// A decoded buffer this close after a grid time still counts as at it (timestamp rounding only).
  private let tolerance: CMTime
  /// The total at the audio rate: the audio track is padded with silence to this many frames (§5.5 step 3's
  /// length, so a Reel ending in silent clips has sound as long as its picture).
  private let audioFrameCount: Int64

  // MARK: watchdog

  /// No append (or, once writing is finishing, no growth of the file) for this long fails the export with
  /// `.stalled`.
  private let stallLimit: Duration
  /// `finishWriting` rewrites the whole file for network use (`shouldOptimizeForNetworkUse`), so it gets longer
  /// between signs of life; any growth of the partial or its `.sb-` temporary counts as one (`checkStall`).
  private var finishLimit: Duration { max(stallLimit * 6, .seconds(120)) }
  /// The file mark the watchdog last compared; `control`-confined.
  private var fileMark: FileMark?
  /// File stats run here, never on `control`: on a hung network share or a sleeping drive a stat can block for
  /// a long time, and the watchdog and teardown must not wait behind it. At most one stat is in flight; the
  /// watchdog compares the last finished one, so a stuck stat never counts as progress.
  private let statQueue = DispatchQueue(label: "com.dcv.trimlab2.export.stat", qos: .utility)
  private let statInFlight = Atomic<Bool>(false)
  private let lastStat = Mutex<FileMark?>(nil)
  /// Test seam: runs at the start of every stat on `statQueue` (may block, as a dead drive would).
  let statHook = Mutex<(@Sendable () -> Void)?>(nil)
  /// The stall's source check has started; `control`-confined.
  private var stallReported = false
  /// Which outputs have a `copyNextSampleBuffer` in flight, and whether new reads are refused. `cancelReading`
  /// tears the reader's audio mixer down under a read that is still waiting in it (SIGSEGV in CoreMedia's
  /// `WaitOnCondition`, hang-report.md), so teardown closes the gate and cancels only once no read is in flight.
  private struct ReadGate {
    var video = false
    var audio = false
    var closed = false
    /// The output has returned nil (its end, or the reader stopped): draining it again would return at once.
    var videoEnded = false
    var audioEnded = false
  }
  /// Test seam: runs inside every gated read, before `copyNextSampleBuffer` (may block, as a wedged read would).
  let readHook = Mutex<(@Sendable (_ video: Bool) -> Void)?>(nil)
  /// Teardown loop iterations (drains and back-off checks), for tests.
  let teardownSteps = Atomic<Int>(0)
  /// Longest teardown keeps checking for a wedged read before it gives up and leaves the job leaked.
  static let teardownGiveUp = Duration.seconds(300)
  private let readGate = Mutex(ReadGate())
  /// Runs the reader teardown (drain, then `cancelReading`), off `control` so a slow drain never blocks it.
  private let teardownQueue = DispatchQueue(label: "com.dcv.trimlab2.export.teardown", qos: .utility)
  /// `releaseWhenQuiet` has started; `control`-confined.
  private var releasing = false
  /// `ReelCompositor.activity` at the last tick; `control`-confined.
  private var composed = -1
  /// How long teardown's `cancelWriting` and `cancelReading` took (nil until teardown ran), for tests and the log.
  let teardownTimes = Mutex<(writing: Duration, reading: Duration)?>(nil)
  /// Longest teardown waits for `cancelReading`/`cancelWriting` before the run is resumed anyway.
  static let teardownBackstop = DispatchTimeInterval.milliseconds(1500)
  /// Uptime (ns) of the last append, or of the start of the current phase.
  private let lastAdvance = Atomic<UInt64>(0)
  /// Where each pump is, for the stall log line (`Phase.rawValue`).
  enum Phase: UInt8 { case idle, hook, reading, appending, thumbnail, finished }
  private let videoPhase = Atomic<UInt8>(0)
  private let audioPhase = Atomic<UInt8>(0)
  private let videoReads = Atomic<Int>(0)
  private let audioAppends = Atomic<Int>(0)
  private func mark(_ which: borrowing Atomic<UInt8>, _ phase: Phase) { which.store(phase.rawValue, ordering: .relaxed) }
  private static func name(_ raw: UInt8) -> String { Phase(rawValue: raw).map { "\($0)" } ?? "?" }
  /// Pump calls in progress. The job keeps itself alive (`keepAlive`) until this is back to 0 after the run
  /// ended: AVFoundation may drop its media-data block (and so the last reference to the job) while a pump is
  /// still inside `copyNextSampleBuffer`, and freeing the reader under a blocked read crashes in CoreMedia.
  private let inside = Atomic<Int>(0)
  /// `self` from `begin` until the pumps are quiet after the run ends; `control`-confined.
  private var keepAlive: ExportJob?
  /// Longest gap between appends seen so far, and whether it was logged; `control`-confined.
  private var lastIdle: Duration = .zero
  /// Watchdog ticks; set up and torn down on `control`.
  private var watchdog: DispatchSourceTimer?

  // shared, behind `shared`
  private struct Shared {
    var continuation: CheckedContinuation<CGImage?, Error>?
    var videoDone = false
    var audioDone = false
    var finishing = false
    var firstFrame: CGImage?
    /// Video grid frames written so far (for the stall log line).
    var written: Int64 = 0
  }
  private let shared = Mutex(Shared())

  // videoQueue-confined
  private var next: Int64 = 0
  private var current: CVPixelBuffer?
  private var pending: (buffer: CVPixelBuffer, pts: CMTime)?
  private var readerExhausted = false
  private var videoMarked = false

  // audioQueue-confined
  private var audioExhausted = false
  private var audioMarked = false
  /// End of the audio appended so far, in frames at `audioRate`.
  private var audioEnd: Int64 = 0
  private var audioFormat: CMAudioFormatDescription?

  init(setup: Setup, audioStage: any AudioStage, injected: ExportError? = nil, makesThumbnail: Bool = true,
       stallLimit: Duration = ExportRunner.defaultStallLimit, frameHook: (@Sendable (Int64) -> Void)? = nil,
       onProgress: @escaping @Sendable (Double) -> Void) {
    s = setup
    self.audioStage = audioStage
    self.injected = injected
    self.makesThumbnail = makesThumbnail
    self.stallLimit = stallLimit
    self.frameHook = frameHook
    self.onProgress = onProgress
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: setup.videoInput, sourcePixelBufferAttributes: nil)
    let fd = setup.frameDuration
    frameCount = Int64((Double(setup.total.value) * Double(fd.timescale)
      / (Double(setup.total.timescale) * Double(fd.value))).rounded())
    tolerance = CMTime(value: fd.value, timescale: fd.timescale * 4)
    audioFrameCount = CMTimeConvertScale(CMTime(setup.total), timescale: Self.audioRate,
                                         method: .roundHalfAwayFromZero).value
    shared.withLock { $0.audioDone = setup.audioInput == nil }
  }

  /// Runs to the end of writing; returns grid frame 0, or nil when it couldn't be made (never fatal).
  func run() async throws -> CGImage? {
    try await withCheckedThrowingContinuation { c in
      control.async { self.begin(c) }
    }
  }

  /// Safe from any thread, including while a pump is blocked in the reader. The run ends with
  /// `CancellationError` (once `finishWriting` is in flight, its completion reports it).
  func abort() {
    stopped.store(true, ordering: .sequentiallyConsistent)
    fail(CancellationError(), from: nil)
  }

  // MARK: control

  private func begin(_ c: CheckedContinuation<CGImage?, Error>) {
    shared.withLock { $0.continuation = c }
    keepAlive = self
    if stopped.load(ordering: .sequentiallyConsistent) { return fail(CancellationError(), from: nil) }
    guard s.reader.startReading() else { return fail(s.reader.error, from: .reader) }
    guard s.writer.startWriting() else { return fail(s.writer.error, from: .writer) }
    s.writer.startSession(atSourceTime: .zero)
    advanced()
    startWatchdog()
    s.videoInput.requestMediaDataWhenReady(on: videoQueue) { self.pumping { self.pumpVideo() } }
    s.audioInput?.requestMediaDataWhenReady(on: audioQueue) { self.pumping { self.pumpAudio() } }
  }

  private func pumping<T>(_ body: () -> T) -> T {
    inside.add(1, ordering: .sequentiallyConsistent)
    defer { inside.subtract(1, ordering: .sequentiallyConsistent) }
    return body()
  }

  /// On `control`, once the run has ended: drops `keepAlive` when no pump call has been in progress for two
  /// checks 50 ms apart. While a pump is busy the checks back off, doubling from 50 ms up to 5 s, so a pump wedged
  /// for good leaks the job (rather than crash) at almost no cost. Later calls while one is under way do nothing.
  private func releaseWhenQuiet() {
    guard keepAlive != nil, !releasing else { return }
    releasing = true
    checkQuiet(quietChecks: 0, delay: .milliseconds(50))
  }

  private func checkQuiet(quietChecks: Int, delay: Duration) {
    let quiet = inside.load(ordering: .sequentiallyConsistent) == 0
    if quiet, quietChecks >= 1 {
      keepAlive = nil
      return
    }
    // Quiet once: confirm 50 ms later. Busy: wait longer each time.
    let wait = quiet ? Duration.milliseconds(50) : delay
    let interval = DispatchTimeInterval.nanoseconds(Int(wait / .nanoseconds(1)))
    control.asyncAfter(deadline: .now() + interval) { [self] in
      checkQuiet(quietChecks: quiet ? quietChecks + 1 : 0, delay: quiet ? delay : min(delay * 2, .seconds(5)))
    }
  }

  private static func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  private func advanced() { lastAdvance.store(Self.uptime(), ordering: .relaxed) }

  private func startWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: control)
    let tick = min(max(stallLimit / 4, .milliseconds(50)), .seconds(1))
    let interval = DispatchTimeInterval.nanoseconds(Int(tick / .nanoseconds(1)))
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
    timer.setEventHandler { [weak self] in self?.checkStall() }
    watchdog = timer
    timer.resume()
  }

  /// On `control`.
  private func stopWatchdog() {
    watchdog?.cancel()
    watchdog = nil
  }

  /// On `control`: fails the export when nothing has advanced for the phase's limit.
  private func checkStall() {
    let (live, finishing, written) = shared.withLock { ($0.continuation != nil, $0.finishing, $0.written) }
    guard live else { return stopWatchdog() }
    // Appends aren't the only progress. On a busy Mac the encoder can hold both inputs not-ready for seconds
    // while it catches up (the file grows), and the reader can wait seconds for frames to compose (a busy GPU).
    // Any of these moving counts; only a pipeline where nothing moves is stalled. While finishing, the file is
    // the only sign of life: any change to it is progress (size, allocated size, or modification time; a
    // temporary allocated at full size up front, or an SMB share reporting sizes late, only shows the latter).
    if let mark = lastStat.withLock({ $0 }), mark != fileMark {
      fileMark = mark
      advanced()
    }
    requestStat()
    let activity = compositorActivity()
    if activity != composed {
      composed = activity
      advanced()
    }
    let limit = finishing ? finishLimit : stallLimit
    let idle = Duration.nanoseconds(Int64(Self.uptime() &- lastAdvance.load(ordering: .relaxed)))
    // A long gap that ended is logged once, so slow-but-alive exports show in the log.
    if lastIdle > .seconds(3), idle < lastIdle {
      MediaLog.note("export: slow — a \(lastIdle) gap between appends ended (\(pipelineState(written)))")
    }
    lastIdle = idle
    // Reads have stopped for half the limit: look at the sources now, so a gone one is known by the verdict.
    if idle > limit / 2, Self.uptime() &- lastSourceCheck > 1_000_000_000 { startSourceCheck() }
    guard idle > limit, !stallReported else { return }
    stallReported = true
    let seconds = Int((limit / .seconds(1)).rounded(.up))
    MediaLog.note("export: stalled — nothing written for \(idle) (\(finishing ? "finishing the file; " : "")"
      + "\(pipelineState(written))); stopping")
    fail(ExportError.stalled(seconds: seconds), from: nil, evenWhileFinishing: true)
  }

  // MARK: source check

  /// The clip name of a source found gone (missing, unreadable or shorter than at the start); `control`-confined.
  private var goneSource: String?
  /// A check is running; who waits for it; when the last one started. All `control`-confined.
  private var sourceCheckRunning = false
  private var sourceWaiters: [(UUID, @Sendable (String?) -> Void)] = []
  private var lastSourceCheck: UInt64 = 0

  /// On `control`: checks the sources off `control` (at user-initiated priority, so a loaded Mac doesn't starve
  /// it), unless a check is running. A check stuck on a dead drive just never answers.
  private func startSourceCheck() {
    guard !sourceCheckRunning, goneSource == nil, !s.sources.isEmpty else { return }
    sourceCheckRunning = true
    lastSourceCheck = Self.uptime()
    let sources = s.sources
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let gone = sources.first { !$0.isIntact }
      control.async { [self] in
        sourceCheckRunning = false
        if let gone {
          goneSource = gone.name
          MediaLog.note("export: source check — \(gone.url.path) is missing, unreadable or shorter than at the start")
        }
        let waiters = sourceWaiters
        sourceWaiters = []
        for (_, w) in waiters { w(goneSource) }
      }
    }
  }

  /// On `control`: a failure that may really be a source going away (`.stalled`, or a reader failure that names
  /// no clip) becomes `.sourceUnreadable(<clip>)` when a source is gone. Bounded by `sourceCheckLimit`: a check
  /// that doesn't answer in time (a dead drive) leaves the error as it was.
  private func classify(_ error: any Error, then: @escaping @Sendable (any Error) -> Void) {
    let open: Bool
    switch error as? ExportError {
    case .stalled?, .sourceUnreadable(nil)?: open = !s.sources.isEmpty
    default: open = false
    }
    guard open else { return then(error) }
    if let goneSource { return then(ExportError.sourceUnreadable(goneSource)) }
    let id = UUID()
    let original = error
    sourceWaiters.append((id, { name in then(name.map { ExportError.sourceUnreadable($0) } ?? original) }))
    startSourceCheck()
    control.asyncAfter(deadline: .now() + Self.sourceCheckLimit) { [self] in
      guard let i = sourceWaiters.firstIndex(where: { $0.0 == id }) else { return }
      sourceWaiters.remove(at: i)
      MediaLog.note("export: source check didn't answer in \(Self.sourceCheckLimit); keeping \(original)")
      then(original)
    }
  }

  /// One `copyNextSampleBuffer` through the gate; nil when the gate is closed (the run has ended) as well as at
  /// the end of the output.
  private func readSample(video: Bool) -> CMSampleBuffer? {
    let open = readGate.withLock { g -> Bool in
      guard !g.closed else { return false }
      if video { g.video = true } else { g.audio = true }
      return true
    }
    guard open else { return nil }
    readHook.withLock { $0 }?(video)
    let sample = video ? s.videoOutput.copyNextSampleBuffer() : s.audioOutput?.copyNextSampleBuffer()
    readGate.withLock { g in
      if video { g.video = false } else { g.audio = false }
      if sample == nil { if video { g.videoEnded = true } else { g.audioEnded = true } }
    }
    return sample
  }

  /// On `teardownQueue`, after the run has resumed: closes the gate, waits until no read is in flight, then
  /// cancels the reader. A read can be waiting on the other output (the reader keeps them roughly in step), so
  /// while one output has a read in flight the other is drained here, a sample at a time, which lets it return;
  /// an output that has ended is never drained again. Otherwise the check re-arms on `teardownQueue`, backing off
  /// from 5 ms to 5 s, so a wedged read costs no thread and no CPU. Both stuck means the reader itself is wedged:
  /// it is never cancelled under them, and after `teardownGiveUp` the checks stop and the job (kept alive by
  /// `keepAlive`) stays leaked instead of crashing. Calls `done` with the time spent waiting and in `cancelReading`.
  private func tearDownReader(done: @escaping @Sendable (_ waited: Duration, _ cancel: Duration) -> Void) {
    readGate.withLock { $0.closed = true }
    teardownStep(started: Self.uptime(), delay: .milliseconds(5), logged: false, done: done)
  }

  private func teardownStep(started t0: UInt64, delay: Duration, logged: Bool,
                            done: @escaping @Sendable (Duration, Duration) -> Void) {
    while true {
      teardownSteps.add(1, ordering: .relaxed)
      // Pick an output to drain (claimed under the lock, so no pump can read it meanwhile), or none.
      let (busy, drainVideo, drainAudio) = readGate.withLock { g -> (Bool, Bool, Bool) in
        guard g.video || g.audio else { return (false, false, false) }
        if g.audio, !g.video, !g.videoEnded {
          g.video = true
          return (true, true, false)
        }
        if g.video, !g.audio, !g.audioEnded, s.audioOutput != nil {
          g.audio = true
          return (true, false, true)
        }
        return (true, false, false)
      }
      guard busy, s.reader.status == .reading else { break }  // quiet, or ended by itself: nothing under a read
      guard drainVideo || drainAudio else {
        let waited = Duration.nanoseconds(Int64(Self.uptime() - t0))
        if waited > Self.teardownGiveUp {
          MediaLog.note("export: teardown — a read is still in flight after \(waited); leaving the reader uncancelled "
            + "and the job leaked")
          return
        }
        let noteNow = !logged && waited > .seconds(2)
        if noteNow {
          MediaLog.note("export: teardown — a read is still in flight after 2 s; cancelling the reader once it returns")
        }
        let interval = DispatchTimeInterval.nanoseconds(Int(delay / .nanoseconds(1)))
        teardownQueue.asyncAfter(deadline: .now() + interval) { [self] in
          teardownStep(started: t0, delay: min(delay * 2, .seconds(5)), logged: logged || noteNow, done: done)
        }
        return
      }
      let sample = pumping { drainVideo ? s.videoOutput.copyNextSampleBuffer() : s.audioOutput?.copyNextSampleBuffer() }
      readGate.withLock { g in
        if drainVideo { g.video = false } else { g.audio = false }
        if sample == nil { if drainVideo { g.videoEnded = true } else { g.audioEnded = true } }
      }
    }
    let t1 = Self.uptime()
    if s.reader.status == .reading { s.reader.cancelReading() }
    let t2 = Self.uptime()
    done(.nanoseconds(Int64(t1 - t0)), .nanoseconds(Int64(t2 - t1)))
  }

  /// Starts a stat of the written files on `statQueue` unless one is still in flight.
  private func requestStat() {
    guard !statInFlight.exchange(true, ordering: .sequentiallyConsistent) else { return }
    statQueue.async { [self] in
      statHook.withLock { $0 }?()
      let mark = writtenMark()
      lastStat.withLock { $0 = mark }
      statInFlight.store(false, ordering: .sequentiallyConsistent)
    }
  }

  /// The export's `ReelCompositor.activity` (0 before the reader has made its compositor).
  private func compositorActivity() -> Int {
    (s.videoOutput.customVideoCompositor as? ReelCompositor)?.activity.load(ordering: .relaxed) ?? 0
  }

  /// Where the pipeline is, for the slow / stalled log lines.
  private func pipelineState(_ written: Int64) -> String {
    "frame \(written) of \(frameCount), reader \(s.reader.status.rawValue), writer \(s.writer.status.rawValue); video "
      + "\(Self.name(videoPhase.load(ordering: .relaxed))) ready \(s.videoInput.isReadyForMoreMediaData) reads "
      + "\(videoReads.load(ordering: .relaxed)); audio \(Self.name(audioPhase.load(ordering: .relaxed))) ready "
      + "\(s.audioInput?.isReadyForMoreMediaData ?? false) appends \(audioAppends.load(ordering: .relaxed)); compositor "
      + "activity \(compositorActivity()); file \(fileMark?.bytes ?? 0) bytes"
  }

  /// The writer's output file and its `.sb-` temporaries, for teardown that ends after the runner has tidied up.
  private func writtenFiles() -> [URL] {
    let url = s.writer.outputURL
    let folder = url.deletingLastPathComponent()
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0 == url.lastPathComponent || $0.hasPrefix(url.lastPathComponent + ".sb-") }
      .map { folder.appending(path: $0) }
  }

  /// On `statQueue`, so a dead drive never blocks `control`.
  private func removeWrittenFiles() {
    statQueue.async { [self] in removeWrittenFilesNow() }
  }

  private func removeWrittenFilesNow() {
    for url in writtenFiles() {
      if url.lastPathComponent.contains(".sb-") {
        MediaLog.note("export: removing leftover writer temporary \(url.lastPathComponent) after teardown")
      }
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// What the finish-phase watchdog compares between ticks.
  struct FileMark: Equatable {
    var bytes: Int64 = 0
    var allocated: Int64 = 0
    var modified: Date?
  }

  /// Sizes, allocated sizes and the newest modification time of the writer's output file plus its
  /// `<partial>.sb-…` temporaries.
  private func writtenMark() -> FileMark {
    var mark = FileMark()
    let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
    for url in writtenFiles() {
      guard let v = try? url.resourceValues(forKeys: keys) else { continue }
      mark.bytes += Int64(v.fileSize ?? 0)
      mark.allocated += Int64(v.totalFileAllocatedSize ?? 0)
      if let m = v.contentModificationDate, mark.modified.map({ m > $0 }) ?? true { mark.modified = m }
    }
    return mark
  }

  /// The file this job's writer writes (tests).
  var outputURL: URL { s.writer.outputURL }

  private var live: Bool { !stopped.load(ordering: .sequentiallyConsistent) }

  private func gridTime(_ n: Int64) -> CMTime {
    CMTime(value: n * s.frameDuration.value, timescale: s.frameDuration.timescale)
  }

  // MARK: videoQueue

  /// Grid frame n gets the latest decoded buffer whose PTS ≤ n × fd, retimed to n × fd. With no new buffer
  /// since the last grid time (a source gap, or the reader ended early) the previous buffer goes again.
  private func pumpVideo() {
    while live, !videoMarked, s.videoInput.isReadyForMoreMediaData {
      guard next < frameCount else {
        s.videoInput.markAsFinished()
        videoMarked = true
        mark(videoPhase, .finished)
        // Unread frames past the grid would hold the reader up; drop them (blocks only this queue).
        while live, !readerExhausted, readSample(video: true) != nil { advanced() }
        readerExhausted = true
        shared.withLock { $0.videoDone = true }
        return finishIfDone()
      }
      mark(videoPhase, .hook)
      frameHook?(next)
      let t = gridTime(next)
      while live {
        if pending == nil, !readerExhausted {
          mark(videoPhase, .reading)
          let read = readSample(video: true)
          videoReads.add(1, ordering: .relaxed)
          if let sample = read {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            pending = (buffer, CMSampleBufferGetPresentationTimeStamp(sample))
          } else {
            if !live { return }
            if s.reader.status == .failed { return fail(s.reader.error, from: .reader) }
            readerExhausted = true
          }
        }
        guard let p = pending, current == nil || p.pts <= t + tolerance else { break }
        current = p.buffer
        pending = nil
      }
      guard live else { return }
      guard let buffer = current else { return fail(ExportError.other("The Reel produced no video."), from: nil) }
      // A cancel racing this append is benign: the cancelled writer makes it return false, and `fail` then finds
      // the continuation already taken and does nothing.
      mark(videoPhase, .appending)
      guard adaptor.append(buffer, withPresentationTime: t) else { return fail(s.writer.error, from: .writer) }
      advanced()
      mark(videoPhase, .idle)
      if next == 0, makesThumbnail {
        mark(videoPhase, .thumbnail)
        defer { mark(videoPhase, .idle) }
        let image = Self.image(of: buffer, hdr: s.hdrOut)
        shared.withLock { $0.firstFrame = image }
      }
      next += 1
      shared.withLock { $0.written = next }
      onProgress(t.seconds / s.total.seconds)
      if let injected { return fail(injected, from: .writer) }
    }
  }

  // MARK: audioQueue

  /// The mix, then silence up to `audioFrameCount` when the mix ends early (the last clips have no audio).
  private func pumpAudio() {
    while live, !audioMarked, let input = s.audioInput, input.isReadyForMoreMediaData {
      mark(audioPhase, .reading)
      if !audioExhausted, let sample = readSample(video: false) {
        mark(audioPhase, .appending)
        guard live else { return }
        let start = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: Self.audioRate,
                                       method: .roundHalfAwayFromZero).value
        audioEnd = max(audioEnd, start + Int64(CMSampleBufferGetNumSamples(sample)))
        if audioFormat == nil { audioFormat = CMSampleBufferGetFormatDescription(sample) }
        // Racing a cancel is benign (see `pumpVideo`): append returns false and `fail` is a no-op.
        guard input.append(audioStage.process(sample)) else { return fail(s.writer.error, from: .writer) }
        advanced()
        audioAppends.add(1, ordering: .relaxed)
        mark(audioPhase, .idle)
        continue
      }
      mark(audioPhase, .idle)
      guard live else { return }
      if s.reader.status == .failed { return fail(s.reader.error, from: .reader) }
      if !audioExhausted, audioEnd < audioFrameCount {
        MediaLog.note("export: audio ends at \(Double(audioEnd) / Double(Self.audioRate)) s; padding silence to "
          + "\(Double(audioFrameCount) / Double(Self.audioRate)) s")
      }
      audioExhausted = true
      guard audioEnd < audioFrameCount else {
        input.markAsFinished()
        audioMarked = true
        mark(audioPhase, .finished)
        shared.withLock { $0.audioDone = true }
        return finishIfDone()
      }
      let count = min(audioFrameCount - audioEnd, Self.silenceChunk)
      guard let silence = Self.silence(frames: count, at: audioEnd, format: audioFormat) else {
        return fail(ExportError.other("The closing silence couldn't be made."), from: nil)
      }
      // Racing a cancel is benign, as above.
      guard input.append(audioStage.process(silence)) else { return fail(s.writer.error, from: .writer) }
      advanced()
      audioAppends.add(1, ordering: .relaxed)
      audioEnd += count
    }
  }

  /// `MediaAudio.readerSettings`' rate.
  static let audioRate: Int32 = 48_000
  /// 0.1 s of silence per buffer.
  private static let silenceChunk: Int64 = 4_800

  /// `frames` of digital silence at frame `start`, in the mix's own format (or `readerSettings`' when the mix
  /// produced nothing).
  static func silence(frames: Int64, at start: Int64, format: CMAudioFormatDescription?) -> CMSampleBuffer? {
    var made: CMAudioFormatDescription?
    if format == nil {
      var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(audioRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
      CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                     magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                     formatDescriptionOut: &made)
    }
    guard let format = format ?? made,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mBytesPerFrame > 0
    else { return nil }
    let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(asbd.mChannelsPerFrame) : 1
    let length = Int(frames) * Int(asbd.mBytesPerFrame) * planes
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &block) == noErr, let block,
      CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
    else { return nil }
    var sample: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: CMItemCount(frames),
      presentationTimeStamp: CMTime(value: start, timescale: audioRate), packetDescriptions: nil,
      sampleBufferOut: &sample) == noErr
    else { return nil }
    return sample
  }

  /// From either pump once its side is done: the last one in finishes the file.
  private func finishIfDone() {
    guard live else { return }
    if s.reader.status == .failed { return fail(s.reader.error, from: .reader) }
    let go = shared.withLock { sh -> Bool in
      guard sh.continuation != nil, sh.videoDone, sh.audioDone, !sh.finishing else { return false }
      sh.finishing = true
      return true
    }
    guard go else { return }
    advanced()
    s.writer.endSession(atSourceTime: CMTime(s.total))
    s.writer.finishWriting { [self] in
      control.async { [self] in
        let failedMeanwhile = shared.withLock { sh -> Bool in
          sh.finishing = false
          return sh.continuation == nil
        }
        // The watchdog already ended the run while this was in flight (it never cancels a finishing writer):
        // the file is ours and unwanted, so remove it now that the writer is done with it.
        if failedMeanwhile {
          removeWrittenFiles()
          return releaseWhenQuiet()
        }
        if stopped.load(ordering: .sequentiallyConsistent) { return fail(CancellationError(), from: nil) }
        guard s.writer.status == .completed else { return fail(s.writer.error, from: .writer) }
        let (c, image) = shared.withLock { sh in (sh.continuation.take(), sh.firstFrame) }
        stopWatchdog()
        c?.resume(returning: image)
        releaseWhenQuiet()
      }
    }
  }

  /// Resumes a taken continuation once, from whichever of teardown and its backstop gets there first.
  private final class Resumer: Sendable {
    private let c: Mutex<CheckedContinuation<CGImage?, Error>?>
    init(_ c: CheckedContinuation<CGImage?, Error>) { self.c = Mutex(c) }
    /// true if this call resumed it.
    @discardableResult func resume(throwing error: any Error) -> Bool {
      guard let c = c.withLock({ $0.take() }) else { return false }
      c.resume(throwing: error)
      return true
    }
  }

  /// Ends the run with `error`, from any thread. The continuation is taken under the lock, so this happens once;
  /// the pumps see `stopped` and return. On `control` the writer is cancelled (so it stops writing the partial
  /// the runner is about to delete), the run resumes, and only then is the reader cancelled, on `teardownQueue`
  /// and never under a read in flight (`tearDownReader`). A wedged reader can therefore never hold the run open; should
  /// either cancel itself block, a `teardownBackstop` resumes the run anyway and the writer's file is removed
  /// once its cancel returns. While `finishWriting` is in flight its completion reports instead, unless the
  /// watchdog gives up on it (`evenWhileFinishing`); a finishing writer is never cancelled, and its completion
  /// removes the file.
  private func fail(_ error: (any Error)?, from source: Side?, evenWhileFinishing: Bool = false) {
    let taken = shared.withLock { sh -> (CheckedContinuation<CGImage?, Error>, finishing: Bool)? in
      guard sh.continuation != nil, evenWhileFinishing || !sh.finishing else { return nil }
      return sh.continuation.take().map { ($0, sh.finishing) }
    }
    guard let (c, finishing) = taken else { return }
    stopped.store(true, ordering: .sequentiallyConsistent)
    if let e = error, let found = ExportCause(e) { reported.withLock { $0 = $0 ?? found } }
    let mapped: any Error
    switch (error, source) {
    case (let e as ExportError, _): mapped = e
    case (let e as CancellationError, _): mapped = e
    case (let e?, .reader): mapped = ExportError(e, readerSide: true)
    case (let e?, _): mapped = ExportError(e, readerSide: false)
    case (nil, .reader): mapped = ExportError.sourceUnreadable(nil)
    case (nil, _): mapped = ExportError.other("The export stopped unexpectedly.")
    }
    control.async { [self] in
      classify(mapped) { [self] final in tearDown(c, with: final, finishing: finishing) }
    }
  }

  /// On `control`, once the error is final: cancels the writer, resumes the run, then tears the reader down.
  private func tearDown(_ c: CheckedContinuation<CGImage?, Error>, with mapped: any Error, finishing: Bool) {
    if let e = mapped as? ExportError, case .sourceUnreadable(let name?) = e {
      MediaLog.note("export: failing with \(name) unreadable")
    }
    let resumer = Resumer(c)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.teardownBackstop) {
      if resumer.resume(throwing: mapped) {
        MediaLog.note("export: teardown still waiting on AVFoundation after \(Self.teardownBackstop); ended the run")
      }
    }
    do {
      stopWatchdog()
      let t0 = Self.uptime()
      if !finishing, s.writer.status == .writing { s.writer.cancelWriting() }
      let t1 = Self.uptime()
      let late = !resumer.resume(throwing: mapped)
      // The backstop resumed first, so the runner may have tidied up before the writer stopped: tidy again.
      if late { removeWrittenFiles() }
      let writing = Duration.nanoseconds(Int64(t1 - t0))
      teardownQueue.async { [self] in
        tearDownReader { [self] waited, cancel in
          teardownTimes.withLock { $0 = (writing: writing, reading: cancel) }
          MediaLog.note("export: teardown cancelWriting \(writing), reads drained in \(waited), cancelReading \(cancel)")
          control.async { [self] in releaseWhenQuiet() }
        }
      }
    }
  }

  /// sRGB 8-bit. An HDR-kept frame is converted to SDR first, as the SDR export converts it (`HDRToSDR`), so the
  /// Done sheet's still reads like the picture. If the LUT render fails, Core Image's own tone map is used.
  private static func image(of buffer: CVPixelBuffer, hdr: Bool) -> CGImage? {
    func render(_ image: CIImage) -> CGImage? {
      imageContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    if !hdr { return render(CIImage(cvPixelBuffer: buffer)) }
    if let made = render(ReelCompositor.sourceImage(buffer, hdrOut: false)) { return made }
    MediaLog.note("export: thumbnail HDR → SDR render failed; using Core Image's tone map")
    return render(CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true]))
  }
}
