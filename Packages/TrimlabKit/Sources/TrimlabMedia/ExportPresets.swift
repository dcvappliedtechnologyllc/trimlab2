import AVFoundation
import Foundation
import TrimlabModel
import VideoToolbox

/// §5.4. Writer output settings for an export. Pure: the same spec, plan and first clip give the same settings.
public enum ExportPresets {
  /// Reel bitrates (bits/s).
  public static let reelStandardBitrate = 8_000_000
  public static let reelHighBitrate = 14_000_000
  /// Original: fraction of the first clip's bitrate, never below `originalMinBitrate`.
  public static let originalStandardFactor = 0.6
  public static let originalHighFactor = 1.0
  public static let originalMinBitrate = 6_000_000
  /// `DataRateLimits` ceiling: this many times the average bitrate, over `dataRateWindow` seconds.
  public static let dataRateCeiling = 1.5
  public static let dataRateWindow = 1
  public static let keyFrameInterval = 2.0
  public static let audioBitrate = 192_000
  public static let audioSampleRate = 48_000

  /// Average video bitrate for the spec (§5.4 Bitrate row).
  public static func bitrate(spec: ExportSpec, firstClip: ClipFacts) -> Int {
    switch spec.format {
    case .reel:
      return spec.quality == .high ? reelHighBitrate : reelStandardBitrate
    case .original:
      let factor = spec.quality == .high ? originalHighFactor : originalStandardFactor
      return max(Int((Double(firstClip.bitrate) * factor).rounded()), originalMinBitrate)
    }
  }

  /// Video settings: H.264 High with BT.709 tags for SDR out, HEVC Main10 with BT.2020 / HLG tags when HDR is
  /// kept. Includes `kVTCompressionPropertyKey_DataRateLimits`; the runner drops it with `withoutDataRateLimits`
  /// when the writer can't apply it. `software` asks VideoToolbox for its software encoder.
  public static func video(spec: ExportSpec, plan: CompositionPlan, firstClip: ClipFacts,
                           software: Bool) -> [String: any Sendable] {
    let rate = bitrate(spec: spec, firstClip: firstClip)
    let fps = Double(plan.frameDuration.timescale) / Double(max(plan.frameDuration.value, 1))
    let compression: [String: any Sendable] = [
      AVVideoAverageBitRateKey: rate,
      AVVideoProfileLevelKey: plan.hdrOut
        ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
      AVVideoMaxKeyFrameIntervalDurationKey: keyFrameInterval,
      AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
      kVTCompressionPropertyKey_DataRateLimits as String: [
        Int((Double(rate) * dataRateCeiling / 8).rounded()), dataRateWindow,
      ],
    ]
    let colour: [String: any Sendable] = plan.hdrOut
      ? [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
      : [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    var settings: [String: any Sendable] = [
      AVVideoCodecKey: plan.hdrOut ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
      AVVideoWidthKey: plan.renderSize.width,
      AVVideoHeightKey: plan.renderSize.height,
      AVVideoColorPropertiesKey: colour,
      AVVideoCompressionPropertiesKey: compression,
    ]
    if software {
      settings[AVVideoEncoderSpecificationKey] = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
      ] as [String: any Sendable]
    }
    return settings
  }

  /// `settings` with `DataRateLimits` removed from the compression properties.
  public static func withoutDataRateLimits(_ settings: [String: any Sendable]) -> [String: any Sendable] {
    var out = settings
    if var compression = settings[AVVideoCompressionPropertiesKey] as? [String: any Sendable] {
      compression[kVTCompressionPropertyKey_DataRateLimits as String] = nil
      out[AVVideoCompressionPropertiesKey] = compression
    }
    return out
  }

  /// AAC-LC 48 kHz stereo 192 kb/s, constant bitrate.
  public static func audio() -> [String: any Sendable] {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: audioSampleRate,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: audioBitrate,
      AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
      AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
    ]
  }
}
