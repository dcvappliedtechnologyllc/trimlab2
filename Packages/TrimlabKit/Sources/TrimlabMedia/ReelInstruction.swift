import AVFoundation
import CoreMedia
import Foundation
import TrimlabModel

/// §5.2. One per `PlanSegment`: the segment's layers (top first), each with its composition track, the source
/// track's `preferredTransform` and stored size, and the render settings. Immutable after init.
public final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
  public struct Layer: Sendable {
    public let trackID: CMPersistentTrackID
    public let spec: LayerSpec
    /// The source track's `preferredTransform` (top-left origin, as AVFoundation stores it).
    public let transform: CGAffineTransform
    /// The source track's stored (`naturalSize`) dimensions, before the transform.
    public let sourceSize: CGSize
  }

  public let segment: PlanSegment
  public let timeRange: CMTimeRange
  /// Top (outgoing) first, as in `PlanSegment.layers`. The compositor draws them bottom-up.
  public let layers: [Layer]
  public let hdrOut: Bool

  public let enablePostProcessing = false
  public let containsTweening = true
  public let requiredSourceTrackIDs: [NSValue]?
  public let passthroughTrackID = kCMPersistentTrackID_Invalid

  public init(segment: PlanSegment, timeRange: CMTimeRange,
              layers: [(trackID: CMPersistentTrackID, spec: LayerSpec, transform: CGAffineTransform,
                        sourceSize: CGSize)],
              hdrOut: Bool) {
    self.segment = segment
    self.timeRange = timeRange
    self.layers = layers.map {
      Layer(trackID: $0.trackID, spec: $0.spec, transform: $0.transform, sourceSize: $0.sourceSize)
    }
    self.hdrOut = hdrOut
    var ids: [CMPersistentTrackID] = []
    for layer in layers where !ids.contains(layer.trackID) { ids.append(layer.trackID) }
    requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
    super.init()
  }

  /// The layer's opacity at `time`: 1 without a ramp; with one, `upperBound` at the segment's start falling
  /// linearly to `lowerBound` at its end (F2).
  public func opacity(of layer: Layer, at time: CMTime) -> Double {
    guard let ramp = layer.spec.opacity else { return 1 }
    let duration = timeRange.duration.seconds
    guard duration > 0 else { return ramp.upperBound }
    let progress = min(max((time - timeRange.start).seconds / duration, 0), 1)
    return ramp.upperBound + (ramp.lowerBound - ramp.upperBound) * progress
  }
}
