import Foundation
@testable import TrimlabModel

/// Test support: whole-source clips and Reels. `fps:` is a frame *duration* (default 1001/30000, i.e. 29.97).
enum Builders {
  static func facts(duration: RationalTime, fps: RationalTime = RationalTime(1001, 30000),
                    size: (Int, Int) = (1080, 1920), audio: Bool = true, hdr: HDRKind = .sdr) -> ClipFacts {
    ClipFacts(duration: duration, frameDuration: fps, displayWidth: size.0, displayHeight: size.1,
              rotation: 0, videoCodec: "hvc1", hasAudio: audio, hdr: hdr, bitrate: 20_000_000,
              captureDate: nil, needsRemux: false)
  }

  /// A clip of `seconds` covering the whole source (In 0, Out = duration, cut, fill).
  static func clip(_ seconds: Double, fps: RationalTime = RationalTime(1001, 30000),
                   size: (Int, Int) = (1080, 1920), audio: Bool = true, hdr: HDRKind = .sdr) -> ReelClip {
    let source = SourceRef(relativePath: nil, absolutePath: "/tmp/clip-\(seconds).mov", size: 1,
                           modified: Date(timeIntervalSince1970: 0))
    return ReelClip.make(source: source,
                         facts: facts(duration: RationalTime(seconds: seconds), fps: fps, size: size,
                                      audio: audio, hdr: hdr),
                         framing: .fill)
  }

  static func reel(_ clipSeconds: [Double], name: String = "Test") -> Reel {
    Reel(id: UUID(), name: name, clips: clipSeconds.map { clip($0) })
  }

  /// A whole-source clip of an exact rational duration.
  static func clip(duration: RationalTime, fps: RationalTime = RationalTime(1001, 30000)) -> ReelClip {
    ReelClip.make(source: clip(1).source, facts: facts(duration: duration, fps: fps), framing: .fill)
  }

  /// Phase 2 review: three ~2 s clips at timescales 15360, 1 000 000 and 2997. Each passes the per-clip bound,
  /// but together their lcm is ≈ 4.8 × 10^10, so summing them (the plan's total) overflows Int32 and traps.
  static let timescaleMix: [ReelClip] = [
    clip(duration: RationalTime(30721, 15360)),
    clip(duration: RationalTime(2_000_001, 1_000_000)),
    clip(duration: RationalTime(5995, 2997), fps: RationalTime(1, 25)),
  ]
}
