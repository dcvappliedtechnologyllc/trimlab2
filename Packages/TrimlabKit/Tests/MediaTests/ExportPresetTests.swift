import AVFoundation
import Foundation
import Testing
@testable import TrimlabMedia
import TrimlabModel
import VideoToolbox

/// §5.4 writer settings.
@Suite struct ExportPresetTests {
  static func facts(bitrate: Int) -> ClipFacts {
    ClipFacts(duration: RationalTime(5, 1), frameDuration: RationalTime(1001, 30000), displayWidth: 1080,
              displayHeight: 1920, rotation: 0, videoCodec: "hevc", hasAudio: true, hdr: .sdr, bitrate: bitrate,
              captureDate: nil, needsRemux: false)
  }

  static func plan(hdr: Bool = false) -> CompositionPlan {
    CompositionPlan(placements: [], segments: [], total: RationalTime(5, 1), frameDuration: RationalTime(1001, 30000),
                    renderSize: Planner.reelSize, audioRamps: [], hasAudioOut: true, hdrOut: hdr)
  }

  static func video(_ spec: ExportSpec, bitrate: Int = 20_000_000, hdr: Bool = false, software: Bool = false)
    -> (all: [String: any Sendable], compression: [String: any Sendable], colour: [String: any Sendable])
  {
    let all = ExportPresets.video(spec: spec, plan: plan(hdr: hdr), firstClip: facts(bitrate: bitrate),
                                  software: software)
    return (all, all[AVVideoCompressionPropertiesKey] as? [String: any Sendable] ?? [:],
            all[AVVideoColorPropertiesKey] as? [String: any Sendable] ?? [:])
  }

  @Test func reelHighSettings() {
    let v = Self.video(ExportSpec(format: .reel, quality: .high))
    #expect(v.compression[AVVideoAverageBitRateKey] as? Int == 14_000_000)
    #expect(v.compression[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
    #expect(v.compression[AVVideoMaxKeyFrameIntervalDurationKey] as? Double == 2)
    #expect(v.all[AVVideoCodecKey] as? AVVideoCodecType == .h264)
    #expect(v.all[AVVideoWidthKey] as? Int == 1080)
    #expect(v.all[AVVideoHeightKey] as? Int == 1920)
  }

  @Test func reelStandardIsEightMegabits() {
    let v = Self.video(ExportSpec(format: .reel, quality: .standard), bitrate: 50_000_000)
    #expect(v.compression[AVVideoAverageBitRateKey] as? Int == 8_000_000)
  }

  @Test func originalBitrateFloor() {
    let v = Self.video(ExportSpec(format: .original, quality: .standard), bitrate: 4_000_000)
    #expect(v.compression[AVVideoAverageBitRateKey] as? Int == 6_000_000)
  }

  @Test func originalScalesFirstClipBitrate() {
    #expect(Self.video(ExportSpec(format: .original, quality: .high), bitrate: 20_000_000)
      .compression[AVVideoAverageBitRateKey] as? Int == 20_000_000)
    #expect(Self.video(ExportSpec(format: .original, quality: .standard), bitrate: 20_000_000)
      .compression[AVVideoAverageBitRateKey] as? Int == 12_000_000)
  }

  @Test func dataRateLimitsAreOnePointFiveTimesOverOneSecond() {
    let v = Self.video(ExportSpec(format: .reel, quality: .high))
    let limits = v.compression[kVTCompressionPropertyKey_DataRateLimits as String] as? [Int]
    #expect(limits == [14_000_000 * 3 / 2 / 8, 1])
    let stripped = ExportPresets.withoutDataRateLimits(v.all)[AVVideoCompressionPropertiesKey] as? [String: any Sendable]
    #expect(stripped?[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
    #expect(stripped?[AVVideoAverageBitRateKey] as? Int == 14_000_000)
  }

  @Test func sdrIsTaggedBT709() {
    let c = Self.video(ExportSpec()).colour
    #expect(c[AVVideoColorPrimariesKey] as? String == AVVideoColorPrimaries_ITU_R_709_2)
    #expect(c[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_709_2)
    #expect(c[AVVideoYCbCrMatrixKey] as? String == AVVideoYCbCrMatrix_ITU_R_709_2)
  }

  @Test func hdrKeptIsHEVCMain10HLG() {
    let v = Self.video(ExportSpec(convertHDR: false), hdr: true)
    #expect(v.all[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
    #expect(v.compression[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
    #expect(v.colour[AVVideoColorPrimariesKey] as? String == AVVideoColorPrimaries_ITU_R_2020)
    #expect(v.colour[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_2100_HLG)
    #expect(v.colour[AVVideoYCbCrMatrixKey] as? String == AVVideoYCbCrMatrix_ITU_R_2020)
  }

  @Test func softwareAddsEncoderSpecification() {
    #expect(Self.video(ExportSpec()).all[AVVideoEncoderSpecificationKey] == nil)
    let spec = Self.video(ExportSpec(), software: true).all[AVVideoEncoderSpecificationKey] as? [String: any Sendable]
    #expect(spec?[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool == false)
  }

  @Test func audioIsConstantAAC48kStereo192k() {
    let a = ExportPresets.audio()
    #expect(a[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
    #expect(a[AVSampleRateKey] as? Int == 48_000)
    #expect(a[AVNumberOfChannelsKey] as? Int == 2)
    #expect(a[AVEncoderBitRateKey] as? Int == 192_000)
    #expect(a[AVEncoderBitRateStrategyKey] as? String == AVAudioBitRateStrategy_Constant)
  }

  @Test func writerAcceptsThePresets() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "trimlab2-preset-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    for hdr in [false, true] {
      for software in [false, true] {
        let v = Self.video(ExportSpec(convertHDR: !hdr), hdr: hdr, software: software).all
        let ok = writer.canApply(outputSettings: v as [String: Any], forMediaType: .video)
          || writer.canApply(outputSettings: ExportPresets.withoutDataRateLimits(v) as [String: Any],
                             forMediaType: .video)
        #expect(ok, "hdr \(hdr) software \(software)")
      }
    }
    #expect(writer.canApply(outputSettings: ExportPresets.audio() as [String: Any], forMediaType: .audio))
  }
}
