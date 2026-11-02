import AVFoundation
import Foundation
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// §5.7 Quick cut and the §5.5 size estimate. Outputs are checked with ffprobe.
@Suite(.serialized, .exclusiveMedia) struct QuickCutTests {
  typealias R = ExportReelTests

  /// A one-clip Original Reel over `name`, In/Out in seconds.
  static func reel(_ name: String, _ inS: Double, _ outS: Double,
                   edit: (inout Reel) -> Void = { _ in }) async throws -> (reel: Reel, clip: ReelClip, url: URL) {
    var (reel, _) = try await FixtureReel.make([(name, inS, outS, .cut, .fill)], format: .original)
    edit(&reel)
    return (reel, reel.clips[0], try await Fixtures.url(name))
  }

  static func snapped(_ clip: ReelClip, _ url: URL) async throws -> RationalTime {
    let asset = AVURLAsset(url: url)
    let index = try await KeyframeIndex.read(asset)
    return QuickCut.snappedIn(for: asset, clip: clip, index: index)
  }

  @discardableResult
  static func run(_ clip: ReelClip, _ url: URL, dest: URL, removeAudio: Bool = false,
                  snappedIn: RationalTime) async throws -> ExportResult {
    var result: ExportResult?
    for try await event in QuickCut().start(clip: clip, url: url, dest: dest, removeAudio: removeAudio,
                                            snappedIn: snappedIn) {
      if case .done(let r) = event { result = r }
    }
    return try #require(result)
  }

  static func video(_ url: URL) async throws -> [String: Any] {
    try #require(try await FFprobe.streams(url).first { ($0["codec_type"] as? String) == "video" })
  }

  @Test func quickRules() async throws {
    let (one, _, _) = try await Self.reel("keyframes.mp4", 0, 2)
    #expect(QuickCut.isAllowed(one) == .allowed)

    var two = one
    two.clips.append(one.clips[0])
    #expect(QuickCut.isAllowed(two) == .needsSingleOriginal)

    var reelFormat = one
    reelFormat.export.format = .reel
    #expect(QuickCut.isAllowed(reelFormat) == .needsSingleOriginal)

    let (hlg, _, _) = try await Self.reel("hlg.mov", 0, 1) { $0.export.convertHDR = true }
    #expect(hlg.clips[0].facts.hdr == .hlg)
    #expect(QuickCut.isAllowed(hlg) == .cantConvertHDR)
    var hlgKept = hlg
    hlgKept.export.convertHDR = false
    #expect(QuickCut.isAllowed(hlgKept) == .allowed)
  }

  @Test func quickStartsAtReportedKeyframe() async throws {
    let (_, clip, url) = try await Self.reel("keyframes.mp4", 3.4, 5.0)
    let snapped = try await Self.snapped(clip, url)
    #expect(snapped.seconds == 3.0)
    try await R.withTempDir { dir in
      let result = try await Self.run(clip, url, dest: dir.appending(path: "cut.mp4"), snappedIn: snapped)
      let frames = try await FFprobe.frames(result.url)
      let first = try #require(frames.map(\.ptsTime).min())
      let frame = clip.facts.frameDuration.seconds
      let durationText = try await #require(FFprobe.format(result.url)["duration"] as? String)
      let duration = try #require(Double(durationText))
      let expected = clip.outTime.seconds - 3.0
      print("quick: first pts \(first) s, duration \(duration) s, expected \(expected) s, frame \(frame) s")
      #expect(abs(first) <= frame)
      #expect(abs(duration - expected) <= frame)
      #expect(try await FFprobe.frames(result.url).first?.keyFrame == true)
    }
  }

  @Test func quickIsStreamCopy() async throws {
    let (_, clip, url) = try await Self.reel("keyframes.mp4", 3.4, 5.0)
    let snapped = try await Self.snapped(clip, url)
    try await R.withTempDir { dir in
      let result = try await Self.run(clip, url, dest: dir.appending(path: "cut.mp4"), snappedIn: snapped)
      let source = try await Self.video(url)
      let out = try await Self.video(result.url)
      #expect(out["codec_name"] as? String == source["codec_name"] as? String)
      #expect(out["profile"] as? String == source["profile"] as? String)
      #expect(out["width"] as? Int == source["width"] as? Int)
      let expected = try await FFprobe.frames(url).filter {
        $0.ptsTime >= snapped.seconds - 0.001 && $0.ptsTime < clip.outTime.seconds - 0.001
      }.count
      let got = try await FFprobe.frames(result.url).count
      #expect(got == expected, "output packets \(got), source packets in range \(expected)")
      #expect(result.url.lastPathComponent == "cut.mp4")
    }
  }

