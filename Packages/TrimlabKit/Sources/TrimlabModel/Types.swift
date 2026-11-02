import Foundation

// §3.2 core data types. All are values, Sendable, and free of any media framework.

public struct TimeSpan: Codable, Hashable, Sendable {
  public var start, duration: RationalTime
  public init(start: RationalTime, duration: RationalTime) {
    self.start = start
    self.duration = duration
  }
  public var end: RationalTime { start + duration }
}

public struct PixelSize: Codable, Hashable, Sendable {
  public var width, height: Int
  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

/// fit = whole frame over a blurred copy.
public enum Framing: String, Codable, Hashable, Sendable { case fill, fit }

/// The join INTO a clip; ignored on the first clip. v2 writes `Limits.shortFade` (Short) or `Limits.longFade` (Long).
/// JSON: `{"cut":{}}` or `{"crossfade":[value,timescale]}` (hand-written, pre-flight F1).
public enum Join: Codable, Hashable, Sendable {
  case cut
  case crossfade(RationalTime)

  private enum Key: String, CodingKey { case cut, crossfade }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    guard c.allKeys.count == 1, let key = c.allKeys.first else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                              debugDescription: "Join needs exactly one of \"cut\" or \"crossfade\""))
    }
    switch key {
    case .cut:
      _ = try c.nestedContainer(keyedBy: DynamicKey.self, forKey: .cut)  // must be an object
      self = .cut
    case .crossfade:
      self = .crossfade(try c.decode(RationalTime.self, forKey: .crossfade))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    switch self {
    case .cut: _ = c.nestedContainer(keyedBy: DynamicKey.self, forKey: .cut)
    case .crossfade(let t): try c.encode(t, forKey: .crossfade)
    }
  }
}

public enum HDRKind: String, Codable, Hashable, Sendable { case sdr, hlg, pq }

/// No cases in v2; v5 adds `.look(id)`. Coding is hand-written because Swift won't synthesize it for an empty enum (F4).
public enum LayerEffect: Codable, Hashable, Sendable {
  public init(from decoder: any Decoder) throws {
    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                            debugDescription: "no layer effects exist in this schema"))
  }
  public func encode(to encoder: any Encoder) throws { switch self {} }
}

public struct SourceRef: Codable, Hashable, Sendable {
  /// Relative to the .trimlab folder, tried first.
  public var relativePath: String?
  public var absolutePath: String
  /// Change detection.
  public var size: Int64
  public var modified: Date

  public init(relativePath: String?, absolutePath: String, size: Int64, modified: Date) {
    self.relativePath = relativePath
    self.absolutePath = absolutePath
    self.size = size
    self.modified = modified
  }
}

/// Probe snapshot; a reopen draws at once.
public struct ClipFacts: Codable, Hashable, Sendable {
  /// `frameDuration` is nominal, e.g. 1001/30000.
  public var duration, frameDuration: RationalTime
  /// Rotation applied; 0/90/180/270.
  public var displayWidth, displayHeight, rotation: Int
  public var videoCodec: String
  public var hasAudio: Bool
  public var hdr: HDRKind
  public var bitrate: Int
  public var captureDate: Date?
  /// .mkv / .avi
  public var needsRemux: Bool

  public init(duration: RationalTime, frameDuration: RationalTime, displayWidth: Int, displayHeight: Int,
              rotation: Int, videoCodec: String, hasAudio: Bool, hdr: HDRKind, bitrate: Int,
              captureDate: Date?, needsRemux: Bool) {
    self.duration = duration
    self.frameDuration = frameDuration
    self.displayWidth = displayWidth
    self.displayHeight = displayHeight
    self.rotation = rotation
    self.videoCodec = videoCodec
    self.hasAudio = hasAudio
    self.hdr = hdr
    self.bitrate = bitrate
    self.captureDate = captureDate
    self.needsRemux = needsRemux
  }
}

public struct ReelClip: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var source: SourceRef
  public var facts: ClipFacts
  /// Source time, Out exclusive.
  public var inTime, outTime: RationalTime
  /// `join` is ignored on the first clip.
  public var join: Join
  public var framing: Framing
  /// Unknown keys, kept and re-written.
  public var extra: JSONObject = [:]

  public init(id: UUID, source: SourceRef, facts: ClipFacts, inTime: RationalTime, outTime: RationalTime,
              join: Join, framing: Framing, extra: JSONObject = [:]) {
    self.id = id
    self.source = source
    self.facts = facts
    self.inTime = inTime
    self.outTime = outTime
    self.join = join
    self.framing = framing
    self.extra = extra
  }

  /// A fresh clip covering the whole source: new UUID, In 0, Out = duration, join `.cut`.
  public static func make(source: SourceRef, facts: ClipFacts, framing: Framing) -> ReelClip {
    ReelClip(id: UUID(), source: source, facts: facts, inTime: .zero, outTime: facts.duration,
             join: .cut, framing: framing)
  }

  /// Length kept in the Reel before any crossfade overlap.
  public var trimmed: RationalTime { outTime - inTime }

  private enum Key: String, CaseIterable { case id, source, facts, inTime, outTime, join, framing }
  private static let known = Set(Key.allCases.map(\.rawValue))

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    func k(_ key: Key) -> DynamicKey { DynamicKey(key.rawValue) }
    id = try c.decode(UUID.self, forKey: k(.id))
    source = try c.decode(SourceRef.self, forKey: k(.source))
    facts = try c.decode(ClipFacts.self, forKey: k(.facts))
    inTime = try c.decode(RationalTime.self, forKey: k(.inTime))
    outTime = try c.decode(RationalTime.self, forKey: k(.outTime))
    join = try c.decode(Join.self, forKey: k(.join))
    framing = try c.decode(Framing.self, forKey: k(.framing))
    extra = try c.extra(excluding: Self.known)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: DynamicKey.self)
    func k(_ key: Key) -> DynamicKey { DynamicKey(key.rawValue) }
    try c.encodeExtra(extra, excluding: Self.known)
    try c.encode(id, forKey: k(.id))
    try c.encode(source, forKey: k(.source))
    try c.encode(facts, forKey: k(.facts))
    try c.encode(inTime, forKey: k(.inTime))
    try c.encode(outTime, forKey: k(.outTime))
    try c.encode(join, forKey: k(.join))
    try c.encode(framing, forKey: k(.framing))
  }
}

