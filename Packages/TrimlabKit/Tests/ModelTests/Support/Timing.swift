import Foundation

/// §5.3 / §10 timing gates, as in MediaTests and EditorTests: medians are asserted in every run, at the spec's figure
/// when `TRIMLAB_TIMING=1` and about 4× looser otherwise, since a parallel `swift test` loads the machine enough to
/// move them. `TRIMLAB_TIMING=1 swift test --no-parallel --filter PlannerTests`.
enum Timing {
  static let strict = ProcessInfo.processInfo.environment["TRIMLAB_TIMING"] == "1"
}
