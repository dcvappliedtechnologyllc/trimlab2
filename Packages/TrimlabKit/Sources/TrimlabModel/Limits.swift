import Foundation

/// Fixed edit-list limits (§4.3.4, §4.3.6, §4.4, §13.4).
public enum Limits {
  /// Shortest span a trim may leave (§7.1).
  public static let minSpan = RationalTime(1, 2)
  /// Instagram's Reel length limit.
  public static let reelMax = RationalTime(180, 1)
  /// Crossfade "Short" (§13.4).
  public static let shortFade = RationalTime(1, 4)
  /// Crossfade "Long" (§13.4).
  public static let longFade = RationalTime(1, 1)
  /// A split must leave at least this much on each side.
  public static let splitEdge = RationalTime(1, 2)
}
