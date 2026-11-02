import AVFoundation
import Foundation
@testable import TrimlabMedia
import TrimlabModel

/// Reels built from the generated fixtures, with real probed `ClipFacts` and loaded assets.
enum FixtureReel {
  typealias Spec = (name: String, inS: Double, outS: Double, join: Join, framing: Framing)

  /// In/Out are snapped to each clip's frame grid (In rounded down, Out rounded down and clamped to the duration).
  static func make(_ specs: [Spec], format: ExportSpec.Format = .reel) async throws -> (Reel, [UUID: AVURLAsset]) {
    var clips: [ReelClip] = []
    var assets: [UUID: AVURLAsset] = [:]
    for spec in specs {
      let url = try await Fixtures.url(spec.name)
      let facts = try await Prober.facts(for: url)
      let fd = facts.frameDuration
      let inT = RationalTime(seconds: spec.inS, timescale: fd.timescale).floored(toFrame: fd)
      let outT = min(RationalTime(seconds: spec.outS, timescale: fd.timescale).floored(toFrame: fd), facts.duration)
      let clip = ReelClip(id: UUID(), source: try Prober.sourceRef(for: url, projectFolder: nil), facts: facts,
                          inTime: inT, outTime: outT, join: spec.join, framing: spec.framing)
      clips.append(clip)
      assets[clip.id] = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }
    return (Reel(id: UUID(), name: "fixture", clips: clips, export: ExportSpec(format: format)), assets)
  }

  /// The eight SDR/HDR fixtures the 18-clip Reel cycles through: 29.97/30/60 fps and VFR, HEVC and H.264,
  /// 4K landscape, +90° rotation and HLG.
  static let cycle = [
    "portrait_hevc.mov", "landscape.mp4", "hlg.mov", "noaudio.mp4", "vfr.mp4", "rotated.mov", "sixty.mp4",
    "keyframes.mp4",
  ]

  /// Index of the clip in `eighteen()` that is `vfr.mp4` trimmed into its 10 fps tail (source 2.0 s onward).
  static let vfrIndices = [4, 12]

  /// 18 clips, about 2 s each, cycling `cycle`; a Short crossfade into clip 5 and a Long one into clip 11;
  /// the second landscape clip (9) is Fit.
  static func eighteen() async throws -> (Reel, [UUID: AVURLAsset]) {
    let specs: [Spec] = (0..<18).map { i in
      let name = cycle[i % cycle.count]
      let join: Join = i == 5 ? .crossfade(Limits.shortFade) : i == 11 ? .crossfade(Limits.longFade) : .cut
      let framing: Framing = i == 9 ? .fit : .fill
      // vfr.mp4 runs 0.5–2.8 s so the composite covers its 10 fps tail.
      let (inS, outS) = name == "vfr.mp4" ? (0.5, 2.8) : (0.4 + Double(i % 3) * 0.1, 2.4 + Double(i % 3) * 0.1)
      return (name, inS, outS, join, framing)
    }
    return try await make(specs)
  }
}
