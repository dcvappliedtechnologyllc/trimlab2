import CoreMedia
import Foundation
import TrimlabModel

extension CMTime {
  /// Exact: value and timescale carry over (the model has already reduced them).
  public init(_ r: RationalTime) {
    self.init(value: r.value, timescale: r.timescale)
  }
}

extension RationalTime {
  /// Exact for a valid, numeric `CMTime`. An invalid, indefinite or infinite time becomes `.zero` rather than
  /// trapping; callers that care (the Prober) check `isNumeric` first.
  public init(_ t: CMTime) {
    guard t.isValid, t.isNumeric, t.timescale > 0 else {
      self = .zero
      return
    }
    self.init(t.value, t.timescale)
  }
}
