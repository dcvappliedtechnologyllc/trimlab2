import Foundation

/// One file of a dropped batch, with the dates that order it.
public struct ImportItem: Hashable, Sendable {
  public var url: URL
  /// QuickTime `creationDate`.
  public var captureDate: Date?
  public var fileCreated: Date?

  public init(url: URL, captureDate: Date?, fileCreated: Date?) {
    self.url = url
    self.captureDate = captureDate
    self.fileCreated = fileCreated
  }
}

/// §4.1, §13.2: the order a dropped batch joins the Reel, so it follows the shoot.
public enum ImportOrder {
  /// By date (capture date, else file creation date: one key per item, F30), then natural file name
  /// (`IMG_2` before `IMG_10`). Items with no date come after the dated ones, by name. Ties keep drop order.
  public static func sorted(_ items: [ImportItem]) -> [ImportItem] {
    items.enumerated().sorted { a, b in
      let da = a.element.captureDate ?? a.element.fileCreated
      let db = b.element.captureDate ?? b.element.fileCreated
      switch (da, db) {
      case let (x?, y?) where x != y: return x < y
      case (.some, nil): return true
      case (nil, .some): return false
      default:
        switch a.element.url.lastPathComponent.localizedStandardCompare(b.element.url.lastPathComponent) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.offset < b.offset
        }
      }
    }.map(\.element)
  }
}
