import AVFoundation
import CoreMedia
import Foundation
import TrimlabModel

/// What preview and export play: the A/B composition, its `ReelCompositor` video composition and (Task 20)
/// the audio mix (nil when the plan has no audio out). AVFoundation's mutable types aren't Sendable; callers
/// don't mutate them after the build.
public struct BuiltComposition: @unchecked Sendable {
  public let composition: AVMutableComposition
  public let videoComposition: AVMutableVideoComposition
  public let audioMix: AVMutableAudioMix?
}

public enum BuildError: Error, Equatable, Sendable {
  case missingAsset(UUID), noVideoTrack(UUID), trackUnavailable
}

/// §5.3. Plan + loaded assets → A/B video composition and, when the plan has audio out, A/B audio tracks + mix.
public enum CompositionBuilder {
  public static func build(_ plan: CompositionPlan, assets: [UUID: AVURLAsset]) async throws -> BuiltComposition {
    let composition = AVMutableComposition()
    var tracks: [AVMutableCompositionTrack] = []
    for _ in 0..<2 {
      guard let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw BuildError.trackUnavailable }
      tracks.append(t)
    }

    // Audio tracks are made on first use, so a Reel with no audible clip has none. A silent clip inserts nothing
    // and leaves an empty range, which the mix reads as digital silence.
    var audioTracks: [AVMutableCompositionTrack?] = [nil, nil]
    // Per audio track: the reel-time ranges that hold audio (see `audioMix(...)`).
    var audioPlaced: [[CMTimeRange]] = [[], []]