  @Test func quickRemoveAudio() async throws {
    let (_, clip, url) = try await Self.reel("portrait_hevc.mov", 0, 2)
    #expect(clip.facts.hasAudio)
    try await R.withTempDir { dir in
      let snapped = try await Self.snapped(clip, url)
      let kept = try await Self.run(clip, url, dest: dir.appending(path: "kept.mp4"), snappedIn: snapped)
      #expect(try await R.audioStreams(kept.url).count == 1)
      let silent = try await Self.run(clip, url, dest: dir.appending(path: "silent.mp4"), removeAudio: true,
                                      snappedIn: snapped)
      #expect(try await R.audioStreams(silent.url).isEmpty)
    }
  }

  @Test func quickHEVCKeepsHvc1Tag() async throws {
    let (_, clip, url) = try await Self.reel("portrait_hevc.mov", 0, 2)
    let snapped = try await Self.snapped(clip, url)
    try await R.withTempDir { dir in
      let result = try await Self.run(clip, url, dest: dir.appending(path: "hevc.mp4"), snappedIn: snapped)
      let v = try await Self.video(result.url)
      #expect(v["codec_name"] as? String == "hevc")
      #expect(v["codec_tag_string"] as? String == "hvc1")
    }
  }

  @Test func quickKeepsRotation() async throws {
    let (_, clip, url) = try await Self.reel("rotated.mov", 0, 2)
    #expect(clip.facts.rotation == 90 || clip.facts.rotation == 270)
    let snapped = try await Self.snapped(clip, url)
    try await R.withTempDir { dir in
      let result = try await Self.run(clip, url, dest: dir.appending(path: "rot.mp4"), snappedIn: snapped)
      let track = try #require(try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video).first)
      let t = try await track.load(.preferredTransform)
      let angle = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
      let source = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
      let st = try await source.load(.preferredTransform)
      let sourceAngle = Int((atan2(st.b, st.a) * 180 / .pi).rounded())
      #expect(abs(angle) == 90, "output rotation \(angle)")
      #expect(angle == sourceAngle)
      let side = (try await Self.video(result.url)["side_data_list"] as? [[String: Any]]) ?? []
      let rotation = side.compactMap { $0["rotation"] as? Int }.first
      #expect(rotation.map { abs($0) } == 90, "ffprobe rotation \(String(describing: rotation))")
    }
  }

