import Foundation
import TrimlabModel

/// §5.5 step 8. The size shown in the export sheet before the export starts.
public enum ExportEstimator {
  /// Exact: `(video bitrate + audio bitrate if the output has sound) / 8 × total seconds`, with the video
  /// bitrate taken from `ExportPresets` for the Reel's spec. Quick (`cut == .quick`) with `quickBytes`: those bytes, the summed source sample
  /// sizes in range (`QuickCut.sampleBytes`). `quickBytes` is ignored for an Exact cut.
  public static func bytes(reel: Reel, quickBytes: Int64? = nil) -> Int64 {
    if reel.export.cut == .quick, let quickBytes { return quickBytes }
    guard let first = reel.clips.first else { return 0 }
    let plan = Planner.plan(reel)
    let bitsPerSecond = ExportPresets.bitrate(spec: reel.export, firstClip: first.facts)
      + (plan.hasAudioOut ? ExportPresets.audioBitrate : 0)
    return Int64((Double(bitsPerSecond) / 8 * plan.total.seconds).rounded())
  }
}
