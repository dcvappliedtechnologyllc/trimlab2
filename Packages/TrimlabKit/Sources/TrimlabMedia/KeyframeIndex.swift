import AVFoundation
import CoreMedia
import Foundation
import TrimlabModel

/// Presentation times of a clip's sync (key) samples, in track (source) time, sorted ascending.
public struct KeyframeIndex: Codable, Sendable {
  public var times: [RationalTime]

  public init(times: [RationalTime]) {
    self.times = times
  }

  /// The last sync sample at or before `t`; the first one when `t` precedes them all; `.zero` when empty.
  public func snappedIn(_ t: RationalTime) -> RationalTime {
    guard let first = times.first else { return .zero }
    var lo = 0
    var hi = times.count  // first index with time > t
    while lo < hi {
      let mid = (lo + hi) / 2
      if times[mid] <= t { lo = mid + 1 } else { hi = mid }
    }
    return lo == 0 ? first : times[lo - 1]
  }

  /// Walks the video track's samples in decode order with an `AVSampleCursor` and keeps the full-sync ones.
  /// Cancellable.
  public static func read(_ asset: AVURLAsset) async throws -> KeyframeIndex {
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw MediaCacheError.noVideoTrack
    }
    guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
      throw MediaCacheError.unreadable("no sample cursor")
    }
    // Cursor times are media time; map them to track time through the first edit.
    let segments = try await track.load(.segments)
    var offset = CMTime.zero
    if let seg = segments.first(where: { !$0.isEmpty }) {
      offset = seg.timeMapping.target.start - seg.timeMapping.source.start
    }
    var found: [RationalTime] = []
    var count = 0
    repeat {
      count += 1
      if count % 512 == 0 { try Task.checkCancellation() }
      if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
        found.append(RationalTime(cursor.presentationTimeStamp + offset))
      }
    } while cursor.stepInDecodeOrder(byCount: 1) == 1
    try Task.checkCancellation()
    return KeyframeIndex(times: Array(Set(found)).sorted())
  }
}
