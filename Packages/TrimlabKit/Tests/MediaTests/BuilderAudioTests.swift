import AVFoundation
import Foundation
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// §5.3 / §5.8 audio: A/B audio tracks, silence, crossfade ramps, channel handling, the `AudioStage` hook.
@Suite struct BuilderAudioTests {
  static let rate = 48_000.0
  /// 44.1 -> 48 kHz conversion band-limits the hard edges of a clip: ~0.4 ms of ring-out after it ends and
  /// ~1.2 ms of pre-ring before the next starts (peak ~0.1). Silence is asserted exactly zero outside this guard.
  static let edgeGuard = 0.0015

  /// Interleaved stereo Float32 read through the mix, placed on a zero-filled 48 kHz timeline by PTS.
  struct Rendered: Sendable {
    var left: [Float], right: [Float]
    var channels: Int, sampleRate: Double
    /// Gap (s) between each buffer's PTS and the end of the previous one; positive = a hole, negative = overlap.
    var discontinuities: [Double]
    func slice(_ from: Double, _ to: Double) -> ArraySlice<Float> {
      // Whole samples inside the window: a sample straddling the start belongs to the previous clip.
      let a = max(0, Int((from * rate).rounded(.up))), b = min(left.count, Int(to * rate))
      return left[a..<max(a, b)]
    }
  }

  /// The reader loop blocks in `copyNextSampleBuffer`, so it runs on its own thread, not a pool thread.
  static func render(_ built: BuiltComposition, seconds: Double) async throws -> Rendered {
    let box = UncheckedBox(built)
    return try await OffPool.run { try renderBlocking(box.value, seconds: seconds) }
  }

