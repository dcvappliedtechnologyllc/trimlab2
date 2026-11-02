import CoreImage
import Foundation
import Synchronization
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// The pump-deadlock repro (hang-report.md): many exports of the audio-carrying fixtures at once, optionally under
/// spinning CPU load, each given `limit` seconds. Off by default; run with
/// `TRIMLAB_STRESS=<exports> [TRIMLAB_STRESS_LANES=<parallel>] [TRIMLAB_STRESS_LOAD=<spinning threads>]
///  swift test --filter ExportStressTests`.
@Suite struct ExportStressTests {
  static let env = ProcessInfo.processInfo.environment
  static let count = Int(env["TRIMLAB_STRESS"] ?? "") ?? 0
  static let lanes = Int(env["TRIMLAB_STRESS_LANES"] ?? "") ?? 4
  static let load = Int(env["TRIMLAB_STRESS_LOAD"] ?? "") ?? 0
  static let limit = Double(env["TRIMLAB_STRESS_LIMIT"] ?? "") ?? 60

  enum Outcome: Sendable { case done, failed(String), hung }

  final class Tally: Sendable {
    let counts = Mutex<(done: Int, failed: [String], hung: Int)>((0, [], 0))
    let spinning = Atomic<Bool>(true)
  }

  /// Last event seen (seconds since start, progress) for one export.
  final class Seen: Sendable {
    let last = Mutex<(at: Double, progress: Double)>((0, 0))
    let fired = Atomic<Bool>(false)
  }

  /// One export, abandoned (and cancelled) when no event arrives for `limit` seconds.
  static func once(_ make: @Sendable () async throws -> Reel, dir: URL, name: String,
                   onProgress: @escaping @Sendable (Double) -> Bool = { _ in false }) async throws -> Outcome {
    let reel = try await make()
    let runner = ExportRunner(resolve: ExportReelTests.resolve)
    let dest = dir.appending(path: name)
    let seen = Seen()
    let t0 = ContinuousClock.now
    func now() -> Double { (ContinuousClock.now - t0) / .seconds(1) }
    return await withTaskGroup(of: Outcome?.self) { group in
      group.addTask {
        do {
          for try await event in runner.start(reel: reel, dest: dest) {
            if case .progress(let p, _) = event {
              seen.last.withLock { $0 = (now(), p) }
              if !seen.fired.load(ordering: .relaxed), onProgress(p) { seen.fired.store(true, ordering: .relaxed) }
            }
          }
          return .done
        } catch is CancellationError {
          return nil
        } catch {
          return .failed("\(error)")
        }
      }
      group.addTask {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          let last = seen.last.withLock { $0 }
          if now() - last.at > limit {
            print("stress: \(name) (\(reel.clips.count) clips, \(reel.export.convertHDR ? "SDR" : "HDR")) no event for "
              + "\(limit) s, stuck at progress \(String(format: "%.3f", last.progress))")
            return .hung
          }
        }
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? .hung
    }
  }

  @Test(.enabled(if: count > 0), .timeLimit(.minutes(60)))
  func manyConcurrentExports() async throws {
    let tally = Tally()
    for _ in 0..<Self.load {
      let t = Thread {
        var x = 0.0
        while tally.spinning.load(ordering: .relaxed) { x = (x + 1).squareRoot() }
        _ = x
      }
      t.qualityOfService = .userInitiated
      t.start()
    }
    defer { tally.spinning.store(false, ordering: .relaxed) }

    let reels: [@Sendable () async throws -> Reel] = [
      { try await FixtureReel.make(ExportReelTests.mainReel).0 },
      { try await FixtureReel.make([("grain.mp4", 0, 6, .cut, .fill), ("grain.mp4", 0, 6, .cut, .fill)]).0 },
      { try await FixtureReel.eighteen().0 },
      {
        var reel = try await FixtureReel.make(ExportReelTests.mainReel).0
        reel.export.convertHDR = false
        return reel
      },
      { try await FixtureReel.make([("over3.mp4", 0, 20, .cut, .fill), ("over3.mp4", 30, 45, .crossfade(Limits.shortFade), .fill)]).0 },
    ]
    let t0 = ContinuousClock.now
    try await ExportReelTests.withTempDir { dir in
      try await withThrowingTaskGroup(of: Void.self) { group in
        for lane in 0..<Self.lanes {
          group.addTask {
            var i = lane
            while i < Self.count {
              let outcome = try await Self.once(reels[i % reels.count], dir: dir, name: "s\(i).mp4")
              tally.counts.withLock {
                switch outcome {
                case .done: $0.done += 1
                case .failed(let why): $0.failed.append("#\(i): \(why)")
                case .hung: $0.hung += 1
                }
              }
              if case .hung = outcome { print("stress: export #\(i) HUNG (> \(Self.limit) s)") }
              try? FileManager.default.removeItem(at: dir.appending(path: "s\(i).mp4"))
              i += Self.lanes
            }
          }
        }
        try await group.waitForAll()
      }
    }
    let t = tally.counts.withLock { $0 }
    let wall = (ContinuousClock.now - t0) / .seconds(1)
    print("stress: \(Self.count) exports, \(Self.lanes) lanes, load \(Self.load): done \(t.done), "
      + "failed \(t.failed.count), hung \(t.hung), wall \(String(format: "%.0f", wall)) s")
    for f in t.failed { print("stress: failed \(f)") }
    #expect(t.hung == 0)
    #expect(t.failed.isEmpty)
  }

