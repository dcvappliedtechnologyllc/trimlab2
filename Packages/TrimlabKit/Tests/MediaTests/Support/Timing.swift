import Foundation

/// §10 timing gates. Medians are asserted in every run: at the §10 figure when `TRIMLAB_TIMING=1`, at a looser one
/// (about 4×) otherwise, since a parallel run's load moves medians too. A single-sample max or tail (one slow sample, one
/// wall-clock throughput read) is asserted only when `TRIMLAB_TIMING=1`, because a parallel `swift test` loads the
/// machine enough to fail it at random. Acceptance runs:
/// `TRIMLAB_TIMING=1 swift test --no-parallel --filter 'PreviewEngineTests|CompositorGateTests|StripLayoutTests'`.
enum Timing {
  static let strict = ProcessInfo.processInfo.environment["TRIMLAB_TIMING"] == "1"
}
