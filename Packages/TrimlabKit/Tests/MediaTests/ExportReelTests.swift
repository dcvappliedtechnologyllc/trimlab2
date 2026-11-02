import AVFoundation
import Foundation
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// §5.4 / §5.5 end-to-end exports, checked with ffprobe. Serialized: each test runs a full export.
@Suite(.serialized, .exclusiveMedia) struct ExportReelTests {
  /// About 12 s: portrait 29.97 HEVC, a silent clip, 4K landscape (Fill) with a Short crossfade into it, HLG.
  static let mainReel: [FixtureReel.Spec] = [
    ("portrait_hevc.mov", 0, 4, .cut, .fill),
    ("noaudio.mp4", 0, 3, .cut, .fill),
    ("landscape.mp4", 0, 3, .crossfade(Limits.shortFade), .fill),
    ("hlg.mov", 0, 2.25, .cut, .fill),
  ]

  struct Exported {
    let url: URL
    let plan: CompositionPlan
    let result: ExportResult
    /// Each event with the seconds since `start` when the test received it.
    let events: [(at: Double, event: ExportEvent)]
    let wall: Double
  }

  static let resolve: @Sendable (ReelClip) -> URL? = { URL(filePath: $0.source.absolutePath) }

  /// A fresh temp folder, removed after `body`.
  static func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory.appending(path: "trimlab2-export-\(UUID())",
                                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
  }

