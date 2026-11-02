import AVFoundation
import Foundation
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// §5.4 export variants end to end: audio removed, HDR kept, Original sizes, software encodes, a Unicode
/// destination, silence padding and the HDR-kept thumbnail. Checked with ffprobe.
@Suite(.serialized, .exclusiveMedia) struct ExportVariantTests {
  typealias R = ExportReelTests

  /// Exports `reel` to `dest` and returns the `.done` result.
  static func export(_ reel: Reel, to dest: URL, software: Bool = false) async throws -> ExportResult {
    var result: ExportResult?
    for try await event in ExportRunner(resolve: R.resolve).start(reel: reel, dest: dest, software: software) {
      if case .done(let r) = event { result = r }
    }
    return try #require(result)
  }

  static func duration(_ stream: [String: Any]) throws -> Double {
    try #require(Double(stream["duration"] as? String ?? ""), "no duration in \(stream)")
  }

  @Test func removeAudioHasNoAudioStream() async throws {
    try await R.withTempDir { dir in
      let e = try await R.export([("portrait_hevc.mov", 0, 2, .cut, .fill), ("landscape.mp4", 0, 2, .cut, .fill)],
                                 in: dir) { $0.export.removeAudio = true }
      #expect(!e.plan.hasAudioOut)
      #expect(try await R.audioStreams(e.url).isEmpty)
      #expect(try await FFprobe.countedFrames(e.url) == R.expectedFrames(e.plan))
    }
  }

  @Test func hdrKeptIsHEVCMain10HLG() async throws {
    try await R.withTempDir { dir in
      let e = try await R.export([("portrait_hevc.mov", 0, 1, .cut, .fill), ("hlg.mov", 0, 2, .cut, .fill)],
                                 in: dir) { $0.export.convertHDR = false }
      #expect(e.plan.hdrOut)
      let v = try await R.videoStream(e.url)
      #expect(v["codec_name"] as? String == "hevc")
      #expect(v["profile"] as? String == "Main 10")
      #expect(v["color_transfer"] as? String == "arib-std-b67")
      #expect(v["pix_fmt"] as? String == "yuv420p10le")
      #expect(!e.result.usedSoftwareEncoder)
    }
  }

