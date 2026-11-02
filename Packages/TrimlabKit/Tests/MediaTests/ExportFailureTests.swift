import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// §5.5 steps 6–7 end to end: cancel, a source going away mid-export, disk full and the software retry.
@Suite(.serialized, .exclusiveMedia) struct ExportFailureTests {
  typealias R = ExportReelTests

  /// Records every attempt the runner makes and answers with `inject`.
  final class AttemptLog: Sendable {
    let attempts = Mutex<[Attempt]>([])
    let inject: @Sendable (Attempt) -> ExportError?
    init(_ inject: @escaping @Sendable (Attempt) -> ExportError?) { self.inject = inject }
    var hook: @Sendable (Attempt) -> ExportError? {
      { attempt in
        self.attempts.withLock { $0.append(attempt) }
        return self.inject(attempt)
      }
    }
    var all: [Attempt] { attempts.withLock { $0 } }
  }

  static func partials(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial.mp4") }
  }

  @Test func cancelLeavesNoPartial() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("over3.mp4", 0, 181, .cut, .fill)])
      let dest = dir.appending(path: "long.mp4")
      let runner = ExportRunner(resolve: R.resolve)
      var cancelWall: Duration?
      var sawPartial = false
      do {
        for try await event in runner.start(reel: reel, dest: dest) {
          if case .progress(let p, _) = event, p > 0.05, cancelWall == nil {
            sawPartial = try !Self.partials(in: dir).isEmpty
            let t0 = ContinuousClock.now
            await runner.cancel()
            cancelWall = ContinuousClock.now - t0
          }
          if case .done = event { Issue.record("export finished after cancel") }
        }
        Issue.record("stream ended without an error")
      } catch is CancellationError {
      } catch {
        Issue.record("expected CancellationError, got \(error)")
      }
      let wall = try #require(cancelWall)
      print("export: cancel() returned in \(wall)")
      #expect(wall < .seconds(3))
      #expect(sawPartial, "no partial file while writing")
      #expect(try Self.partials(in: dir).isEmpty)
      #expect(!FileManager.default.fileExists(atPath: dest.path))
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
  }

  /// Review Focus 2: an unlinked open file stays readable on APFS, an ejected drive does not; truncating the
  /// copy to 0 bytes is the closest local stand-in for the drive going away.
  @Test func sourceRemovedDuringExportFailsAndDeletesPartial() async throws {
    try await R.withTempDir { dir in
      let copy = dir.appending(path: "src/IMG_4821.MOV")
      try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: try await Fixtures.url("over3.mp4"), to: copy)
      var (reel, _) = try await FixtureReel.make([("over3.mp4", 0, 20, .cut, .fill),
                                                  ("over3.mp4", 0, 30, .cut, .fill)])
      reel.clips[1].source.absolutePath = copy.path
      let out = dir.appending(path: "out", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let dest = out.appending(path: "reel.mp4")
      let runner = ExportRunner(resolve: R.resolve)
      var truncated = false
      do {
        for try await event in runner.start(reel: reel, dest: dest) {
          if case .progress(let p, _) = event, p > 0.05, !truncated {
            let handle = try FileHandle(forWritingTo: copy)
            try handle.truncate(atOffset: 0)
            try handle.close()
            truncated = true
          }
        }
        Issue.record("export succeeded with a truncated source")
      } catch let error as ExportError {
        guard case .sourceUnreadable = error else {
          Issue.record("expected sourceUnreadable, got \(error)")
          return
        }
        print("export: truncated source → \(error.sentence)")
      }
      #expect(truncated)
      #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }
  }

  @Test func diskFullNotRetried() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 2, .cut, .fill)])
      let log = AttemptLog { _ in .diskFull }
      let runner = ExportRunner(resolve: R.resolve, testHook: log.hook)
      let dest = dir.appending(path: "out.mp4")
      do {
        for try await event in runner.start(reel: reel, dest: dest) {
          if case .done = event { Issue.record("export succeeded") }
        }
        Issue.record("stream ended without an error")
      } catch let error as ExportError {
        #expect(error == .diskFull)
        #expect(error.sentence == "The disk is full.")
      }
      #expect(log.all == [Attempt(number: 1, software: false)])
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
  }

  @Test func encoderFailedRetriesSoftware() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("portrait_hevc.mov", 0, 2, .cut, .fill)])
      let log = AttemptLog { $0.number == 1 ? .encoderFailed : nil }
      let outputs = Mutex<[String]>([])
      let runner = ExportRunner(resolve: R.resolve, testHook: log.hook,
                                onJob: { job in outputs.withLock { $0.append(job.outputURL.lastPathComponent) } })
      let dest = dir.appending(path: "out.mp4")
      var result: ExportResult?
      for try await event in runner.start(reel: reel, dest: dest) {
        if case .done(let r) = event { result = r }
      }
      let r = try #require(result)
      #expect(r.usedSoftwareEncoder)
      #expect(log.all == [Attempt(number: 1, software: false), Attempt(number: 2, software: true)])
      // Each attempt writes its own `<stem>.<8 hex>.partial.mp4`, so a late teardown of one can't touch the other.
      let names = outputs.withLock { $0 }
      #expect(names.count == 2 && Set(names).count == 2, "\(names)")
      #expect(names.allSatisfy { $0.wholeMatch(of: /out\.[0-9a-f]{8}\.partial\.mp4/) != nil }, "\(names)")
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.mp4"])
      #expect(try await FFprobe.countedFrames(dest) == R.expectedFrames(Planner.plan(reel)))
    }
  }

  @Test func encoderFailedTwiceGivesUp() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      let log = AttemptLog { _ in .encoderFailed }
      let runner = ExportRunner(resolve: R.resolve, testHook: log.hook)
      await #expect(throws: ExportError.encoderFailed) {
        for try await _ in runner.start(reel: reel, dest: dir.appending(path: "out.mp4")) {}
      }
      #expect(log.all == [Attempt(number: 1, software: false), Attempt(number: 2, software: true)])
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
  }

  @Test func softwareRequestFailingIsNotRetried() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      let log = AttemptLog { _ in .encoderFailed }
      let runner = ExportRunner(resolve: R.resolve, testHook: log.hook)
      await #expect(throws: ExportError.encoderFailed) {
        for try await _ in runner.start(reel: reel, dest: dir.appending(path: "out.mp4"), software: true) {}
      }
      #expect(log.all == [Attempt(number: 1, software: true)])
    }
  }

  /// I5: a thumbnail that can't be made is logged and the export still finishes.
  @Test func missingThumbnailStillSaves() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      let runner = ExportRunner(resolve: R.resolve, testHook: nil, makesThumbnail: false)
      let dest = dir.appending(path: "out.mp4")
      var result: ExportResult?
      let (_, logged) = try await MediaLog.capturing {
        for try await event in runner.start(reel: reel, dest: dest) {
          if case .done(let r) = event { result = r }
        }
      }
      let r = try #require(result)
      #expect(r.firstFrame == nil)
      #expect(r.url == dest)
      #expect(FileManager.default.fileExists(atPath: dest.path))
      #expect(logged.contains { $0.contains("thumbnail") }, "\(logged)")
    }
  }

  /// The partial name is unique to the export; someone else's `out.partial.mp4` is left alone.
  @Test func foreignPartialIsLeftAlone() async throws {
    try await R.withTempDir { dir in
      let foreign = dir.appending(path: "out.partial.mp4")
      try Data("not ours".utf8).write(to: foreign)
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      var names: Set<String> = []
      for try await event in ExportRunner(resolve: R.resolve).start(reel: reel, dest: dir.appending(path: "out.mp4")) {
        if case .progress = event { names.formUnion(try Self.partials(in: dir)) }
      }
      #expect(try Data(contentsOf: foreign) == Data("not ours".utf8))
      #expect(names.contains { $0 != "out.partial.mp4" && $0.hasPrefix("out.") }, "\(names)")
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["out.mp4", "out.partial.mp4"])
    }
  }

  // MARK: stalls (hang-report.md)

  /// Blocks the video pump at grid frame `at` for `hold`, as a reader that stopped delivering would.
  final class StuckRead: Sendable {
    let at: Int64
    let hold: Duration
    let reached = Atomic<Bool>(false)
    let released = Atomic<Bool>(false)
    /// The attempt's job, held weakly so the test can see it freed.
    let job = Mutex<WeakJob>(WeakJob())
    struct WeakJob { weak var value: ExportJob? }
    init(at: Int64, hold: Duration) { (self.at, self.hold) = (at, hold) }
    var wasReached: Bool { reached.load(ordering: .sequentiallyConsistent) }
    var wasReleased: Bool { released.load(ordering: .sequentiallyConsistent) }
    var jobAlive: Bool { job.withLock { $0.value != nil } }
    var teardown: (writing: Duration, reading: Duration)? { job.withLock { $0.value?.teardownTimes.withLock { $0 } } }
    var hook: @Sendable (Int64) -> Void {
      { frame in
        guard frame == self.at else { return }
        self.reached.store(true, ordering: .sequentiallyConsistent)
        Thread.sleep(forTimeInterval: self.hold / .seconds(1))
        self.released.store(true, ordering: .sequentiallyConsistent)
      }
    }
    var onJob: @Sendable (ExportJob) -> Void { { job in self.job.withLock { $0.value = job } } }
  }

  /// Polls `condition` every 20 ms for up to `seconds`.
  static func eventually(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// The watchdog ends an export that writes nothing for `stallLimit`, without waiting for the stuck pump.
  @Test func stalledExportFailsInsteadOfHanging() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("portrait_hevc.mov", 0, 4, .cut, .fill)])
      let stuck = StuckRead(at: 10, hold: .seconds(8))
      var runner: ExportRunner? = ExportRunner(resolve: R.resolve, testHook: nil, stallLimit: .milliseconds(500),
                                               frameHook: stuck.hook, onJob: stuck.onJob)
      let t0 = ContinuousClock.now
      do {
        for try await event in runner!.start(reel: reel, dest: dir.appending(path: "out.mp4")) {
          if case .done = event { Issue.record("export finished through a stall") }
        }
        Issue.record("stream ended without an error")
      } catch let error as ExportError {
        #expect(error == .stalled(seconds: 1))
        #expect(error.sentence == "The export made no progress for 1 second, so it was stopped.")
      }
      let wall = ContinuousClock.now - t0
      print("export: stall reported after \(wall)")
      #expect(stuck.wasReached)
      #expect(wall < .seconds(5), "the run waited for the stuck pump (\(wall))")
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
      #expect(!stuck.wasReleased, "the hold ended before the stall was reported")
      // Once the hold ends the pump returns and nothing keeps the job alive.
      runner = nil
      #expect(try await Self.eventually(12) { stuck.wasReleased }, "the stuck pump never returned")
      // Freed within one backed-off check (≤ 5 s) of the pump returning.
      #expect(try await Self.eventually(7) { !stuck.jobAlive }, "the job was never freed")
    }
  }

  /// A file stat that never returns (a hung network share, a sleeping drive) must not hold up the watchdog: with
  /// the read stuck too, the export still reports `.stalled` on time.
  @Test func stuckFileStatDoesNotDelayTheStall() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("portrait_hevc.mov", 0, 4, .cut, .fill)])
      let stuck = StuckRead(at: 10, hold: .seconds(8))
      let runner = ExportRunner(resolve: R.resolve, testHook: nil, stallLimit: .milliseconds(500),
                                frameHook: stuck.hook, onJob: { job in
                                  job.statHook.withLock { $0 = { Thread.sleep(forTimeInterval: 8) } }
                                  stuck.onJob(job)
                                })
      let t0 = ContinuousClock.now
      do {
        for try await event in runner.start(reel: reel, dest: dir.appending(path: "out.mp4")) {
          if case .done = event { Issue.record("export finished through a stall") }
        }
        Issue.record("stream ended without an error")
      } catch let error as ExportError {
        #expect(error == .stalled(seconds: 1))
      }
      let wall = ContinuousClock.now - t0
      print("export: stall with a stuck stat reported after \(wall)")
      #expect(stuck.wasReached)
      #expect(wall < .seconds(5), "the watchdog waited for the stuck stat (\(wall))")
    }
  }

  /// A stall whose cause is a source that went away names that source, with its own sentence, not `.stalled`.
  @Test func stallWithAGoneSourceNamesIt() async throws {
    try await R.withTempDir { dir in
      let copy = dir.appending(path: "src/IMG_STALL.MOV")
      try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: try await Fixtures.url("portrait_hevc.mov"), to: copy)
      var (reel, _) = try await FixtureReel.make([("portrait_hevc.mov", 0, 4, .cut, .fill)])
      reel.clips[0].source.absolutePath = copy.path
      let out = dir.appending(path: "out", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let stuck = StuckRead(at: 10, hold: .seconds(8))
      // The read sticks because the file has just been cut to nothing, as a pulled drive would leave it.
      let hook: @Sendable (Int64) -> Void = { frame in
        if frame == 10, let handle = try? FileHandle(forWritingTo: copy) {
          try? handle.truncate(atOffset: 0)
          try? handle.close()
        }
        stuck.hook(frame)
      }
      let runner = ExportRunner(resolve: R.resolve, testHook: nil, stallLimit: .milliseconds(500), frameHook: hook)
      do {
        for try await _ in runner.start(reel: reel, dest: out.appending(path: "out.mp4")) {}
        Issue.record("stream ended without an error")
      } catch let error as ExportError {
        #expect(error == .sourceUnreadable("IMG_STALL.MOV"), "\(error)")
        #expect(error.sentence == "IMG_STALL.MOV can't be read any more. Check that its drive is connected.")
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }
  }

  /// A read wedged inside the reader while the other output has already ended: teardown has nothing to drain,
  /// so it must back off (re-arming, no thread held, no spinning) until the read returns, then cancel the reader.
  @Test func teardownBacksOffWhileAReadIsWedged() async throws {
    try await R.withTempDir { dir in
      // The sound ends with the first clip (4 s); the picture runs on through the silent one.
      let (reel, _) = try await FixtureReel.make([("portrait_hevc.mov", 0, 4, .cut, .fill),
                                                  ("noaudio.mp4", 0, 3, .cut, .fill)])
      final class Wedge: Sendable {
        let reads = Atomic<Int>(0)
        let reached = Atomic<Bool>(false)
        let job = Mutex<StuckRead.WeakJob>(StuckRead.WeakJob())
      }
      let wedge = Wedge()
      let runner = ExportRunner(resolve: R.resolve, testHook: nil, onJob: { job in
        wedge.job.withLock { $0.value = job }
        job.readHook.withLock {
          $0 = { video in
            // The 180th video read (about 6 s in, the audio long ended) sticks for 3 s.
            guard video, wedge.reads.add(1, ordering: .relaxed).newValue == 180 else { return }
            wedge.reached.store(true, ordering: .sequentiallyConsistent)
            Thread.sleep(forTimeInterval: 3)
          }
        }
      })
      let stream = runner.start(reel: reel, dest: dir.appending(path: "out.mp4"))
      let reading = Task { () -> (any Error)? in
        do { for try await _ in stream {} } catch { return error }
        return nil
      }
      while !wedge.reached.load(ordering: .sequentiallyConsistent) { try await Task.sleep(for: .milliseconds(10)) }
      let t0 = ContinuousClock.now
      await runner.cancel()
      let error = await reading.value
      #expect(error is CancellationError, "\(String(describing: error))")
      #expect(ContinuousClock.now - t0 < .seconds(1.5), "cancel waited for the wedged read")
      // While the read is held, teardown only re-arms its back-off: a handful of steps, not a spin.
      try await Task.sleep(for: .seconds(2))
      let job = try #require(wedge.job.withLock { $0.value })
      let steps = job.teardownSteps.load(ordering: .relaxed)
      print("export: teardown steps while a read was wedged for 2 s: \(steps)")
      #expect(steps < 30, "teardown spun: \(steps) steps")
      #expect(job.teardownTimes.withLock { $0 } == nil, "the reader was cancelled under the wedged read")
      // Once the read returns, teardown cancels the reader and the job is let go.
      #expect(try await Self.eventually(8) { wedge.job.withLock { $0.value?.teardownTimes.withLock { $0 } } != nil
        || wedge.job.withLock { $0.value == nil } })
    }
  }

  /// Cancel must not need the pump's queue: with the video read stuck, the stream still ends promptly.
  @Test func cancelWhileVideoReadIsStuck() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("portrait_hevc.mov", 0, 4, .cut, .fill)])
      let stuck = StuckRead(at: 10, hold: .seconds(8))
      let runner = ExportRunner(resolve: R.resolve, testHook: nil, frameHook: stuck.hook, onJob: stuck.onJob)
      let stream = runner.start(reel: reel, dest: dir.appending(path: "out.mp4"))
      let reading = Task { () -> (any Error)? in
        do {
          for try await _ in stream {}
          return nil
        } catch {
          return error
        }
      }
      while !stuck.wasReached { try await Task.sleep(for: .milliseconds(10)) }
      let t0 = ContinuousClock.now
      await runner.cancel()
      let error = await reading.value
      let wall = ContinuousClock.now - t0
      // Teardown cancels the reader after the run has resumed; give it a moment to record its timings.
      _ = try await Self.eventually(2) { stuck.teardown != nil }
      let teardown = stuck.teardown
      print("export: cancel with a stuck read ended the stream in \(wall); teardown cancelWriting "
        + "\(teardown.map { "\($0.writing)" } ?? "?"), cancelReading \(teardown.map { "\($0.reading)" } ?? "?")")
      #expect(error is CancellationError, "\(String(describing: error))")
      #expect(wall < .seconds(1.5), "cancel waited for the stuck pump (\(wall))")
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
  }
}