  static func export(_ specs: [FixtureReel.Spec], in dir: URL, software: Bool = false,
                     edit: (inout Reel) -> Void = { _ in }) async throws -> Exported {
    var (reel, _) = try await FixtureReel.make(specs)
    edit(&reel)
    let dest = dir.appending(path: "out.mp4")
    let runner = ExportRunner(resolve: resolve)
    let t0 = ContinuousClock.now
    var events: [(Double, ExportEvent)] = []
    var result: ExportResult?
    for try await event in runner.start(reel: reel, dest: dest, software: software) {
      events.append(((ContinuousClock.now - t0) / .seconds(1), event))
      if case .done(let r) = event { result = r }
    }
    let wall = (ContinuousClock.now - t0) / .seconds(1)
    return Exported(url: dest, plan: Planner.plan(reel), result: try #require(result), events: events, wall: wall)
  }

  static func videoStream(_ url: URL) async throws -> [String: Any] {
    try #require(try await FFprobe.streams(url).first { $0["codec_type"] as? String == "video" })
  }

  static func audioStreams(_ url: URL) async throws -> [[String: Any]] {
    try await FFprobe.streams(url).filter { $0["codec_type"] as? String == "audio" }
  }

  static func expectedFrames(_ plan: CompositionPlan) -> Int {
    Int((plan.total.seconds / plan.frameDuration.seconds).rounded())
  }

  /// Every PTS delta is one frame duration (to ffprobe's microsecond print precision).
  static func expectGridDeltas(_ url: URL, fd: Double) async throws {
    let pts = try await FFprobe.frames(url).map(\.ptsTime)
    #expect(pts.first.map { abs($0) < 1e-6 } == true, "first pts \(pts.first ?? .nan)")
    let bad = zip(pts, pts.dropFirst()).enumerated().filter { abs($0.element.1 - $0.element.0 - fd) > 1e-5 }
    let first = bad.first.map { "frame \($0.offset): \($0.element.1 - $0.element.0)" } ?? ""
    #expect(bad.count == 0, "\(bad.count) off-grid deltas vs \(fd), first \(first)")
  }

  // MARK: main Reel

  @Test func reelExportShape() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export(Self.mainReel, in: dir)
      print("export: \(String(format: "%.2f", e.plan.total.seconds)) s Reel in \(String(format: "%.2f", e.wall)) s wall")
      let v = try await Self.videoStream(e.url)
      #expect(v["codec_name"] as? String == "h264")
      #expect(v["profile"] as? String == "High")
      #expect(v["width"] as? Int == 1080)
      #expect(v["height"] as? Int == 1920)
      #expect(v["color_primaries"] as? String == "bt709")
      #expect(v["color_transfer"] as? String == "bt709")
      #expect(v["color_space"] as? String == "bt709")
      let atoms = try FFprobe.atomOrder(e.url).filter { $0 != "free" && $0 != "wide" }
      #expect(Array(atoms.prefix(3)) == ["ftyp", "moov", "mdat"], "\(atoms)")
      #expect(e.result.url == e.url)
      let thumb = try #require(e.result.firstFrame)
      #expect(thumb.width == 1080 && thumb.height == 1920)
      let size = try FileManager.default.attributesOfItem(atPath: e.url.path)[.size] as? Int64
      #expect(e.result.bytes == size)
      #expect(!e.result.usedSoftwareEncoder)
    }
  }

  @Test func exactCFRFrameCount() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export(Self.mainReel, in: dir)
      #expect(try await FFprobe.countedFrames(e.url) == Self.expectedFrames(e.plan))
      try await Self.expectGridDeltas(e.url, fd: e.plan.frameDuration.seconds)
    }
  }

  @Test func durationWithinOneFrame() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export(Self.mainReel, in: dir)
      let duration = try #require(Double(try await FFprobe.format(e.url)["duration"] as? String ?? ""))
      #expect(abs(duration - e.plan.total.seconds) <= e.plan.frameDuration.seconds,
              "duration \(duration) vs total \(e.plan.total.seconds)")
    }
  }

  /// 12 s of grain.mp4: the encoder spends what it is given only on content that needs it. The flat testsrc2
  /// clips of `mainReel` come out ~20 % under target (11.2 Mb/s) whatever the settings; real footage hits it.
  @Test func bitrateWithin15Percent() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("grain.mp4", 0, 6, .cut, .fill), ("grain.mp4", 0, 6, .cut, .fill)], in: dir)
      #expect(e.plan.total.seconds > 11.5)
      let rate = try await #require(Double(try Self.videoStream(e.url)["bit_rate"] as? String ?? ""))
      print("export: video bitrate \(Int(rate)) b/s (target 14 000 000)")
      #expect(abs(rate - 14_000_000) / 14_000_000 <= 0.15, "bit_rate \(rate)")
    }
  }

  @Test func audioIsAac48kStereo() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export(Self.mainReel, in: dir)
      let audio = try await Self.audioStreams(e.url)
      #expect(audio.count == 1)
      let a = try #require(audio.first)
      #expect(a["codec_name"] as? String == "aac")
      #expect(a["profile"] as? String == "LC")
      #expect(a["sample_rate"] as? String == "48000")
      #expect(a["channels"] as? Int == 2)
    }
  }

  @Test func progressMonotonicAndThrottled() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export(Self.mainReel, in: dir)
      let progress = e.events.compactMap { item -> (Double, Double, Double?)? in
        if case .progress(let p, let eta) = item.event { return (item.at, p, eta) }
        return nil
      }
      #expect(progress.count >= 3)
      #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.1 < $1.1 }, "not increasing")
      let span = (progress.last?.0 ?? 0) - (progress.first?.0 ?? 0)
      #expect(Double(progress.count) <= span * 10 + 1, "\(progress.count) events over \(span) s")
      #expect((progress.last?.1 ?? 0) >= 0.99)
      #expect(progress.contains { $0.2 != nil }, "no ETA")
      #expect(progress.allSatisfy { $0.1 >= 0 && $0.1 <= 1 })
      guard case .done = e.events.last?.event else {
        Issue.record("last event is not .done")
        return
      }
      #expect(e.events.filter { if case .done = $0.event { true } else { false } }.count == 1)
    }
  }

  @Test func partialRenamedOnSuccess() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export(Self.mainReel, in: dir)
      let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      #expect(names == ["out.mp4"], "\(names)")
      #expect(FileManager.default.fileExists(atPath: e.url.path))
    }
  }

  // MARK: CFR across rates

  @Test func crossfadeVFRIntoSixtyIsCFRAndGapless() async throws {
    try await Self.withTempDir { dir in
      // bright60 stands in for sixty.mp4: same 60 fps, but flat 0xC0 grey, so the blend is visible in luma
      // (sixty.mp4 and vfr.mp4 differ by ~4 YAVG).
      let e = try await Self.export([
        ("portrait_hevc.mov", 0, 5, .cut, .fill),
        ("vfr.mp4", 0, 4, .cut, .fill),
        ("bright60.mp4", 0, 3, .crossfade(Limits.shortFade), .fill),
      ], in: dir)
      let fd = e.plan.frameDuration
      #expect(fd == RationalTime(1001, 30000))
      #expect(try await FFprobe.countedFrames(e.url) == Self.expectedFrames(e.plan))
      try await Self.expectGridDeltas(e.url, fd: fd.seconds)

      let overlap = e.plan.placements[2].reelSpan.start.seconds
      let overlapEnd = overlap + e.plan.placements[2].fadeIn.seconds
      let frames = try await FFprobe.frameYAVGs(e.url)
      let vfrOnly = try #require(frames.last { $0.pts < overlap - 1e-6 })
      let sixtyOnly = try #require(frames.first { $0.pts >= overlapEnd - 1e-6 })
      let inside = frames.filter { $0.pts > overlap + 1e-6 && $0.pts < overlapEnd - 1e-6 }
      #expect(inside.count >= 5, "\(inside.count) frames in the overlap")
      #expect(sixtyOnly.yavg - vfrOnly.yavg > 40, "neighbours \(vfrOnly.yavg) → \(sixtyOnly.yavg)")
      for f in inside {
        #expect(f.yavg > vfrOnly.yavg && f.yavg < sixtyOnly.yavg,
                "frame at \(f.pts) YAVG \(f.yavg) not inside (\(vfrOnly.yavg), \(sixtyOnly.yavg))")
      }
    }
  }

  // MARK: colour

  /// Guards against a second transfer conversion in the writer: flat 0x30 grey comes back at its source luma.
  @Test func darkGreyRoundTrips() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("dark.mp4", 0, 3, .cut, .fill)], in: dir)
      let source = try await FFprobe.signalstats(try await Fixtures.url("dark.mp4"), at: 1.0).yavg
      let out = try await FFprobe.signalstats(e.url, at: 1.0).yavg
      print("export: dark.mp4 YAVG source \(source), export \(out)")
      #expect(abs(out - source) <= 2, "source \(source) export \(out)")
    }
  }

  @Test func hdrKeptExportIsHEVCMain10HLG() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("hlg.mov", 0, 2, .cut, .fill)], in: dir) { $0.export.convertHDR = false }
      #expect(e.plan.hdrOut)
      let v = try await Self.videoStream(e.url)
      #expect(v["codec_name"] as? String == "hevc")
      #expect(v["profile"] as? String == "Main 10")
      #expect(v["pix_fmt"] as? String == "yuv420p10le")
      #expect(v["color_primaries"] as? String == "bt2020")
      #expect(v["color_transfer"] as? String == "arib-std-b67")
      #expect(v["color_space"] as? String == "bt2020nc")
      #expect(try await FFprobe.countedFrames(e.url) == Self.expectedFrames(e.plan))
    }
  }

  // MARK: audio absent

  @Test func noAudioReelHasNoAudioTrack() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("noaudio.mp4", 0, 2, .cut, .fill)], in: dir)
      #expect(!e.plan.hasAudioOut)
      #expect(try await Self.audioStreams(e.url).isEmpty)
      #expect(try await FFprobe.countedFrames(e.url) == Self.expectedFrames(e.plan))
    }
  }

  /// Task 20 carry: stale facts say a clip has audio, but no clip has an enabled audio track, so the build has
  /// no audio tracks and no mix. The export writes video only.
  @Test func audioOutWithNoAudioTracksWritesVideoOnly() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("noaudio.mp4", 0, 2, .cut, .fill)], in: dir) { reel in
        reel.clips[0].facts.hasAudio = true
      }
      #expect(e.plan.hasAudioOut)
      #expect(try await Self.audioStreams(e.url).isEmpty)
      #expect(try await FFprobe.countedFrames(e.url) == Self.expectedFrames(e.plan))
    }
  }

  @Test func removeAudioHasNoAudioTrack() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("portrait_hevc.mov", 0, 2, .cut, .fill)], in: dir) { reel in
        reel.export.removeAudio = true
      }
      #expect(try await Self.audioStreams(e.url).isEmpty)
    }
  }

  // MARK: software encoder

  @Test func softwareFlagIsRecorded() async throws {
    try await Self.withTempDir { dir in
      let e = try await Self.export([("dark.mp4", 0, 1, .cut, .fill)], in: dir, software: true)
      #expect(e.result.usedSoftwareEncoder)
      #expect(try await Self.videoStream(e.url)["codec_name"] as? String == "h264")
      #expect(try await FFprobe.countedFrames(e.url) == Self.expectedFrames(e.plan))
    }
  }

  // MARK: cancel and failure

  @Test func cancelMidExportLeavesNothing() async throws {
    try await Self.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make(Self.mainReel)
      let dest = dir.appending(path: "out.mp4")
      let runner = ExportRunner(resolve: Self.resolve)
      var cancelledAt: Double?
      var sawPartial = false
      do {
        for try await event in runner.start(reel: reel, dest: dest) {
          if case .progress(let p, _) = event, p > 0.1, cancelledAt == nil {
            sawPartial = try FileManager.default.contentsOfDirectory(atPath: dir.path)
              .contains { $0.hasPrefix("out.") && $0.hasSuffix(".partial.mp4") }
            cancelledAt = p
            await runner.cancel()
          }
          if case .done = event { Issue.record("export finished after cancel at \(cancelledAt ?? -1)") }
        }
        Issue.record("stream ended without an error")
      } catch is CancellationError {
      } catch {
        Issue.record("expected CancellationError, got \(error)")
      }
      #expect(cancelledAt != nil)
      #expect(sawPartial, "no partial file while writing")
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
      #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
  }

  @Test func unreadableSourceFailsCleanly() async throws {
    try await Self.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 2, .cut, .fill)])
      let corrupt = try await Fixtures.url("corrupt.mov")
      let dest = dir.appending(path: "out.mp4")
      for resolve: @Sendable (ReelClip) -> URL? in [{ _ in corrupt }, { _ in nil }] {
        let runner = ExportRunner(resolve: resolve)
        do {
          for try await _ in runner.start(reel: reel, dest: dest) {}
          Issue.record("export succeeded")
        } catch let error as ExportError {
          guard case .sourceUnreadable = error else {
            Issue.record("expected sourceUnreadable, got \(error)")
            continue
          }
          #expect(!error.sentence.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
      }
    }
  }

  @Test func runnerExportsAgainOnceTheStreamEnds() async throws {
    try await Self.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      let runner = ExportRunner(resolve: Self.resolve)
      for name in ["a.mp4", "b.mp4"] {
        for try await _ in runner.start(reel: reel, dest: dir.appending(path: name)) {}
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["a.mp4", "b.mp4"])
    }
  }

  @Test func existingDestinationIsNeverOverwritten() async throws {
    try await Self.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      let dest = dir.appending(path: "out.mp4")
      try Data("keep".utf8).write(to: dest)
      let runner = ExportRunner(resolve: Self.resolve)
      await #expect(throws: ExportError.self) {
        for try await _ in runner.start(reel: reel, dest: dest) {}
      }
      #expect(try Data(contentsOf: dest) == Data("keep".utf8))
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.mp4"])
    }
  }
}