  private static func renderBlocking(_ built: BuiltComposition, seconds: Double) throws -> Rendered {
    let reader = try AVAssetReader(asset: built.composition)
    let audioTracks = built.composition.tracks(withMediaType: .audio)
    guard !audioTracks.isEmpty else { throw Fixtures.Failure(description: "composition has no audio tracks") }
    let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: MediaAudio.readerSettings)
    output.audioMix = built.audioMix
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? Fixtures.Failure(description: "startReading failed") }
    let n = Int(seconds * rate)
    var l = [Float](repeating: 0, count: n), r = l
    var gaps: [Double] = []
    var prevEnd: Double?
    var channels = 0
    var sr = 0.0
    while let sb = output.copyNextSampleBuffer() {
      if let fmt = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
        channels = Int(asbd.pointee.mChannelsPerFrame)
        sr = asbd.pointee.mSampleRate
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
      let frames = CMSampleBufferGetNumSamples(sb)
      if let e = prevEnd { gaps.append(pts - e) }
      prevEnd = pts + Double(frames) / rate
      var block: CMBlockBuffer?
      var abl = AudioBufferList()
      var size = 0
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sb, bufferListSizeNeededOut: &size, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
      guard let data = abl.mBuffers.mData else { continue }
      let p = data.assumingMemoryBound(to: Float.self)
      let start = Int((pts * rate).rounded())
      for i in 0..<frames where start + i >= 0 && start + i < n {
        l[start + i] = p[i * channels]
        r[start + i] = p[i * channels + (channels > 1 ? 1 : 0)]
      }
    }
    if reader.status == .failed { throw reader.error ?? Fixtures.Failure(description: "read failed") }
    return Rendered(left: l, right: r, channels: channels, sampleRate: sr, discontinuities: gaps)
  }

  static func rms(_ s: ArraySlice<Float>) -> Double {
    guard !s.isEmpty else { return 0 }
    return (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
  }

  /// Goertzel power at `freq`, normalised by the window length so windows of any size compare.
  static func goertzel(_ s: ArraySlice<Float>, _ freq: Double) -> Double {
    let w = 2 * Double.pi * freq / rate, c = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for x in s {
      let s0 = Double(x) + c * s1 - s2
      s2 = s1
      s1 = s0
    }
    let n = Double(s.count)
    return (s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n)
  }

  static func build(_ specs: [FixtureReel.Spec]) async throws -> (CompositionPlan, BuiltComposition) {
    let (reel, assets) = try await FixtureReel.make(specs)
    let plan = Planner.plan(reel)
    return (plan, try await CompositionBuilder.build(plan, assets: assets))
  }

  // MARK: tests

  @Test func silenceAcrossNoAudioClip() async throws {
    let (plan, built) = try await Self.build([
      ("tone660.mov", 0, 1, .cut, .fill), ("noaudio.mp4", 0, 1, .cut, .fill), ("tone660.mov", 1, 2, .cut, .fill),
    ])
    #expect(plan.hasAudioOut)
    let out = try await Self.render(built, seconds: plan.total.seconds)
    // 48 kHz sources: a 44.1 kHz source's converter can leak a sub-millisecond burst into the next gap.
    // The silent span is the NoAudio clip's placement.
    let silent = plan.placements[1].reelSpan
    let gap = out.slice(silent.start.seconds, silent.end.seconds)
    #expect(gap.count > 46_000)
    #expect(gap.allSatisfy { $0 == 0 }, "noaudio span is not digital silence")
    #expect(Self.rms(out.slice(0.1, silent.start.seconds - 0.1)) > 0.05)
    #expect(Self.rms(out.slice(silent.end.seconds + 0.1, plan.total.seconds - 0.1)) > 0.05)
    #expect(out.discontinuities.allSatisfy { abs($0) <= 0.001 }, "PTS discontinuities \(out.discontinuities.filter { abs($0) > 0.001 })")
  }

  /// 44.1 kHz sources: the sample-rate converter used to leak a sub-millisecond burst into the empty range, and
  /// it was nondeterministic, so read ten times. Exact zeros between the edge guards.
  @Test func silenceAcrossNoAudioClip44k() async throws {
    let (plan, built) = try await Self.build([
      ("portrait_hevc.mov", 0, 1, .cut, .fill), ("noaudio.mp4", 0, 1, .cut, .fill), ("portrait_hevc.mov", 1, 2, .cut, .fill),
    ])
    let silent = plan.placements[1].reelSpan
    var peaks: [Float] = []
    for _ in 0..<10 {
      let out = try await Self.render(built, seconds: plan.total.seconds)
      let gap = out.slice(silent.start.seconds + Self.edgeGuard, silent.end.seconds - Self.edgeGuard)
      peaks.append(gap.map { abs($0) }.max() ?? 0)
      #expect(out.discontinuities.allSatisfy { abs($0) <= 0.001 })
    }
    print("peak in noaudio span over 10 reads (44.1 kHz): \(peaks)")
    #expect(peaks.allSatisfy { $0 == 0 }, "non-zero samples in the gap, peaks \(peaks)")
  }

  @Test func noAudioClipAfterCrossfadeStaysSilent() async throws {
    // clip1 -> crossfade -> clip2 -> noaudio -> clip4: the noaudio span, after a crossfade, must stay silent.
    let (plan, built) = try await Self.build([
      ("portrait_hevc.mov", 0, 2, .cut, .fill), ("portrait_hevc.mov", 0, 2, .crossfade(Limits.longFade), .fill),
      ("noaudio.mp4", 0, 1, .cut, .fill), ("portrait_hevc.mov", 0, 1, .cut, .fill),
    ])
    let silent = plan.placements[2].reelSpan
    var peaks: [Float] = []
    for _ in 0..<10 {
      let out = try await Self.render(built, seconds: plan.total.seconds)
      peaks.append(out.slice(silent.start.seconds + Self.edgeGuard, silent.end.seconds - Self.edgeGuard)
        .map { abs($0) }.max() ?? 0)
    }
    print("peak in idle-track span over 10 reads: \(peaks)")
    #expect(peaks.allSatisfy { $0 == 0 }, "peaks \(peaks)")
  }

  struct Entry {
    var range: CMTimeRange
    var from: Float, to: Float
    var text: String { "\(range.start.seconds)-\(range.end.seconds) \(from)>\(to)" }
  }

  /// Walks a track's volume entries from 0: each must start where the previous one ended.
  static func contiguousEntries(_ built: BuiltComposition, total: Double) throws -> [[Entry]] {
    let mix = try #require(built.audioMix)
    return mix.inputParameters.map { param in
      var entries: [Entry] = []
      var t = CMTime.zero
      while t.seconds < total {
        var a: Float = 0, b: Float = 0
        var r = CMTimeRange.zero
        guard param.getVolumeRamp(for: t, startVolume: &a, endVolume: &b, timeRange: &r), r.duration > .zero else { break }
        entries.append(Entry(range: r, from: a, to: b))
        t = r.end
      }
      return entries
    }
  }

  /// Entries are contiguous, and (so none was dropped for overlapping another) the last one reaches the end of
  /// the audio on its track.
  static func expectTiled(_ tracks: [[Entry]], _ built: BuiltComposition, sourceLocation: SourceLocation = #_sourceLocation) {
    let audio = built.composition.tracks(withMediaType: .audio)
    for (entries, track) in zip(tracks, audio) {
      #expect((entries.last?.range.end.seconds ?? 0) >= track.timeRange.end.seconds - 0.001,
              "entries end at \(entries.last?.range.end.seconds ?? 0), audio ends at \(track.timeRange.end.seconds)",
              sourceLocation: sourceLocation)
      for (prev, next) in zip(entries, entries.dropFirst()) {
        #expect(next.range.start == prev.range.end, "entry \(next.text) after \(prev.text)",
                sourceLocation: sourceLocation)
      }
    }
  }

  /// The source's audio ends 0.5 s before its video; the outgoing fade must not run into the next hold.
  @Test func fadeOutOfShortAudioIsClamped() async throws {
    let (plan, built) = try await Self.build([
      ("shortaudio.mp4", 0, 3, .cut, .fill), ("tone660.mov", 0, 2, .crossfade(Limits.longFade), .fill),
      ("tone660.mov", 0, 1, .cut, .fill),
    ])
    let tracks = try Self.contiguousEntries(built, total: plan.total.seconds)
    Self.expectTiled(tracks, built)
    // The clamped fade keeps its slope: 1 -> 0 over 1 s, cut off 0.5 s in, ends at 0.5.
    let all: [Entry] = tracks.flatMap { $0 }
    let fade = all.first { (e: Entry) -> Bool in e.from == 1 && e.to < 1 && e.to > 0 }
    #expect(fade != nil, "no partial fade entry")
  }

  /// The source's audio starts 0.5 s after its video. AVFoundation reports that as leading silence inside an
  /// audio track that starts at 0, so there is no late placed range to clamp to: the fade stays whole and
  /// the entries must still tile. (The incoming-side clamp itself is not reachable with a fixture.)
  @Test func fadeIntoLateStartingAudioTiles() async throws {
    let (plan, built) = try await Self.build([
      ("tone660.mov", 0, 2, .cut, .fill), ("lateaudio.mp4", 0, 2.5, .crossfade(Limits.longFade), .fill),
    ])
    let tracks = try Self.contiguousEntries(built, total: plan.total.seconds)
    Self.expectTiled(tracks, built)
    let all: [Entry] = tracks.flatMap { $0 }
    #expect(all.contains { (e: Entry) -> Bool in e.from == 0 && e.to == 1 })
  }

  @Test func crossfadeRampsAudio() async throws {
    // 440 Hz out (portrait_hevc), 660 Hz in (tone660), 1 s crossfade starting at 1.5 s.
    let (plan, built) = try await Self.build([
      ("portrait_hevc.mov", 0, 2.5, .cut, .fill), ("tone660.mov", 0, 2.5, .crossfade(Limits.longFade), .fill),
    ])
    let p1 = plan.placements[1]
    let t0 = p1.reelSpan.start.seconds, fade = p1.fadeIn.seconds
    #expect(abs(fade - 1) < 1e-9)
    let out = try await Self.render(built, seconds: plan.total.seconds)

    // Energy of each tone in tenths of the overlap: 440 falls, 660 rises.
    func energies(_ k: Int) -> (e440: Double, e660: Double) {
      let a = t0 + fade * Double(k) / 10, b = a + fade / 10
      return (Self.goertzel(out.slice(a, b), 440), Self.goertzel(out.slice(a, b), 660))
    }
    let first = energies(0), q1 = energies(2), mid = energies(5), last = energies(9)
    #expect(first.e440 > first.e660 * 20, "start of overlap should be almost all 440")
    #expect(last.e660 > last.e440 * 20, "end of overlap should be almost all 660")
    #expect(q1.e440 > q1.e660, "25 % in: outgoing 440 must still dominate (inverted ramp?)")
    #expect(mid.e440 < first.e440 && mid.e660 > first.e660)
    #expect(last.e440 < mid.e440 && last.e660 > mid.e660)
    // Linear ramp: at 25 % amplitude is 0.75 / 0.25, so the 440 : 660 power ratio is about 9.
    let ratio = q1.e440 / q1.e660
    #expect(ratio > 4 && ratio < 20, "ratio \(ratio)")

    // The ramps are in the mix parameters.
    let mix = try #require(built.audioMix)
    #expect(mix.inputParameters.count == 2)
    let audio = built.composition.tracks(withMediaType: .audio)
    #expect(audio.count == 2)
    for ramp in plan.audioRamps {
      let param = try #require(mix.inputParameters.first { $0.trackID == audio[ramp.track].trackID })
      var start: Float = -1, end: Float = -1
      var range = CMTimeRange.zero
      let found = param.getVolumeRamp(for: CMTime(ramp.span.start), startVolume: &start, endVolume: &end, timeRange: &range)
      #expect(found)
      #expect(Double(start) == ramp.from && Double(end) == ramp.to, "\(ramp.track): \(start)→\(end)")
      #expect(abs(range.start.seconds - ramp.span.start.seconds) < 1e-6)
      #expect(abs(range.duration.seconds - ramp.span.duration.seconds) < 1e-6)
    }
  }

  /// A fade-out leaves the track's volume at 0; a later cut clip on that track must be set back to 1.
  @Test func cutAfterCrossfadeIsAudible() async throws {
    let (plan, built) = try await Self.build([
      ("portrait_hevc.mov", 0, 2, .cut, .fill), ("tone660.mov", 0, 2, .crossfade(Limits.longFade), .fill),
      ("portrait_hevc.mov", 0, 2, .cut, .fill),
    ])
    // Clip 3 lands on clip 1's track, which faded out.
    #expect(plan.placements[2].track == plan.placements[0].track)
    let out = try await Self.render(built, seconds: plan.total.seconds)
    let s = plan.placements[2].reelSpan
    let got = Self.rms(out.slice(s.start.seconds + 0.2, s.start.seconds + 1.8))

    let (solo, soloBuilt) = try await Self.build([("portrait_hevc.mov", 0, 2, .cut, .fill)])
    let ref = Self.rms(try await Self.render(soloBuilt, seconds: solo.total.seconds).slice(0.2, 1.8))
    #expect(ref > 0.05)
    #expect(abs(got - ref) / ref < 0.1, "clip 3 rms \(got), standalone \(ref)")
  }

  @Test func monoBecomesStereo48k() async throws {
    let (plan, built) = try await Self.build([("mono44k.mov", 0, 2, .cut, .fill)])
    let out = try await Self.render(built, seconds: plan.total.seconds)
    #expect(out.channels == 2)
    #expect(out.sampleRate == 48_000)
    #expect(out.left == out.right)
    #expect(Self.rms(out.slice(0.2, 1.8)) > 0.05)
    // Resampled, not stretched: still 440 Hz.
    let w = out.slice(0.5, 1.5)
    #expect(Self.goertzel(w, 440) > Self.goertzel(w, 400) * 50)
  }

  @Test func removeAudioMeansNoAudioMix() async throws {
    var (reel, assets) = try await FixtureReel.make([("portrait_hevc.mov", 0, 2, .cut, .fill)])
    reel.export.removeAudio = true
    let plan = Planner.plan(reel)
    #expect(!plan.hasAudioOut)
    let built = try await CompositionBuilder.build(plan, assets: assets)
    #expect(built.audioMix == nil)
    #expect(built.composition.tracks(withMediaType: .audio).isEmpty)
  }

  @Test func identityStageIsIdentity() throws {
    var fmt: CMAudioFormatDescription?
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
      mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: nil, dataBuffer: try Self.block(bytes: 8 * 16), formatDescription: try #require(fmt), sampleCount: 16,
      presentationTimeStamp: CMTime(value: 480, timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sb)
    let input = try #require(sb)
    let stage: any AudioStage = IdentityAudioStage()
    let output = stage.process(input)
    #expect(output === input)
  }

  static func block(bytes: Int) throws -> CMBlockBuffer {
    var b: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &b)
    return try #require(b)
  }
}
