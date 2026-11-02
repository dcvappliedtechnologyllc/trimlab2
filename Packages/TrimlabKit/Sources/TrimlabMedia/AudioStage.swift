import AVFoundation
import CoreMedia

/// The v3 hook between the audio mix output and the writer input (§5.5 step 4). v2 passes buffers through.
public protocol AudioStage: Sendable {
  func process(_ buffer: CMSampleBuffer) -> CMSampleBuffer
}

public struct IdentityAudioStage: AudioStage {
  public init() {}
  public func process(_ buffer: CMSampleBuffer) -> CMSampleBuffer { buffer }
}

/// Output settings for `AVAssetReaderAudioMixOutput` (§5.5, §5.8). Asking for 48 kHz stereo here is what turns
/// mono sources into dual mono and resamples 44.1 kHz sources.
public enum MediaAudio {
  public static let readerSettings: [String: any Sendable] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48_000,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ]
}