  static let truncCount = Int(env["TRIMLAB_STRESS_TRUNC"] ?? "") ?? 0

  /// The source-goes-away case (ExportFailureTests.sourceRemovedDuringExportFailsAndDeletesPartial) at varied
  /// moments: every export must end (an error is expected), none may stall.
  @Test(.enabled(if: truncCount > 0), .timeLimit(.minutes(60)))
  func truncatedSourceNeverStalls() async throws {
    let tally = Tally()
    let source = try await Fixtures.url("over3.mp4")
    try await ExportReelTests.withTempDir { dir in
      try await withThrowingTaskGroup(of: Void.self) { group in
        for lane in 0..<Self.lanes {
          group.addTask {
            var i = lane
            while i < Self.truncCount {
              let copy = dir.appending(path: "src\(i)/IMG_\(i).MOV")
              try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(),
                                                      withIntermediateDirectories: true)
              try FileManager.default.copyItem(at: source, to: copy)
              var (reel, _) = try await FixtureReel.make([("over3.mp4", 0, 20, .cut, .fill),
                                                          ("over3.mp4", 0, 30, .cut, .fill)])
              reel.clips[1].source.absolutePath = copy.path
              let at = [0.02, 0.05, 0.1, 0.2, 0.35, 0.45, 0.55, 0.7][i % 8]
              let fixed = reel
              let outcome = try await Self.once({ fixed }, dir: dir, name: "t\(i).mp4") { p in
                guard p > at else { return false }
                if let handle = try? FileHandle(forWritingTo: copy) {
                  try? handle.truncate(atOffset: 0)
                  try? handle.close()
                }
                return true
              }
              tally.counts.withLock {
                switch outcome {
                case .done: $0.done += 1
                case .failed: $0.done += 1
                case .hung: $0.hung += 1
                }
              }
              if case .hung = outcome { print("stress: truncated export #\(i) (cut at \(at)) STALLED") }
              try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
              try? FileManager.default.removeItem(at: dir.appending(path: "t\(i).mp4"))
              i += Self.lanes
            }
          }
        }
        try await group.waitForAll()
      }
    }
    let t = tally.counts.withLock { $0 }
    print("stress: \(Self.truncCount) truncated-source exports, \(Self.lanes) lanes: ended \(t.done), stalled \(t.hung)")
    #expect(t.hung == 0)
  }

  static let teardownCount = Int(env["TRIMLAB_STRESS_TEARDOWN"] ?? "") ?? 0

  /// Teardown while a pump is inside a read (hang-report.md, crash rounds): cancel or stall with the video read
  /// stuck, so the audio pump sits in `copyNextSampleBuffer` when the reader is torn down. A crash kills the
  /// process; a clean pass prints the count.
  @Test(.enabled(if: teardownCount > 0), .timeLimit(.minutes(60)))
  func teardownDuringReads() async throws {
    let tally = Tally()
    for _ in 0..<Self.load {
      let t = Thread { var x = 0.0; while tally.spinning.load(ordering: .relaxed) { x = (x + 1).squareRoot() }; _ = x }
      t.start()
    }
    defer { tally.spinning.store(false, ordering: .relaxed) }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for lane in 0..<Self.lanes {
        group.addTask { try await Self.teardowns(lane: lane, tally: tally) }
      }
      try await group.waitForAll()
    }
    print("stress: teardown during reads: \(tally.counts.withLock { $0.done }) exports torn down, no crash")
  }

  static func teardowns(lane: Int, tally: Tally) async throws {
    var i = lane
    while i < teardownCount {
      defer { i += lanes }
      try await ExportReelTests.withTempDir { dir in
        let (reel, _) = try await FixtureReel.make(ExportReelTests.mainReel)
        let stuck = ExportFailureTests.StuckRead(at: Int64(5 + i % 20), hold: .milliseconds(1500))
        let stall = i % 2 == 1
        let runner = ExportRunner(resolve: ExportReelTests.resolve, testHook: nil,
                                  stallLimit: stall ? .milliseconds(300) : .seconds(20), frameHook: stuck.hook)
        let stream = runner.start(reel: reel, dest: dir.appending(path: "out.mp4"))
        let reading = Task { () -> Bool in
          do { for try await _ in stream {} } catch {}
          return true
        }
        if i % 4 == 2 {
          // Cancel early, while the reader is still prerolling and a read is likely waiting on it.
          try await Task.sleep(for: .microseconds(Int.random(in: 0...200_000)))
          await runner.cancel()
        } else if !stall {
          while !stuck.wasReached { try await Task.sleep(for: .milliseconds(5)) }
          // Let the audio pump run into the reader while the video read is held.
          try await Task.sleep(for: .milliseconds(Int.random(in: 0...400)))
          await runner.cancel()
        }
        _ = await reading.value
      }
      tally.counts.withLock { $0.done += 1 }
    }
  }

  static let goneCount = Int(env["TRIMLAB_STRESS_GONE"] ?? "") ?? 0

  /// Holds the main actor in long busy stretches (as ScreensTests' ImageRenderer pass does) until stopped.
  @MainActor static func hogMain(_ tally: Tally) async {
    while tally.spinning.load(ordering: .relaxed) {
      let end = ContinuousClock.now + .seconds(Double.random(in: 5...20))
      var x = 0.0
      while ContinuousClock.now < end, tally.spinning.load(ordering: .relaxed) { x = (x + 1).squareRoot() }
      _ = x
      await Task.yield()
    }
  }

  /// A source cut to nothing mid-export must always end as `sourceUnreadable(<its name>)`, never `.stalled` or an
  /// unnamed source, even with the main actor held and the CPUs busy. Alternates the two ExportFailureTests cases:
  /// truncation alone (the reader fails or stalls by itself) and truncation plus a stuck read with a short limit.
  @Test(.enabled(if: goneCount > 0), .timeLimit(.minutes(60)))
  func goneSourceIsNamedUnderLoad() async throws {
    let tally = Tally()
    for _ in 0..<Self.load {
      let t = Thread { var x = 0.0; while tally.spinning.load(ordering: .relaxed) { x = (x + 1).squareRoot() }; _ = x }
      t.qualityOfService = .userInitiated
      t.start()
    }
    let hog = Task { @MainActor in await Self.hogMain(tally) }
    // TRIMLAB_STRESS_GPU=<n>: n threads keep the GPU busy with large Core Image renders (as ImageRenderer does).
    for _ in 0..<(Int(Self.env["TRIMLAB_STRESS_GPU"] ?? "") ?? 0) {
      let t = Thread {
        let context = CIContext()
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 7680, height: 4320))
          .applyingGaussianBlur(sigma: 40)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        while tally.spinning.load(ordering: .relaxed) {
          _ = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
        }
      }
      t.start()
    }
    defer { tally.spinning.store(false, ordering: .relaxed); hog.cancel() }
    let source = try await Fixtures.url("over3.mp4")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for lane in 0..<Self.lanes {
        group.addTask {
          var i = lane
          while i < Self.goneCount {
            defer { i += Self.lanes }
            try await ExportReelTests.withTempDir { dir in
              let copy = dir.appending(path: "src/GONE_\(i).MOV")
              try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
              try FileManager.default.copyItem(at: source, to: copy)
              var (reel, _) = try await FixtureReel.make([("over3.mp4", 0, 20, .cut, .fill), ("over3.mp4", 0, 30, .cut, .fill)])
              reel.clips[1].source.absolutePath = copy.path
              let withStuckRead = i % 2 == 1
              @Sendable func cut() {
                if let h = try? FileHandle(forWritingTo: copy) { try? h.truncate(atOffset: 0); try? h.close() }
              }
              let stuck = ExportFailureTests.StuckRead(at: 40, hold: .seconds(6))
              let runner = withStuckRead
                ? ExportRunner(resolve: ExportReelTests.resolve, testHook: nil, stallLimit: .milliseconds(500),
                               frameHook: { frame in if frame == 40 { cut() }; stuck.hook(frame) })
                : ExportRunner(resolve: ExportReelTests.resolve)
              var outcome = "done"
              var cutDone = false
              do {
                for try await event in runner.start(reel: reel, dest: dir.appending(path: "out.mp4")) {
                  if !withStuckRead, case .progress(let p, _) = event, p > 0.05, !cutDone { cut(); cutDone = true }
                }
              } catch let error as ExportError {
                outcome = error == .sourceUnreadable("GONE_\(i).MOV") ? "named" : "\(error)"
              } catch {
                outcome = "\(error)"
              }
              tally.counts.withLock {
                if outcome == "named" { $0.done += 1 } else { $0.failed.append("#\(i) \(withStuckRead ? "stuck" : "plain"): \(outcome)") }
              }
            }
          }
        }
      }
      try await group.waitForAll()
    }
    let t = tally.counts.withLock { $0 }
    print("stress: gone source under load: named \(t.done), wrong \(t.failed.count)")
    for f in t.failed { print("stress: wrong \(f)") }
    #expect(t.failed.isEmpty)
  }
}
