import AVFoundation
import Foundation
import TrimlabEditor
import TrimlabModel

/// The preview engine as `EditorModel` sees it: every call recorded, nothing played. Tests drive playback by
/// calling `onTime` and `onEnd` themselves.
@MainActor final class StubPreview: PreviewDriving {
  struct Shown: Equatable {
    var plan: CompositionPlan
    var at: RationalTime
    var play: Bool
  }

  let player = AVPlayer()
  var muted = false
  var loop = true
  var onTime: (@MainActor (RationalTime) -> Void)?
  var onEnd: (@MainActor () -> Void)?

  private(set) var shown: [Shown] = []
  private(set) var seeks: [RationalTime] = []
  private(set) var rates: [Double] = []
  /// Asset ids each `show` was given.
  private(set) var assetIDs: [Set<UUID>] = []

  func show(_ plan: CompositionPlan, assets: [UUID: AVURLAsset], at t: RationalTime, play: Bool) async {
    shown.append(Shown(plan: plan, at: t, play: play))
    assetIDs.append(Set(assets.keys))
  }

  func seek(_ t: RationalTime) async -> Bool {
    seeks.append(t)
    return true
  }

  func setRate(_ r: Double) { rates.append(r) }

  /// The last rate set, 0 before any.
  var rate: Double { rates.last ?? 0 }
}
