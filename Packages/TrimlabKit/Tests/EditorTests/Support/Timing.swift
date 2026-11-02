import Foundation

/// §10 timing gates, as in MediaTests: medians are asserted in every run (the §10 figure under `TRIMLAB_TIMING=1`,
/// about 4× looser otherwise); a single-sample max only when
/// `TRIMLAB_TIMING=1`, because a parallel `swift test` loads the machine enough to fail it at random.
/// `TRIMLAB_TIMING=1 swift test --no-parallel --filter 'StripLayoutTests|DeckLayoutTests'`.
enum Timing {
  static let strict = ProcessInfo.processInfo.environment["TRIMLAB_TIMING"] == "1"
}
