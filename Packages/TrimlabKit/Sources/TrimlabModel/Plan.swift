import Foundation

/// §3.3. One clip's place on the output timeline.
public struct Placement: Hashable, Sendable {
  public var clipID: UUID
  /// `index`: the clip's position in `Reel.clips`. `track`: 0/1, alternating (A/B), so a crossfade spans both.
  public var index, track: Int
  /// `reelSpan`: output time, duration = the clip's trimmed length. `sourceIn`: the clip's In.
  public var reelSpan: TimeSpan
  /// `fadeIn` = effective crossfade into this clip; 0 for a cut or the first placement.
  public var sourceIn, fadeIn: RationalTime

  public init(clipID: UUID, index: Int, track: Int, reelSpan: TimeSpan, sourceIn: RationalTime,
              fadeIn: RationalTime) {
    self.clipID = clipID
    self.index = index
    self.track = track
    self.reelSpan = reelSpan
    self.sourceIn = sourceIn
    self.fadeIn = fadeIn
  }
}

/// One layer of a segment. `placement` indexes `CompositionPlan.placements`.
public struct LayerSpec: Hashable, Sendable {
  public var placement: Int
  public var framing: Framing
  /// Outgoing layer of an overlap only, nil otherwise. Stored as `0...1` (a `1...0` range traps) and read
  /// **upper → lower**: opacity is `upperBound` at the segment's start and `lowerBound` at its end (F2).
  public var opacity: ClosedRange<Double>?
  /// `[]` in v2.
  public var effects: [LayerEffect]

  public init(placement: Int, framing: Framing, opacity: ClosedRange<Double>? = nil, effects: [LayerEffect] = []) {
    self.placement = placement
    self.framing = framing
    self.opacity = opacity
    self.effects = effects
  }
}

/// An interval of output time and its layers, top (outgoing) first.
public struct PlanSegment: Hashable, Sendable {
  public var span: TimeSpan
  public var layers: [LayerSpec]

  public init(span: TimeSpan, layers: [LayerSpec]) {
    self.span = span
    self.layers = layers
  }
}

/// A linear volume ramp on one audio track (0/1) across `span`.
public struct AudioRamp: Hashable, Sendable {
  public var track: Int
  public var span: TimeSpan
  public var from, to: Double

  public init(track: Int, span: TimeSpan, from: Double, to: Double) {
    self.track = track
    self.span = span
    self.from = from
    self.to = to
  }
}

/// §3.3 / §5.1. What preview and export build from.
public struct CompositionPlan: Hashable, Sendable {
  public var placements: [Placement]
  /// Cover `[0, total)` with no gaps and no overlaps, sorted.
  public var segments: [PlanSegment]
  public var total, frameDuration: RationalTime
  public var renderSize: PixelSize
  public var audioRamps: [AudioRamp]
  public var hasAudioOut, hdrOut: Bool

  public init(placements: [Placement], segments: [PlanSegment], total: RationalTime, frameDuration: RationalTime,
              renderSize: PixelSize, audioRamps: [AudioRamp], hasAudioOut: Bool, hdrOut: Bool) {
    self.placements = placements
    self.segments = segments
    self.total = total
    self.frameDuration = frameDuration
    self.renderSize = renderSize
    self.audioRamps = audioRamps
    self.hasAudioOut = hasAudioOut
    self.hdrOut = hdrOut
  }
}
