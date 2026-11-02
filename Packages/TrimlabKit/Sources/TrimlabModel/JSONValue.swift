import Foundation

/// Any JSON value. Holds the keys a build doesn't know so they round-trip unchanged (§3.2, §8.3).
public enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
    else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value") }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

public typealias JSONObject = [String: JSONValue]

/// A coding key for any string, used to reach the keys a type doesn't know.
struct DynamicKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ string: String) { stringValue = string }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where K == DynamicKey {
  /// Every key not in `known`, decoded as JSON.
  func extra(excluding known: Set<String>) throws -> JSONObject {
    var out: JSONObject = [:]
    for key in allKeys where !known.contains(key.stringValue) {
      out[key.stringValue] = try decode(JSONValue.self, forKey: key)
    }
    return out
  }
}

extension KeyedEncodingContainer where K == DynamicKey {
  /// Writes `extra` back, skipping any key the type owns (known keys always win).
  mutating func encodeExtra(_ extra: JSONObject, excluding known: Set<String>) throws {
    for (k, v) in extra where !known.contains(k) {
      try encode(v, forKey: DynamicKey(k))
    }
  }
}