  @Test func originalOddDimsBecomeEven() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("odd.mp4", 0, 1, .cut, .fill)], format: .original)
      let dest = dir.appending(path: "odd.mp4")
      _ = try await Self.export(reel, to: dest)
      let v = try await R.videoStream(dest)
      #expect(v["width"] as? Int == 1078)
      #expect(v["height"] as? Int == 1916)
    }
  }

  /// The first clip (rotated.mov, 1920×1080 stored, +90°) sets the size; the 4K landscape clip is framed into it.
  @Test func originalUsesFirstClipSize() async throws {
    try await R.withTempDir { dir in
      let (reel, _) = try await FixtureReel.make([("rotated.mov", 0, 1, .cut, .fill),
                                                  ("landscape.mp4", 0, 1, .cut, .fill)], format: .original)
      let dest = dir.appending(path: "orig.mp4")
      _ = try await Self.export(reel, to: dest)
      let v = try await R.videoStream(dest)
      #expect(v["width"] as? Int == 1080)
      #expect(v["height"] as? Int == 1920)
      let plan = Planner.plan(reel)
      #expect(try await FFprobe.countedFrames(dest) == R.expectedFrames(plan))
    }
  }

  @Test func unicodeDestination() async throws {
    try await R.withTempDir { dir in
      let folder = dir.appending(path: "spaced é", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let (reel, _) = try await FixtureReel.make([("noaudio.mp4", 0, 1, .cut, .fill)])
      let dest = folder.appending(path: "Reel é 1.mp4")
      let result = try await Self.export(reel, to: dest)
      #expect(FileManager.default.fileExists(atPath: dest.path))
      #expect(result.url == dest)
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Reel é 1.mp4"])
    }
  }

  // MARK: software encoder, no injection

  @Test func softwareSDRIsH264High() async throws {
    try await R.withTempDir { dir in
      let e = try await R.export([("portrait_hevc.mov", 0, 2, .cut, .fill)], in: dir, software: true)
      let v = try await R.videoStream(e.url)
      #expect(v["codec_name"] as? String == "h264")
      #expect(v["profile"] as? String == "High")
      #expect(e.result.usedSoftwareEncoder)
      #expect(try await FFprobe.countedFrames(e.url) == R.expectedFrames(e.plan))
    }
  }

  @Test func softwareHDRKeptIsHEVCMain10() async throws {
    try await R.withTempDir { dir in
      let e = try await R.export([("hlg.mov", 0, 2, .cut, .fill)], in: dir, software: true) {
        $0.export.convertHDR = false
      }
      let v = try await R.videoStream(e.url)
      #expect(v["codec_name"] as? String == "hevc")
      #expect(v["profile"] as? String == "Main 10")
      #expect(v["pix_fmt"] as? String == "yuv420p10le")
      #expect(v["color_transfer"] as? String == "arib-std-b67")
      #expect(e.result.usedSoftwareEncoder)
      #expect(try await FFprobe.countedFrames(e.url) == R.expectedFrames(e.plan))
    }
  }

  // MARK: audio padding

  /// Task 22 carry: the last clip has no audio, so the mix ends early; the export pads silence to the total.
  @Test func audioPaddedToVideoLength() async throws {
    try await R.withTempDir { dir in
      let e = try await R.export([("portrait_hevc.mov", 0, 2, .cut, .fill), ("noaudio.mp4", 0, 2, .cut, .fill)],
                                 in: dir)
      let video = try await Self.duration(try R.videoStream(e.url))
      let audio = try await Self.duration(try #require(try R.audioStreams(e.url).first))
      print("export: padded audio \(audio) s, video \(video) s")
      #expect(abs(audio - video) <= 1024.0 / 48000, "audio \(audio) vs video \(video)")
      #expect(abs(video - e.plan.total.seconds) <= e.plan.frameDuration.seconds)
    }
  }

  // MARK: HDR-kept picture

  /// The HDR-kept thumbnail is tone-mapped to SDR, so it reads like the SDR-converted export's thumbnail.
  @Test func hdrKeptFirstFrameIsToneMapped() async throws {
    try await R.withTempDir { dir in
      let hdr = try await R.export([("hlgbright.mov", 0, 1, .cut, .fill)], in: dir) { $0.export.convertHDR = false }
      let hdrLuma = try #require(hdr.result.firstFrame.flatMap(FrameStats.limitedLuma))
      try FileManager.default.removeItem(at: hdr.url)
      let sdr = try await R.export([("hlgbright.mov", 0, 1, .cut, .fill)], in: dir)
      let sdrLuma = try #require(sdr.result.firstFrame.flatMap(FrameStats.limitedLuma))
      print("export: firstFrame luma HDR-kept \(hdrLuma), SDR-converted \(sdrLuma)")
      #expect(abs(hdrLuma - sdrLuma) / sdrLuma <= 0.10, "HDR-kept \(hdrLuma) vs SDR \(sdrLuma)")
    }
  }

  /// The baked LUTs load (a missing resource would fall back to Core Image's darker tone map without failing).
  @Test func hdrToSDRLUTsLoad() throws {
    let gpu = try #require(HDRToSDR.gpu)
    for transfer in [HDRToSDR.Transfer.hlg, .pq] {
      let lut = try #require(gpu.luts[transfer])
      #expect(lut.width == 65 && lut.height == 65 && lut.depth == 65)
    }
  }

  /// The HLG → SDR conversion matches v1's (zscale + Hable, `FFprobe.v1ToneMap`), which the owner approved: per band of
  /// the neutral HLG ramp, and on flat bright HLG grey, within 4 codes of v1's output for the same source. Core
  /// Image's own tone map was far darker on neutral tones (HLG 1/6: 39 against 53, 1/2: 82 against 123; hlgbright
  /// 174 against 212).
  @Test func hlgToSDRMatchesV1() async throws {
    try await R.withTempDir { dir in
      let ramp = try await Fixtures.url("hlgramp.mov")
      let e = try await R.export([("hlgramp.mov", 0, 1, .cut, .fill)], in: dir)
      #expect(!e.plan.hdrOut)
      let ours = Self.bands(try await FFprobe.lumaPlane(e.url, at: 0.5))
      let v1 = Self.bands(try await FFprobe.lumaPlane(ramp, at: 0.5, filter: FFprobe.v1ToneMap))
      print("export: HLG ramp → SDR Y per band (signal k/12): ours "
        + ours.map { String(format: "%.1f", $0) }.joined(separator: " ") + "; v1 "
        + v1.map { String(format: "%.1f", $0) }.joined(separator: " "))
      #expect(ours.count == 12 && v1.count == 12)
      for (k, (o, r)) in zip(ours, v1).enumerated() {
        #expect(abs(o - r) <= 4, "band \(k) (HLG \(String(format: "%.3f", Double(k) / 12))): ours \(o), v1 \(r)")
      }
      #expect(ours.count > 2 && ours[2] >= 20, "shadows crushed: HLG 0.167 gives \(ours.count > 2 ? ours[2] : -1)")
      try FileManager.default.removeItem(at: e.url)

      let bright = try await Fixtures.url("hlgbright.mov")
      let b = try await R.export([("hlgbright.mov", 0, 1, .cut, .fill)], in: dir)
      let oursBright = Self.mean(try await FFprobe.lumaPlane(b.url, at: 0.5).y)
      let v1Bright = Self.mean(try await FFprobe.lumaPlane(bright, at: 0.5, filter: FFprobe.v1ToneMap).y)
      print("export: hlgbright → SDR Y ours \(oursBright), v1 \(v1Bright)")
      #expect(abs(oursBright - v1Bright) <= 4, "hlgbright: ours \(oursBright), v1 \(v1Bright)")
    }
  }

  /// PQ sources get v1's conversion too (the same chain, baked into its own LUT). v1's Hable output for PQ runs past
  /// white (Y' 248 and 255 for the top bands), which players clip to white; the SDR output is clamped to white
  /// (Y' 235), so v1 is compared clipped there.
  @Test func pqToSDRMatchesV1() async throws {
    try await R.withTempDir { dir in
      let ramp = try await Fixtures.url("pqramp.mov")
      let e = try await R.export([("pqramp.mov", 0, 1, .cut, .fill)], in: dir)
      #expect(!e.plan.hdrOut)
      let ours = Self.bands(try await FFprobe.lumaPlane(e.url, at: 0.5))
      let v1 = Self.bands(try await FFprobe.lumaPlane(ramp, at: 0.5, filter: FFprobe.v1ToneMap))
      print("export: PQ ramp → SDR Y per band (signal k/12): ours "
        + ours.map { String(format: "%.1f", $0) }.joined(separator: " ") + "; v1 "
        + v1.map { String(format: "%.1f", $0) }.joined(separator: " "))
      #expect(ours.count == 12 && v1.count == 12)
      for (k, (o, r)) in zip(ours, v1).enumerated() {
        #expect(abs(o - min(r, 235)) <= 4, "band \(k) (PQ \(String(format: "%.3f", Double(k) / 12))): ours \(o), v1 \(r)")
      }
    }
  }

  /// Mean Y of each 90 px band of `hlgramp.mov`'s layout: the middle 60 columns, rows 400–1519.
  static func bands(_ plane: (y: [UInt8], width: Int)) -> [Double] {
    let height = plane.y.count / plane.width
    guard plane.width == 1080, height >= 1520 else { return [] }
    return (0..<12).map { k in
      var sum = 0
      for row in 400..<1520 {
        for col in (90 * k + 15)..<(90 * k + 75) { sum += Int(plane.y[row * plane.width + col]) }
      }
      return Double(sum) / Double(1120 * 60)
    }
  }

  static func mean(_ y: [UInt8]) -> Double { y.isEmpty ? 0 : Double(y.reduce(0) { $0 + Int($1) }) / Double(y.count) }

  /// Task 19 carry (measurement, reported to the controller): where an SDR clip lands inside an HDR-kept Reel.
  /// bright.mp4 is 75 % grey (Y' 0xC0, signal 0.753). In the written file it reads as HLG signal 0.656, Core
  /// Image's SDR → HLG mapping (AVFoundation's, before the flash fix, gave 0.636); BT.2408's SDR-in-HLG mapping
  /// (SDR white at HLG 0.75) would put it near 0.57. Pins today's mapping until a ruling.
  @Test func sdrClipInsideHDRKeptReel() async throws {
    try await R.withTempDir { dir in
      let e = try await R.export([("bright.mp4", 0, 2, .cut, .fill), ("hlg.mov", 0, 1, .cut, .fill)], in: dir) {
        $0.export.convertHDR = false
      }
      #expect(e.plan.hdrOut)
      let source = try await FFprobe.signalstats(try await Fixtures.url("bright.mp4"), at: 1.0).yavg
      let out = try await FFprobe.signalstats(e.url, at: 1.0).yavg
      let signal = (out - 16) / 219
      print("export: bright.mp4 Y source \(source) (\((source - 16) / 219)), in HDR-kept Reel \(out) (HLG \(signal))")
      // Cross-check the raw Y plane against ffprobe's own signalstats for the same frame.
      let tagged = try #require(try await FFprobe.frameYAVGs(e.url).first { abs($0.pts - 1.0) < 1e-3 }).yavg / 4
      #expect(abs(tagged - out) <= 1, "signalstats \(tagged) vs raw \(out)")
      #expect(abs(signal - 0.656) <= 0.02, "HLG signal \(signal)")
    }
  }

  /// No flash at the start of a colour-converted clip (HLG into an SDR Reel, SDR into an HDR-kept one): its first
  /// frame is converted like every later one. AVFoundation's own conversion left frame 0 unconverted (208 then
  /// 186; 181.75 then 155.25), so the compositor now does the conversion itself.
  @Test func convertedClipFirstFrameIsConverted() async throws {
    try await R.withTempDir { dir in
      let sdr = try await R.export([("hlgbright.mov", 0, 1, .cut, .fill)], in: dir)
      let sdrFrames = try await FFprobe.frameYAVGs(sdr.url)
      // The thumbnail is grid frame 0; measured the same way as frame 1 of the written file.
      let thumb = try #require(sdr.result.firstFrame.flatMap(FrameStats.limitedLuma))
      let frame1 = try #require(FrameStats.limitedLuma(try await Self.decodedFrame(sdr.url, at: 1.0 / 30)))
      try FileManager.default.removeItem(at: sdr.url)
      let hdr = try await R.export([("hlgbright.mov", 0, 1, .cut, .fill), ("bright.mp4", 0, 1, .cut, .fill)], in: dir) {
        $0.export.convertHDR = false
      }
      let hdrFrames = try await FFprobe.frameYAVGs(hdr.url)
      let start = try #require(hdrFrames.firstIndex { abs($0.pts - 1.0) < 1e-3 })
      print("export: first frame of converted clip: HLG in SDR \(sdrFrames[0].yavg) then \(sdrFrames[1].yavg); "
        + "SDR in HDR \(hdrFrames[start].yavg / 4) then \(hdrFrames[start + 1].yavg / 4); "
        + "SDR thumbnail \(thumb) vs frame 1 \(frame1)")
      #expect(abs(sdrFrames[0].yavg - sdrFrames[1].yavg) <= 3, "HLG in SDR: \(sdrFrames[0].yavg) then \(sdrFrames[1].yavg)")
      #expect(abs(hdrFrames[start].yavg - hdrFrames[start + 1].yavg) / 4 <= 3,
              "SDR in HDR: \(hdrFrames[start].yavg / 4) then \(hdrFrames[start + 1].yavg / 4)")
      #expect(abs(thumb - frame1) <= 3, "thumbnail \(thumb) vs frame 1 \(frame1)")
    }
  }

  /// The written file's frame at `t`, decoded to an image.
  static func decodedFrame(_ url: URL, at t: Double) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
  }
}
