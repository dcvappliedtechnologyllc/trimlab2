import Foundation

/// Exact rational time (gcd-normalised + − min max, frame snapping); no floats in the edit list.
/// JSON: `[value, timescale]`. Converted to CMTime only in TrimlabMedia.
///
/// Every value built through `init(_:_:)` or decoded from JSON is normalised (gcd-reduced, timescale > 0).
/// Equality, hashing and ordering compare the exact rational value, so a hand-set non-normalised pair
/// still compares correctly. Arithmetic overflow traps (Swift's checked integer operators).
public struct RationalTime: Codable, Hashable, Comparable, Sendable {
  public var value: Int64
  public var timescale: Int32

  public static let zero = RationalTime(0, 1)

  public init(_ value: Int64, _ timescale: Int32) {
    precondition(timescale != 0, "RationalTime timescale must not be 0")
    let (v, ts) = Self.normalise(value, Int64(timescale))
    self.value = v
    self.timescale = Int32(ts)  // traps if the reduced timescale doesn't fit
  }

  /// Import and display rounding only: never use this for edit-list arithmetic.
  public init(seconds: Double, timescale: Int32 = 600) {
    self.init(Int64((seconds * Double(timescale)).rounded()), timescale)
  }

  /// Display only.
  public var seconds: Double { Double(value) / Double(timescale) }

  // MARK: arithmetic

  public static func + (a: RationalTime, b: RationalTime) -> RationalTime {
    let (ts, ma, mb) = commonScale(a, b)
    return RationalTime(wide: a.value * ma + b.value * mb, ts)
  }

  public static func - (a: RationalTime, b: RationalTime) -> RationalTime {
    let (ts, ma, mb) = commonScale(a, b)
    return RationalTime(wide: a.value * ma - b.value * mb, ts)
  }

  public static func * (a: RationalTime, n: Int64) -> RationalTime {
    RationalTime(wide: a.value * n, Int64(a.timescale))
  }

  /// Half of this time, exact.
  public func halved() -> RationalTime {
    value % 2 == 0 ? RationalTime(wide: value / 2, Int64(timescale)) : RationalTime(wide: value, Int64(timescale) * 2)
  }

  /// The start of the frame (of length `fd`, frames starting at 0) that contains this time.
  public func floored(toFrame fd: RationalTime) -> RationalTime {
    let (num, den) = frameRatio(fd)
    return fd * IntMath.floorDiv(num, den)
  }

  /// The nearest frame start (frames of length `fd`); a time exactly halfway goes to the later frame.
  public func rounded(toFrame fd: RationalTime) -> RationalTime {
    let (num, den) = frameRatio(fd)
    return fd * IntMath.floorDiv(2 * num + den, 2 * den)
  }

  // MARK: comparison

  public static func == (a: RationalTime, b: RationalTime) -> Bool { compare(a, b) == 0 }

  public static func < (a: RationalTime, b: RationalTime) -> Bool { compare(a, b) < 0 }

  public func hash(into hasher: inout Hasher) {
    let (v, ts) = Self.normalise(value, Int64(timescale))
    hasher.combine(v)
    hasher.combine(ts)
  }

  // MARK: Codable — [value, timescale]

  public init(from decoder: any Decoder) throws {
    var c = try decoder.unkeyedContainer()
    let v = try c.decode(Int64.self)
    let ts = try c.decode(Int32.self)
    guard c.isAtEnd else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "RationalTime is exactly [value, timescale]")
    }
    guard ts > 0 else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "RationalTime timescale must be > 0")
    }
    self.init(v, ts)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.unkeyedContainer()
    try c.encode(value)
    try c.encode(timescale)
  }

  // MARK: private

  /// Builds from an Int64 timescale (e.g. an lcm), reducing before narrowing to Int32.
  private init(wide value: Int64, _ timescale: Int64) {
    let (v, ts) = Self.normalise(value, timescale)
    self.value = v
    self.timescale = Int32(ts)
  }

  private static func normalise(_ value: Int64, _ timescale: Int64) -> (Int64, Int64) {
    if value == 0 { return (0, 1) }
    let g = IntMath.gcd(value, timescale)
    let sign: Int64 = timescale < 0 ? -1 : 1
    return (sign * (value / g), sign * (timescale / g))
  }

  /// lcm of the two timescales and the multipliers that bring each value onto it.
  private static func commonScale(_ a: RationalTime, _ b: RationalTime) -> (Int64, Int64, Int64) {
    let ta = Int64(a.timescale), tb = Int64(b.timescale)
    let lcm = ta / IntMath.gcd(ta, tb) * tb
    return (lcm, lcm / ta, lcm / tb)
  }

  /// self / fd as num / den with den > 0.
  private func frameRatio(_ fd: RationalTime) -> (Int64, Int64) {
    precondition(fd.value > 0 && fd.timescale > 0, "frame duration must be positive")
    var num = value * Int64(fd.timescale)
    var den = fd.value * Int64(timescale)
    if den < 0 { num = -num; den = -den }
    return (num, den)
  }

  /// Sign of a − b, exact via 128-bit cross products.
  private static func compare(_ a: RationalTime, _ b: RationalTime) -> Int {
    let l = a.value.multipliedFullWidth(by: Int64(b.timescale))
    let r = b.value.multipliedFullWidth(by: Int64(a.timescale))
    // Timescales of normalised values are > 0; a hand-set negative one flips the inequality.
    let flip = (a.timescale < 0) != (b.timescale < 0)
    let s: Int = l.high != r.high ? (l.high < r.high ? -1 : 1) : (l.low == r.low ? 0 : (l.low < r.low ? -1 : 1))
    return flip ? -s : s
  }
}

/// The one copy of the integer helpers the model's exact arithmetic shares.
enum IntMath {
  /// Greatest common divisor of the magnitudes; gcd(0, 0) is 0.
  static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
    var (a, b) = (a.magnitude, b.magnitude)
    while b != 0 { (a, b) = (b, a % b) }
    return Int64(a)
  }

  /// Division rounding toward negative infinity.
  static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }
}