public struct ExportSpec: Codable, Hashable, Sendable {
  public enum Format: String, Codable, Hashable, Sendable { case reel, original }
  public enum Cut: String, Codable, Hashable, Sendable { case exact, quick }
  public enum Quality: String, Codable, Hashable, Sendable { case standard, high }

  public var format = Format.reel, cut = Cut.exact, quality = Quality.high
  public var convertHDR = true, removeAudio = false
  /// nil = derive (§4.9): the file name from `Naming`, the folder next to the clips (§13.1).
  public var fileName: String?, folder: String?
  /// Unknown keys, kept and re-written.
  public var extra: JSONObject = [:]

  public init(format: Format = .reel, cut: Cut = .exact, quality: Quality = .high,
              convertHDR: Bool = true, removeAudio: Bool = false,
              fileName: String? = nil, folder: String? = nil, extra: JSONObject = [:]) {
    self.format = format
    self.cut = cut
    self.quality = quality
    self.convertHDR = convertHDR
    self.removeAudio = removeAudio
    self.fileName = fileName
    self.folder = folder
    self.extra = extra
  }

  private enum Key: String, CaseIterable { case format, cut, quality, convertHDR, removeAudio, fileName, folder }
  private static let known = Set(Key.allCases.map(\.rawValue))

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    func k(_ key: Key) -> DynamicKey { DynamicKey(key.rawValue) }
    format = try c.decode(Format.self, forKey: k(.format))
    cut = try c.decode(Cut.self, forKey: k(.cut))
    quality = try c.decode(Quality.self, forKey: k(.quality))
    convertHDR = try c.decode(Bool.self, forKey: k(.convertHDR))
    removeAudio = try c.decode(Bool.self, forKey: k(.removeAudio))
    fileName = try c.decodeIfPresent(String.self, forKey: k(.fileName))
    folder = try c.decodeIfPresent(String.self, forKey: k(.folder))
    extra = try c.extra(excluding: Self.known)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: DynamicKey.self)
    func k(_ key: Key) -> DynamicKey { DynamicKey(key.rawValue) }
    try c.encodeExtra(extra, excluding: Self.known)
    try c.encode(format, forKey: k(.format))
    try c.encode(cut, forKey: k(.cut))
    try c.encode(quality, forKey: k(.quality))
    try c.encode(convertHDR, forKey: k(.convertHDR))
    try c.encode(removeAudio, forKey: k(.removeAudio))
    try c.encodeIfPresent(fileName, forKey: k(.fileName))
    try c.encodeIfPresent(folder, forKey: k(.folder))
  }
}

public struct Reel: Codable, Hashable, Sendable {
  public static let currentSchema = 1

  public var schema = Reel.currentSchema
  public var id: UUID
  public var name: String
  public var clips: [ReelClip]
  public var export: ExportSpec
  /// Unknown keys, kept and re-written.
  public var extra: JSONObject = [:]

  public init(schema: Int = Reel.currentSchema, id: UUID, name: String, clips: [ReelClip],
              export: ExportSpec = ExportSpec(), extra: JSONObject = [:]) {
    self.schema = schema
    self.id = id
    self.name = name
    self.clips = clips
    self.export = export
    self.extra = extra
  }

  /// A new Reel with no clips and the default export settings.
  public static func empty(name: String) -> Reel { Reel(id: UUID(), name: name, clips: []) }

  private enum Key: String, CaseIterable { case schema, id, name, clips, export }
  private static let known = Set(Key.allCases.map(\.rawValue))

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    func k(_ key: Key) -> DynamicKey { DynamicKey(key.rawValue) }
    schema = try c.decode(Int.self, forKey: k(.schema))
    id = try c.decode(UUID.self, forKey: k(.id))
    name = try c.decode(String.self, forKey: k(.name))
    clips = try c.decode([ReelClip].self, forKey: k(.clips))
    export = try c.decode(ExportSpec.self, forKey: k(.export))
    extra = try c.extra(excluding: Self.known)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: DynamicKey.self)
    func k(_ key: Key) -> DynamicKey { DynamicKey(key.rawValue) }
    try c.encodeExtra(extra, excluding: Self.known)
    try c.encode(schema, forKey: k(.schema))
    try c.encode(id, forKey: k(.id))
    try c.encode(name, forKey: k(.name))
    try c.encode(clips, forKey: k(.clips))
    try c.encode(export, forKey: k(.export))
  }
}

public struct Selection: Hashable, Sendable {
  public var primary: UUID?
  public var all: Set<UUID>
  public init(primary: UUID? = nil, all: Set<UUID> = []) {
    self.primary = primary
    self.all = all
  }
}
