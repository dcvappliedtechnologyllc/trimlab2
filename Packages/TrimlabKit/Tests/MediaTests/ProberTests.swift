import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import TrimlabMedia
@testable import TrimlabModel

@Suite(.serialized) struct ProberTests {
  static let probeable = [
    "portrait_hevc.mov", "rotated.mov", "landscape.mp4", "hlg.mov", "noaudio.mp4", "vfr.mp4", "odd.mp4",
    "over3.mp4", "spaced é/clip é 1.mov", "sixty.mp4", "mono44k.mov", "keyframes.mp4", "tiny.mp4",
  ]

  private static func facts(_ name: String) async throws -> ClipFacts {
    try await Prober.facts(for: Fixtures.url(name))
  }

  @Test func portraitHEVC() async throws {
    let f = try await Self.facts("portrait_hevc.mov")
    #expect(f.displayWidth == 1080 && f.displayHeight == 1920)
    #expect(f.frameDuration == RationalTime(1001, 30000))
    #expect(f.videoCodec == "hevc")
    #expect(f.hasAudio)
    #expect(f.hdr == .sdr)
    #expect(!f.needsRemux)
    #expect(f.bitrate > 0)
  }

  @Test func rotatedReportsDisplayDims() async throws {
    let f = try await Self.facts("rotated.mov")
    #expect(f.displayWidth == 1080 && f.displayHeight == 1920)
    #expect(f.rotation == 90)
  }

  @Test func hlgDetected() async throws {
    #expect(try await Self.facts("hlg.mov").hdr == .hlg)
  }

  @Test func noAudio() async throws {
    #expect(try await Self.facts("noaudio.mp4").hasAudio == false)
  }

  @Test func vfrNominalIsSane() async throws {
    let f = try await Self.facts("vfr.mp4")
    #expect(f.frameDuration == RationalTime(1, 30))
  }

  @Test func sixtyFps() async throws {
    #expect(try await Self.facts("sixty.mp4").frameDuration == RationalTime(1, 60))
  }

  @Test func unicodePath() async throws {
    let f = try await Self.facts("spaced é/clip é 1.mov")
    #expect(abs(f.duration.seconds - 3) < 0.1)
  }

  @Test func mkvNeedsRemux() async throws {
    let mkv = try await Fixtures.url("sample.mkv")
    await #expect(throws: ProbeError.unplayable) { try await Prober.facts(for: mkv) }
  }

  @Test func truncatedMovThrowsUnplayable() async throws {
    let url = try await Fixtures.url("corrupt.mov")
    let start = ContinuousClock.now
    await #expect(throws: ProbeError.unplayable) { try await Prober.facts(for: url) }
    #expect(ContinuousClock.now - start < .seconds(1))
  }

  @Test func textFileUnsupported() async throws {
    let url = try await Fixtures.url("notes.txt")
    await #expect(throws: ProbeError.unsupportedType) { try await Prober.facts(for: url) }
  }