    // Each placement's source orientation comes from its own track's preferredTransform (Task 18 ruling),
    // never from ClipFacts.rotation.
    var sources: [(transform: CGAffineTransform, size: CGSize)] = []
    sources.reserveCapacity(plan.placements.count)
    for p in plan.placements {
      guard let asset = assets[p.clipID] else { throw BuildError.missingAsset(p.clipID) }
      guard let video = try await asset.loadTracks(withMediaType: .video).first else {
        throw BuildError.noVideoTrack(p.clipID)
      }
      let (transform, size) = try await video.load(.preferredTransform, .naturalSize)
      let track = tracks[p.track]
      let start = CMTime(p.reelSpan.start)
      let end = track.timeRange.end
      let filled = end.isValid && end.isNumeric ? end : .zero
      if filled < start { track.insertEmptyTimeRange(CMTimeRange(start: filled, end: start)) }
      try track.insertTimeRange(CMTimeRange(start: CMTime(p.sourceIn), duration: CMTime(p.reelSpan.duration)),
                                of: video, at: start)
      sources.append((transform, size))

      if plan.hasAudioOut, let audio = try await firstEnabledAudioTrack(of: asset) {
        let range = try await audio.load(.timeRange)
        // The audio can end before the video; take what exists.
        let want = CMTimeRange(start: CMTime(p.sourceIn), duration: CMTime(p.reelSpan.duration))
        let take = want.intersection(range)
        if take.duration > .zero {
          let t: AVMutableCompositionTrack
          if let existing = audioTracks[p.track] {
            t = existing
          } else {
            guard let made = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw BuildError.trackUnavailable }
            audioTracks[p.track] = made
            t = made
          }
          let tEnd = t.timeRange.end
          let tFilled = tEnd.isValid && tEnd.isNumeric ? tEnd : .zero
          if tFilled < start { t.insertEmptyTimeRange(CMTimeRange(start: tFilled, end: start)) }
          let at = start + (take.start - want.start)
          try t.insertTimeRange(take, of: audio, at: at)
          audioPlaced[p.track].append(CMTimeRange(start: at, duration: take.duration))
        }
      }
    }

    let instructions = plan.segments.map { segment in
      ReelInstruction(
        segment: segment,
        timeRange: CMTimeRange(start: CMTime(segment.span.start), duration: CMTime(segment.span.duration)),
        layers: segment.layers.map { spec in
          let p = plan.placements[spec.placement]
          let source = sources[spec.placement]
          return (tracks[p.track].trackID, spec, source.transform, source.size)
        },
        hdrOut: plan.hdrOut)
    }

    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = plan.hdrOut ? ReelCompositorHDR.self : ReelCompositorSDR.self
    vc.renderSize = CGSize(width: plan.renderSize.width, height: plan.renderSize.height)
    vc.frameDuration = CMTime(plan.frameDuration)
    vc.instructions = instructions
    // The composition's colour space, which the compositor's output matches. Sources are not converted to it by
    // AVFoundation (`ReelCompositor.canConformColorOfSourceFrames`): AVFoundation's conversion left each converted
    // clip's first frame unconverted, a one-frame flash. The compositor converts in Core Image instead.
    if plan.hdrOut {
      vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
      vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
      vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
    } else {
      vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
      vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
      vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }

    #if DEBUG
    if !plan.segments.isEmpty {
      let valid = vc.isValid(for: composition.tracks, assetDuration: composition.duration,
                             timeRange: CMTimeRange(start: .zero, duration: CMTime(plan.total)),
                             validationDelegate: nil)
      assert(valid, "video composition is invalid for plan total \(plan.total.seconds) s")
    }
    #endif

    return BuiltComposition(composition: composition, videoComposition: vc,
                            audioMix: audioMix(plan, tracks: audioTracks, placed: audioPlaced))
  }

  // MARK: audio

  /// §5.8: the first enabled audio track of the source.
  private static func firstEnabledAudioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack? {
    for track in try await asset.loadTracks(withMediaType: .audio) where try await track.load(.isEnabled) {
      return track
    }
    return nil
  }

  /// `plan.audioRamps` as per-track volume parameters, built only from ramps.
  ///
  /// An audio mix holds a track at its last ramp's end value, so after a crossfade out (1 -> 0) a later cut clip
  /// on the same track would play silent: every stretch of audio that is not inside a crossfade ramp gets an
  /// explicit 1 -> 1 hold. Every empty range or gap gets a 0 -> 0 hold, which keeps a 44.1 kHz source's
  /// sample-rate-converter burst out of the silence. (Ramps, not `setVolume(_:at:)` points: AVFoundation
  /// interpolates from a point to the next entry, so a point followed by a later ramp fades in between.)
  private static func audioMix(_ plan: CompositionPlan, tracks: [AVMutableCompositionTrack?],
                               placed: [[CMTimeRange]]) -> AVMutableAudioMix? {
    guard plan.hasAudioOut else { return nil }
    var parameters: [AVMutableAudioMixInputParameters] = []
    for (index, track) in tracks.enumerated() {
      guard let track else { continue }
      let fades = plan.audioRamps.filter { $0.track == index }.map {
        (range: CMTimeRange(start: CMTime($0.span.start), duration: CMTime($0.span.duration)),
         from: Float($0.from), to: Float($0.to))
      }.sorted { $0.range.start < $1.range.start }
      let p = AVMutableAudioMixInputParameters(track: track)
      func hold(_ from: CMTime, _ to: CMTime, _ volume: Float) {
        if from < to { p.setVolumeRamp(fromStartVolume: volume, toEndVolume: volume, timeRange: CMTimeRange(start: from, end: to)) }
      }
      var cursor = CMTime.zero
      for span in placed[index] {
        hold(cursor, span.start, 0)
        var at = span.start
        for fade in fades {
          // The audio may start later or end earlier than the plan's span: clamp the fade to what is placed,
          // keeping its slope, so entries tile exactly against the holds.
          let r = fade.range.intersection(span)
          guard r.isValid, r.duration > .zero else { continue }
          let total = fade.range.duration.seconds
          func volume(_ t: CMTime) -> Float {
            fade.from + (fade.to - fade.from) * Float((t - fade.range.start).seconds / total)
          }
          hold(at, r.start, 1)
          p.setVolumeRamp(fromStartVolume: volume(r.start), toEndVolume: volume(r.end), timeRange: r)
          at = max(at, r.end)
        }
        hold(at, span.end, 1)
        cursor = span.end
      }
      parameters.append(p)
    }
    guard !parameters.isEmpty else { return nil }
    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters
    return mix
  }
}