  @Test func quickRefusesExistingDestination() async throws {
    let (_, clip, url) = try await Self.reel("keyframes.mp4", 0, 2)
    try await R.withTempDir { dir in
      let dest = dir.appending(path: "taken.mp4")
      try Data("mine".utf8).write(to: dest)
      await #expect(throws: ExportError.other("taken.mp4 already exists.")) {
        try await Self.run(clip, url, dest: dest, snappedIn: .zero)
      }
      #expect(try String(contentsOf: dest, encoding: .utf8) == "mine")
      #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["taken.mp4"])
    }
  }

  @Test func quickMissingSourceIsUnreadable() async throws {
    let (_, clip, _) = try await Self.reel("keyframes.mp4", 0, 2)
    try await R.withTempDir { dir in
      await #expect(throws: ExportError.sourceUnreadable(URL(filePath: clip.source.absolutePath).lastPathComponent)) {
        try await Self.run(clip, dir.appending(path: "gone.mp4"), dest: dir.appending(path: "o.mp4"), snappedIn: .zero)
      }
      let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      #expect(left.isEmpty, "left behind: \(left)")
    }
  }

  @Test func quickCancelLeavesNoPartial() async throws {
    let (_, clip, url) = try await Self.reel("keyframes.mp4", 0, 5)
    try await R.withTempDir { dir in
      let dest = dir.appending(path: "cancelled.mp4")
      let cut = QuickCut()
      let stream = cut.start(clip: clip, url: url, dest: dest, removeAudio: false, snappedIn: .zero)
      await cut.cancel()
      // The awaitable cancel (Quit): once it returns the partial is gone, before anyone reads the stream.
      let early = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      #expect(early.isEmpty, "cancel returned before tidying up: \(early)")
      await #expect(throws: CancellationError.self) {
        for try await _ in stream {}
      }
      let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      #expect(left.isEmpty, "left behind: \(left)")
    }
  }


  @Test func quickCutWithAudioKeepsBothStreams() async throws {
    for name in ["lateaudio.mp4", "portrait_hevc.mov"] {
      let (_, clip, url) = try await Self.reel(name, 0.4, 2.0)
      let snapped = try await Self.snapped(clip, url)
      try await R.withTempDir { dir in
        let result = try await Self.run(clip, url, dest: dir.appending(path: "a.mp4"), snappedIn: snapped)
        #expect(try await R.audioStreams(result.url).count == 1, "\(name) audio stream")
        let source = try await Self.video(url)
        let out = try await Self.video(result.url)
        #expect(out["codec_name"] as? String == source["codec_name"] as? String)
        let text = try await #require(FFprobe.format(result.url)["duration"] as? String)
        let duration = try #require(Double(text))
        let expected = clip.outTime.seconds - snapped.seconds
        print("quick audio \(name): duration \(duration) s, expected \(expected) s")
        // Passthrough keeps whole AAC packets, so audio that runs past Out can stretch the container by up to
        // one packet (1024/48000 s = 21.3 ms). The video stream itself must end within 1 ms.
        let videoText = try #require(out["duration"] as? String)
        let videoDuration = try #require(Double(videoText))
        #expect(abs(videoDuration - expected) <= 0.001, "\(name) video: \(videoDuration) vs \(expected)")
        let tolerance = name == "portrait_hevc.mov" ? 0.001 : 1024.0 / 48000
        #expect(abs(duration - expected) <= tolerance, "\(name): \(duration) vs \(expected)")
      }
    }
  }

  @Test func quickCancelMidExportLeavesNothing() async throws {
    let (_, clip, url) = try await Self.reel("over3.mp4", 0, 181)
    try await R.withTempDir { dir in
      let dest = dir.appending(path: "long.mp4")
      let cut = QuickCut()
      var sawProgress = false
      await #expect(throws: CancellationError.self) {
        for try await event in cut.start(clip: clip, url: url, dest: dest, removeAudio: false, snappedIn: .zero) {
          if case .progress = event {
            sawProgress = true
            await cut.cancel()
          }
        }
      }
      #expect(sawProgress, "export finished before a progress event")
      let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      #expect(left.isEmpty, "left behind: \(left)")
      #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
  }

  @Test func quickProResUsesMov() throws {
    var facts = try #require(Optional(ClipFacts(
      duration: RationalTime(600, 600), frameDuration: RationalTime(1, 30), displayWidth: 1920, displayHeight: 1080,
      rotation: 0, videoCodec: "prores", hasAudio: true, hdr: .sdr, bitrate: 100_000_000, captureDate: nil,
      needsRemux: false)))
    let ref = SourceRef(relativePath: nil, absolutePath: "/x/p.mov", size: 1, modified: Date(timeIntervalSince1970: 0))
    var clip = ReelClip.make(source: ref, facts: facts, framing: .fill)
    let dest = URL(filePath: "/out/name.mp4")
    #expect(QuickCut.fileType(for: clip) == .mov)
    #expect(QuickCut.destination(for: clip, dest: dest).lastPathComponent == "name.mov")
    facts.videoCodec = "h264"
    clip.facts = facts
    #expect(QuickCut.fileType(for: clip) == .mp4)
    #expect(QuickCut.destination(for: clip, dest: URL(filePath: "/out/name.mov")).lastPathComponent == "name.mp4")
  }

  @Test func sampleBytesMatchesRangeAndGrowsWithIt() async throws {
    let url = try await Fixtures.url("keyframes.mp4")
    let asset = AVURLAsset(url: url)
    let all = await QuickCut.sampleBytes(asset: asset, range: RationalTime(0, 600)..<RationalTime(10 * 600, 600))
    let tail = await QuickCut.sampleBytes(asset: asset, range: RationalTime(3 * 600, 600)..<RationalTime(10 * 600, 600))
    let sizeText = try await #require(FFprobe.format(url)["size"] as? String)
    let size = try #require(Int64(sizeText))
    #expect(all > 0 && tail > 0 && tail < all)
    #expect(Double(all) > Double(size) * 0.9 && all <= size, "samples \(all) of file \(size)")
  }

  // MARK: estimate

  static func syntheticReel(seconds: Double, hasAudio: Bool, quality: ExportSpec.Quality = .high,
                            format: ExportSpec.Format = .reel) -> Reel {
    let facts = ClipFacts(
      duration: RationalTime(seconds: seconds, timescale: 600), frameDuration: RationalTime(1, 30),
      displayWidth: 1080, displayHeight: 1920, rotation: 0, videoCodec: "h264", hasAudio: hasAudio, hdr: .sdr,
      bitrate: 20_000_000, captureDate: nil, needsRemux: false)
    let ref = SourceRef(relativePath: nil, absolutePath: "/x/a.mp4", size: 1, modified: Date(timeIntervalSince1970: 0))
    return Reel(id: UUID(), name: "r", clips: [ReelClip.make(source: ref, facts: facts, framing: .fill)],
                export: ExportSpec(format: format, quality: quality))
  }

  @Test func estimateReelHigh() {
    let reel = Self.syntheticReel(seconds: 48.2, hasAudio: true)
    let expected = Double(14_000_000 + 192_000) / 8 * 48.2
    let got = Double(ExportEstimator.bytes(reel: reel))
    #expect(abs(got - expected) / expected < 0.01)
    #expect(abs(got - 85.5e6) / 85.5e6 < 0.01)
  }

  @Test func estimateFollowsPresetsAndAudio() {
    var silent = Self.syntheticReel(seconds: 10, hasAudio: true, quality: .standard)
    silent.export.removeAudio = true
    #expect(ExportEstimator.bytes(reel: silent) == Int64(ExportPresets.reelStandardBitrate / 8 * 10))
    let original = Self.syntheticReel(seconds: 10, hasAudio: false, quality: .standard, format: .original)
    #expect(ExportEstimator.bytes(reel: original) == Int64(ExportPresets.originalMinBitrate.max(12_000_000) / 8 * 10))
    #expect(ExportEstimator.bytes(reel: .empty(name: "e")) == 0)
  }

  @Test func estimateQuickUsesSampleBytesOnlyForQuick() {
    var reel = Self.syntheticReel(seconds: 10, hasAudio: true, format: .original)
    reel.export.cut = .quick
    #expect(ExportEstimator.bytes(reel: reel, quickBytes: 1234) == 1234)
    // Quick without a measurement falls back to the bitrate formula.
    #expect(ExportEstimator.bytes(reel: reel, quickBytes: nil) > 1234)
    // Stale quickBytes are ignored once the cut is Exact again.
    reel.export.cut = .exact
    #expect(ExportEstimator.bytes(reel: reel, quickBytes: 1234) == ExportEstimator.bytes(reel: reel))
    #expect(ExportEstimator.bytes(reel: reel, quickBytes: 1234) != 1234)
  }

  /// Original takes a fraction of the clip's own bitrate (0.6 Standard, 1.0 High), never below 6 Mb/s.
  static func originalBytes(clipBitrate: Int, quality: ExportSpec.Quality, audio: Bool = false) -> Int64 {
    var reel = syntheticReel(seconds: 10, hasAudio: audio, quality: quality, format: .original)
    reel.clips[0].facts.bitrate = clipBitrate
    return ExportEstimator.bytes(reel: reel)
  }

  @Test func estimateOriginalFactors() {
    #expect(Self.originalBytes(clipBitrate: 40_000_000, quality: .standard) == 40_000_000 * 6 / 10 / 8 * 10)
    #expect(Self.originalBytes(clipBitrate: 40_000_000, quality: .high) == 40_000_000 / 8 * 10)
    #expect(Self.originalBytes(clipBitrate: 40_000_000, quality: .high, audio: true) == (40_000_000 + 192_000) / 8 * 10)
  }

  @Test func estimateOriginalFloorsAtSixMegabits() {
    // 4 Mb/s × 0.6 = 2.4 and 4 × 1.0 = 4: both below the floor.
    #expect(Self.originalBytes(clipBitrate: 4_000_000, quality: .standard) == 6_000_000 / 8 * 10)
    #expect(Self.originalBytes(clipBitrate: 4_000_000, quality: .high) == 6_000_000 / 8 * 10)
    // 8 Mb/s × 0.6 = 4.8 is floored; × 1.0 = 8 is not.
    #expect(Self.originalBytes(clipBitrate: 8_000_000, quality: .standard) == 6_000_000 / 8 * 10)
    #expect(Self.originalBytes(clipBitrate: 8_000_000, quality: .high) == 8_000_000 / 8 * 10)
  }
}

private extension Int {
  func max(_ other: Int) -> Int { Swift.max(self, other) }
}