  @Test func probeIsFast() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    _ = try await Prober.facts(for: url)  // warm-up: framework load is not a per-clip cost
    var times: [Duration] = []
    for _ in 0..<5 {
      let t0 = ContinuousClock.now
      _ = try await Prober.facts(for: url)
      times.append(ContinuousClock.now - t0)
    }
    let median = times.sorted()[2]
    // §10's 30 ms under TRIMLAB_TIMING=1; 4× looser in a parallel run.
    #expect(median < .milliseconds(Timing.strict ? 30 : 120), "median probe \(median)")
  }

  @Test func ffmpegSearchOrder() {
    let ok: Set<String> = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    #expect(FFmpegLocation.find(isExecutable: { ok.contains($0) })?.ffmpeg.path == "/opt/homebrew/bin/ffmpeg")
    #expect(FFmpegLocation.find(isExecutable: { _ in false }) == nil)
    let all: Set<String> = ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    #expect(FFmpegLocation.find(isExecutable: { all.contains($0) })?.ffmpeg.path
            == "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
  }

  @Test func cmTimeBridgeExact() {
    let r = RationalTime(1001, 30000)
    let t = CMTime(r)
    #expect(t.value == 1001 && t.timescale == 30000)
    #expect(RationalTime(t) == r)
    let back = RationalTime(t)
    #expect(back.value == 1001 && back.timescale == 30000)
  }

  // MARK: ruling additions

  @Test func nonNumericCMTimesDoNotTrap() {
    #expect(RationalTime(.invalid) == .zero)
    #expect(RationalTime(.indefinite) == .zero)
    #expect(RationalTime(.positiveInfinity) == .zero)
    #expect(Prober.floored(.indefinite, onto: RationalTime(1, 30)) == nil)
    #expect(Prober.snappedFrameDuration(minFrame: .invalid, nominalRate: .nan, name: "x") == RationalTime(1, 30))
  }

  @Test func frameDurationSnapsToNominalSet() {
    func snap(_ fps: Double) -> RationalTime {
      Prober.snappedFrameDuration(minFrame: CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000),
                                  nominalRate: 0, name: "x")
    }
    #expect(snap(29.97) == RationalTime(1001, 30000))
    #expect(snap(59.94) == RationalTime(1001, 60000))
    #expect(snap(23.976) == RationalTime(1001, 24000))
    #expect(snap(25) == RationalTime(1, 25))
    #expect(snap(7) == RationalTime(1, 30))  // not nominal: fallback
  }

  @Test func highFrameRatesSnapToTheirOwnDuration() {
    func snap(_ fps: Double) -> RationalTime {
      Prober.snappedFrameDuration(minFrame: CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000),
                                  nominalRate: 0, name: "x")
    }
    #expect(snap(100) == RationalTime(1, 100))
    #expect(snap(119.88) == RationalTime(1001, 120000))
    #expect(snap(120) == RationalTime(1, 120))
    #expect(snap(239.76) == RationalTime(1001, 240000))
    #expect(snap(240) == RationalTime(1, 240))
  }

  @Test func highFpsFactsAreSane() throws {
    func clip(_ fd: RationalTime) throws -> ReelClip {
      let facts = ClipFacts(duration: RationalTime(3003, 240000) * 100, frameDuration: fd, displayWidth: 1080,
                            displayHeight: 1920, rotation: 0, videoCodec: "hevc", hasAudio: true, hdr: .sdr,
                            bitrate: 1, captureDate: nil, needsRemux: false)
      let ref = SourceRef(relativePath: nil, absolutePath: "/x.mov", size: 1, modified: Date(timeIntervalSince1970: 0))
      return .make(source: ref, facts: facts, framing: .fill)
    }
    let slow = try clip(RationalTime(1001, 240000))
    #expect(TimeBounds.isSane(slow))
    #expect(TimeBounds.reelIsSane([slow, try clip(RationalTime(1, 30))]))
    #expect(TimeBounds.reelIsSane([slow, try clip(RationalTime(1001, 30000))]))
  }

  @Test func nominalRateBranchWhenMinFrameDurationUnusable() {
    #expect(Prober.snappedFrameDuration(minFrame: .invalid, nominalRate: 29.97, name: "x") == RationalTime(1001, 30000))
    #expect(Prober.snappedFrameDuration(minFrame: .zero, nominalRate: 25, name: "x") == RationalTime(1, 25))
  }

  @Test func codecAliases() {
    #expect(Prober.codecName(0x68657631) == "hevc")  // hev1
    #expect(Prober.codecName(0x68766331) == "hevc")  // hvc1
    #expect(Prober.codecName(0x61766333) == "h264")  // avc3
    #expect(Prober.codecName(0x61766331) == "h264")  // avc1
  }

  @Test func mirroredTransformIsNotRotated180() {
    let mirror = CGAffineTransform(scaleX: -1, y: 1)
    #expect(Prober.rotation(of: mirror) == 0)
    #expect(Prober.rotation(of: mirror.rotated(by: .pi / 2)) == 90)
    #expect(Prober.rotation(of: CGAffineTransform(scaleX: 1, y: -1)) == 180)  // vertical flip = mirror + 180
  }

  @Test func fallbackIsLogged() {
    let (_, lines) = MediaLog.capturing {
      _ = Prober.snappedFrameDuration(minFrame: .invalid, nominalRate: 0, name: "odd.mp4")
    }
    #expect(lines.contains { $0.contains("odd.mp4") })
  }

  /// M1: captures are per task, so suites running in parallel never see each other's lines.
  @Test func logCapturesAreIsolated() async {
    async let a = MediaLog.capturing { () async -> Void in
      for i in 0..<50 { MediaLog.note("capture-a \(i)"); await Task.yield() }
    }
    async let b = MediaLog.capturing { () async -> Void in
      for i in 0..<50 { MediaLog.note("capture-b \(i)"); await Task.yield() }
    }
    let (la, lb) = await (a.1, b.1)
    #expect(la.count == 50 && la.allSatisfy { $0.hasPrefix("capture-a") })
    #expect(lb.count == 50 && lb.allSatisfy { $0.hasPrefix("capture-b") })
    let outside = MediaLog.capturing { () -> Void in }
    #expect(outside.1.isEmpty)
  }

  @Test func durationFloorsOntoFrameTimescale() {
    // 3.0001 s on a 1/30 timescale floors to 90/30, never above the asset.
    let d = Prober.floored(CMTime(value: 30001, timescale: 10000), onto: RationalTime(1, 30))
    #expect(d == RationalTime(90, 30))
    #expect(Prober.floored(CMTime(value: 1, timescale: 1000), onto: RationalTime(1, 30)) == RationalTime(0, 30))
  }

  @Test func rotationSnapsToQuarterTurns() {
    #expect(Prober.rotation(of: .identity) == 0)
    #expect(Prober.rotation(of: CGAffineTransform(rotationAngle: .pi / 2)) == 270)
    #expect(Prober.rotation(of: CGAffineTransform(rotationAngle: .pi)) == 180)
    #expect(Prober.rotation(of: CGAffineTransform(rotationAngle: -.pi / 2)) == 90)
  }

  @Test func sourceRefRelativeInsideProject() async throws {
    let url = try await Fixtures.url("spaced é/clip é 1.mov")
    let inside = try Prober.sourceRef(for: url, projectFolder: Fixtures.dir)
    #expect(inside.relativePath == "spaced é/clip é 1.mov")
    #expect(inside.size > 0)
    #expect(inside.absolutePath == url.path)
    let outside = try Prober.sourceRef(for: url, projectFolder: Fixtures.dir.appending(path: "spaced"))
    #expect(outside.relativePath == nil)
    #expect(try Prober.sourceRef(for: url, projectFolder: nil).relativePath == nil)
  }

  @Test func importItemCarriesFileCreationDate() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let item = await Prober.importItem(for: url)
    #expect(item.url == url)
    #expect(item.fileCreated != nil)
  }

  @Test(arguments: probeable) func everyFixtureIsSane(_ name: String) async throws {
    let url = try await Fixtures.url(name)
    let f = try await Prober.facts(for: url)
    let clip = ReelClip.make(source: try Prober.sourceRef(for: url, projectFolder: nil), facts: f, framing: .fill)
    #expect(TimeBounds.isSane(clip), "\(name)")
  }

  @Test func reelOfEveryFixtureIsSane() async throws {
    var clips: [ReelClip] = []
    for name in Self.probeable {
      let url = try await Fixtures.url(name)
      clips.append(.make(source: try Prober.sourceRef(for: url, projectFolder: nil),
                         facts: try await Prober.facts(for: url), framing: .fill))
    }
    #expect(TimeBounds.reelIsSane(clips))
  }
}
