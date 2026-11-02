import Foundation

/// §8.3: each step turns a schema-*n* project object into schema *n + 1*, filling defaults for the fields that
/// schema added. `ProjectCodec.decode` runs them in order from the file's schema up to `Reel.currentSchema`.
public enum Migrations {
  public typealias Step = @Sendable (JSONObject) -> JSONObject

  /// Keyed by the schema the step upgrades FROM. Empty in v2: schema 1 is the first.
  public static let steps: [Int: Step] = [:]
}