/// §5.5 step 7 classification, from synthetic errors.
@Suite struct ExportErrorClassTests {
  static func av(_ code: AVError.Code, underlying: NSError? = nil) -> NSError {
    NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
  }

  static func status(_ code: Int) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: code) }

  @Test func videoToolboxFailuresAreEncoderFailed() {
    // kVTVideoEncoderMalfunctionErr -12912, kVTVideoEncoderNotAvailableNowErr -12915.
    for code in [AVError.Code.unknown, .decodeFailed] {
      for vt in [-12912, -12915, -12902] {
        #expect(ExportError(Self.av(code, underlying: Self.status(vt))) == .encoderFailed, "\(code) / \(vt)")
      }
    }
    #expect(ExportError(Self.av(.unknown, underlying: NSError(domain: "com.apple.videotoolbox", code: -1)))
      == .encoderFailed)
    #expect(ExportError(Self.status(-12912)) == .encoderFailed)
    #expect(ExportError(Self.av(.encoderNotFound)) == .encoderFailed)
  }

  @Test func diskFullWinsAndIsNeverEncoder() {
    #expect(ExportError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskFull)
    #expect(ExportError(Self.av(.unknown, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
      == .diskFull)
    #expect(ExportError(Self.av(.diskFull)) == .diskFull)
    #expect(ExportError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .diskFull)
  }

  @Test func readerSideIsSource() {
    #expect(ExportError(Self.av(.decodeFailed, underlying: Self.status(-12909)), readerSide: true)
      == .sourceUnreadable(nil))
    #expect(ExportError(Self.av(.unknown), readerSide: true) == .sourceUnreadable(nil))
    #expect(ExportError(Self.av(.failedToLoadMediaData)) == .sourceUnreadable(nil))
  }

  @Test func unrelatedIsOther() {
    #expect(ExportError(Self.av(.unknown)).isOther)
    #expect(ExportError(Self.av(.unknown, underlying: Self.status(-50))).isOther)
    #expect(ExportError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)).isOther)
  }

  @Test func sentences() {
    #expect(ExportError.diskFull.sentence == "The disk is full.")
    #expect(ExportError.sourceUnreadable(nil).sentence
      == "A clip can't be read any more. Check that its drive is connected.")
    #expect(ExportError.sourceUnreadable("IMG_4821.MOV").sentence
      == "IMG_4821.MOV can't be read any more. Check that its drive is connected.")
    #expect(ExportError.encoderFailed.sentence == "The video encoder stopped.")
    #expect(ExportError.other("detail").sentence == "Something went wrong while saving.")
    #expect(ExportError.stalled(seconds: 20).sentence
      == "The export made no progress for 20 seconds, so it was stopped.")
  }
}

