import Foundation

/// §4.2, §4.3.6, §4.5 display strings. Exact integer arithmetic, a fixed "." separator (never the locale),
/// and the unit joined to its number by a no-break space (v1 ruling). Negative times display as 0.
public enum Formatting {
  static let nbsp = "\u{00A0}"

  /// A frame rate to two decimals at most, trailing zeros dropped: "29.97", "25", "59.94".
  public static func fps(_ frame: RationalTime) -> String {
    guard frame.value > 0 else { return "0" }
    let hundredths = (Double(frame.timescale) * 100 / Double(frame.value)).rounded()
    let whole = Int(hundredths) / 100, rest = Int(hundredths) % 100
    if rest == 0 { return "\(whole)" }
    return rest % 10 == 0 ? "\(whole).\(rest / 10)" : "\(whole).\(rest < 10 ? "0" : "")\(rest)"
  }

  /// §4.3.6: "Instagram Reels can be up to 3 minutes. Trim 0:12.4 more."
  public static func overLimitLine(_ excess: RationalTime) -> String {
    "Instagram Reels can be up to 3 minutes. Trim \(trimMore(excess)) more."
  }

  /// `m:ss.ff`: whole seconds, then the frame (of length `frame`) within that second, floored.
  public static func timecode(_ t: RationalTime, frame: RationalTime) -> String {
    let t = max(t, .zero)
    let whole = IntMath.floorDiv(t.value, Int64(t.timescale))
    let rest = t - RationalTime(whole, 1)
    let ff = frame.value > 0 && frame.timescale > 0
      ? IntMath.floorDiv(rest.value * Int64(frame.timescale), frame.value * Int64(rest.timescale)) : 0
    return "\(whole / 60):\(pad(whole % 60)).\(pad(ff))"
  }

  /// `12.40 s`: seconds to the nearest 0.01.
  public static func seconds(_ t: RationalTime) -> String {
    let h = units(t, per: 100, roundingUp: false)
    return "\(h / 100).\(pad(h % 100))\(nbsp)s"
  }

  /// The Reel total: `48.2 s`, or `2:14.6` once it rounds to a minute or more (nearest 0.1 s).
  public static func total(_ t: RationalTime) -> String {
    let d = units(t, per: 10, roundingUp: false)
    return d >= 600 ? minutes(tenths: d) : "\(d / 10).\(d % 10)\(nbsp)s"
  }

  /// "Trim 0:12.4 more": `m:ss.d`, rounded **up** to 0.1 s so a positive excess never reads 0:00.0.
  public static func trimMore(_ excess: RationalTime) -> String {
    minutes(tenths: units(excess, per: 10, roundingUp: true))
  }

  /// "Clip 8.5 s": seconds to the nearest 0.1.
  public static func clipLength(_ t: RationalTime) -> String {
    let d = units(t, per: 10, roundingUp: false)
    return "\(d / 10).\(d % 10)\(nbsp)s"
  }

  /// A crossfade's length (the caption's tooltip): seconds to the nearest 0.01, trailing zeros dropped —
  /// `0.6 s`, `0.25 s`, `1 s`.
  public static func fade(_ t: RationalTime) -> String {
    let h = units(t, per: 100, roundingUp: false)
    let frac = h % 100
    let tail = frac == 0 ? "" : frac % 10 == 0 ? ".\(frac / 10)" : ".\(pad(frac))"
    return "\(h / 100)\(tail)\(nbsp)s"
  }

  // MARK: private

  private static func minutes(tenths d: Int64) -> String {
    let s = d / 10
    return "\(s / 60):\(pad(s % 60)).\(d % 10)"
  }

  /// `t × per` as a whole number: nearest (halves up), or ceiling.
  private static func units(_ t: RationalTime, per: Int64, roundingUp: Bool) -> Int64 {
    let t = max(t, .zero)
    let n = t.value * per, d = Int64(t.timescale)
    return roundingUp ? IntMath.floorDiv(n + d - 1, d) : IntMath.floorDiv(2 * n + d, 2 * d)
  }

  private static func pad(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