/// §4.9 destination checks.
@Suite struct ExportPreflightTests {
  static func reel() async throws -> Reel {
    try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill), ("portrait_hevc.mov", 0, 1, .cut, .fill)]).0
  }

  static let resolve: @Sendable (ReelClip) -> URL? = { URL(filePath: $0.source.absolutePath) }

  static func check(_ dest: URL, _ reel: Reel, project: URL? = nil, resolve: (ReelClip) -> URL? = resolve,
                    exists: Bool = false, writable: Bool = true) -> PreflightIssue? {
    ExportPreflight.check(dest: dest, reel: reel, projectFile: project, resolve: resolve,
                          fileExists: { _ in exists }, isWritable: { _ in writable })
  }

  @Test func destEqualsSourceRefused() async throws {
    let reel = try await Self.reel()
    let source = reel.clips[1].source.absolutePath
    let upper = URL(filePath: (source as NSString).deletingLastPathComponent)
      .appending(path: URL(filePath: source).lastPathComponent.uppercased())
    #expect(Self.check(upper, reel, exists: true) == .isReelFile)
    // Through a dot segment and a symlinked folder.
    let tmp = FileManager.default.temporaryDirectory.appending(path: "trimlab2-preflight-\(UUID())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let link = tmp.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link,
                                               withDestinationURL: URL(filePath: source).deletingLastPathComponent())
    #expect(Self.check(URL(filePath: link.path + "/./" + URL(filePath: source).lastPathComponent), reel,
                       exists: true) == .isReelFile)

    let project = tmp.appending(path: "Spa Tour.trimlab")
    #expect(Self.check(tmp.appending(path: "spa tour.TRIMLAB"), reel, project: project, exists: true) == .isReelFile)
  }

  @Test func missingClipBlocks() async throws {
    var reel = try await Self.reel()
    reel.clips[1].source.absolutePath = "/Volumes/Card/DCIM/IMG_4821.MOV"
    let dest = FileManager.default.temporaryDirectory.appending(path: "new.mp4")
    #expect(Self.check(dest, reel, resolve: { $0.id == reel.clips[1].id ? nil : Self.resolve($0) })
      == .missing("IMG_4821.MOV"))
  }

  @Test func existingFileReported() async throws {
    let reel = try await Self.reel()
    let dest = FileManager.default.temporaryDirectory.appending(path: "taken.mp4")
    #expect(Self.check(dest, reel, exists: true) == .exists)
    #expect(Self.check(dest, reel, exists: false) == nil)
  }

  /// M-4: a folder already named like the export is never "a file to replace".
  @Test func existingFolderBlocks() async throws {
    let reel = try await Self.reel()
    let tmp = FileManager.default.temporaryDirectory.appending(path: "trimlab2-preflight-dir-\(UUID())")
    let folder = tmp.appending(path: "Spa Tour.mp4", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(ExportPreflight.check(dest: folder, reel: reel, projectFile: nil, resolve: Self.resolve) == .isFolder)
    // A file of that name is still the Replace case.
    let file = tmp.appending(path: "Other.mp4")
    try Data("x".utf8).write(to: file)
    #expect(ExportPreflight.check(dest: file, reel: reel, projectFile: nil, resolve: Self.resolve) == .exists)
  }

  @Test func unwritableFolderReported() async throws {
    let reel = try await Self.reel()
    let dest = FileManager.default.temporaryDirectory.appending(path: "new.mp4")
    #expect(Self.check(dest, reel, writable: false) == .folderUnwritable)
  }

  @Test func realFileSystemDefaults() async throws {
    let reel = try await Self.reel()
    let source = URL(filePath: reel.clips[0].source.absolutePath)
    #expect(ExportPreflight.check(dest: source, reel: reel, projectFile: nil, resolve: Self.resolve) == .isReelFile)
    let fresh = FileManager.default.temporaryDirectory.appending(path: "trimlab2-\(UUID()).mp4")
    #expect(ExportPreflight.check(dest: fresh, reel: reel, projectFile: nil, resolve: Self.resolve) == nil)
  }
}

extension ExportError {
  var isOther: Bool { if case .other = self { true } else { false } }
}
