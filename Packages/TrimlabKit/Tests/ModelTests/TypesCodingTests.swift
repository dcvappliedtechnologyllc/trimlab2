import Foundation
import Testing
@testable import TrimlabModel

@Suite struct TypesCodingTests {
  // MARK: fixtures

  static let date = Date(timeIntervalSinceReferenceDate: 783_000_000.25)

  static func facts(duration: RationalTime = RationalTime(236, 10)) -> ClipFacts {
    ClipFacts(duration: duration, frameDuration: RationalTime(1001, 30000),
              displayWidth: 1080, displayHeight: 1920, rotation: 90,
              videoCodec: "hvc1", hasAudio: true, hdr: .hlg,
              bitrate: 12_000_000, captureDate: date, needsRemux: false)
  }

  static func source() -> SourceRef {
    SourceRef(relativePath: "IMG_4821.MOV", absolutePath: "/Volumes/Card/IMG_4821.MOV",
              size: 123_456_789, modified: date)
  }

  static func clip() -> ReelClip { ReelClip.make(source: source(), facts: facts(), framing: .fill) }

  /// Encodes `value`, adds `"future": {"a":[1,2]}` at the top level, decodes it back.
  static func injectFuture<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    obj["future"] = ["a": [1, 2]]
    return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: obj))
  }

  static func futureOf<T: Encodable>(_ value: T) throws -> NSDictionary? {
    let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value)) as? [String: Any]
    return obj?["future"] as? NSDictionary
  }

  static let futureValue: JSONValue = .object(["a": .array([.number(1), .number(2)])])
  static var futureDict: NSDictionary { ["a": [1, 2]] }

  // MARK: extra round-trip

  @Test func unknownKeysRoundTripOnEveryExtraType() throws {
    let clip = try Self.injectFuture(Self.clip())
    #expect(clip.extra["future"] == Self.futureValue)
    #expect(try Self.futureOf(clip) == Self.futureDict)

    let spec = try Self.injectFuture(ExportSpec())
    #expect(spec.extra["future"] == Self.futureValue)
    #expect(try Self.futureOf(spec) == Self.futureDict)

    var reel = Reel.empty(name: "Spa Tour")
    reel.clips = [clip]
    reel.export = spec
    let decoded = try Self.injectFuture(reel)
    #expect(decoded.extra["future"] == Self.futureValue)
    #expect(try Self.futureOf(decoded) == Self.futureDict)
    #expect(decoded.clips[0].extra["future"] == Self.futureValue)
    #expect(decoded.export.extra["future"] == Self.futureValue)
  }

  @Test func knownKeysDoNotLandInExtra() throws {
    let clip = try JSONDecoder().decode(ReelClip.self, from: try JSONEncoder().encode(Self.clip()))
    #expect(clip.extra.isEmpty)
    let reel = try JSONDecoder().decode(Reel.self, from: try JSONEncoder().encode(Reel.empty(name: "x")))
    #expect(reel.extra.isEmpty && reel.export.extra.isEmpty)
  }

  @Test func extraDoesNotOverrideKnownKeys() throws {
    var spec = ExportSpec()
    spec.extra = ["quality": .string("standard")]
    let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(spec)) as? [String: Any]
    #expect(obj?["quality"] as? String == "high")
  }

  @Test func valuesRoundTripExactly() throws {
    var reel = Reel.empty(name: "Spa Tour")
    var b = Self.clip()
    b.join = .crossfade(Limits.shortFade)
    b.framing = .fit
    b.inTime = RationalTime(2002, 30000)
    reel.clips = [Self.clip(), b]
    reel.export.fileName = "Out.mp4"
    reel.export.folder = "/Users/me/Movies"
    reel.export.quality = .standard
    reel.extra = ["note": .array([.null, .bool(true), .string("s"), .number(1.5)])]
    let back = try JSONDecoder().decode(Reel.self, from: try JSONEncoder().encode(reel))
    #expect(back == reel)
  }

  @Test func reelKeyNames() throws {
    let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Reel.empty(name: "x"))) as? [String: Any]
    #expect(Set(obj?.keys.map { $0 } ?? []) == ["schema", "id", "name", "clips", "export"])
    #expect(obj?["schema"] as? Int == 1)
  }

  // MARK: Join (F1: spec shape, not synthesized `_0`)

  @Test func joinCodesAsSpecShape() throws {
    let enc = JSONEncoder()
    #expect(String(data: try enc.encode(Join.cut), encoding: .utf8) == #"{"cut":{}}"#)
    #expect(String(data: try enc.encode(Join.crossfade(RationalTime(1, 4))), encoding: .utf8) == #"{"crossfade":[1,4]}"#)
    let dec = JSONDecoder()
    #expect(try dec.decode(Join.self, from: Data(#"{"cut":{}}"#.utf8)) == .cut)
    #expect(try dec.decode(Join.self, from: Data(#"{"crossfade":[1,4]}"#.utf8)) == .crossfade(RationalTime(1, 4)))
  }

  @Test func joinRejectsUnknownOrAmbiguous() {
    let dec = JSONDecoder()
    #expect(throws: DecodingError.self) { try dec.decode(Join.self, from: Data(#"{"wipe":{}}"#.utf8)) }
    #expect(throws: DecodingError.self) { try dec.decode(Join.self, from: Data(#"{"cut":{},"crossfade":[1,4]}"#.utf8)) }
    #expect(throws: DecodingError.self) { try dec.decode(Join.self, from: Data(#"{"crossfade":{"_0":[1,4]}}"#.utf8)) }
  }

  // MARK: LayerEffect (F4: no cases in v2)

  @Test func layerEffectHasNoDecodableValue() throws {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([LayerEffect].self, from: Data(#"[{"look":"x"}]"#.utf8)) }
    #expect(try JSONDecoder().decode([LayerEffect].self, from: Data("[]".utf8)).isEmpty)
  }

  // MARK: JSONValue

  @Test func jsonValueRoundTrips() throws {
    let text = #"{"a":null,"b":true,"c":1.5,"d":"s","e":[1,{"f":false}]}"#
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(v == .object(["a": .null, "b": .bool(true), "c": .number(1.5), "d": .string("s"),
                          "e": .array([.number(1), .object(["f": .bool(false)])])]))
    let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(v))
    #expect(again == v)
  }

  // MARK: defaults and helpers

  @Test func exportSpecDefaults() {
    let s = ExportSpec()
    #expect(s.format == .reel && s.cut == .exact && s.quality == .high && s.convertHDR && !s.removeAudio && s.fileName == nil)
    #expect(s.folder == nil && s.extra.isEmpty)  // nil folder = next to the clips (§13.1)
  }

  @Test func makeClipDefaults() {
    let f = Self.facts()
    let c = ReelClip.make(source: Self.source(), facts: f, framing: .fit)
    #expect(c.inTime == .zero && c.outTime == f.duration && c.join == .cut && c.framing == .fit)
    #expect(c.source == Self.source() && c.facts == f && c.extra.isEmpty)
    #expect(c.trimmed == f.duration)
    #expect(ReelClip.make(source: Self.source(), facts: f, framing: .fit).id != c.id)
  }

  @Test func trimmedIsOutMinusIn() {
    var c = Self.clip()
    c.inTime = RationalTime(1, 1)
    c.outTime = RationalTime(5, 2)
    #expect(c.trimmed == RationalTime(3, 2))
  }

  @Test func timeSpanEnd() {
    #expect(TimeSpan(start: RationalTime(1, 2), duration: RationalTime(1, 4)).end == RationalTime(3, 4))
  }

  @Test func emptyReel() {
    let r = Reel.empty(name: "Spa Tour")
    #expect(r.name == "Spa Tour" && r.clips.isEmpty && r.schema == Reel.currentSchema && r.export == ExportSpec())
    #expect(Reel.currentSchema == 1)
    #expect(Reel.empty(name: "x").id != r.id)
  }

  @Test func selectionDefaultsEmpty() {
    let s = Selection()
    #expect(s.primary == nil && s.all.isEmpty)
  }

  @Test func rawEnumsCodeAsStrings() throws {
    let enc = JSONEncoder()
    #expect(String(data: try enc.encode([Framing.fill, .fit]), encoding: .utf8) == #"["fill","fit"]"#)
    #expect(String(data: try enc.encode([HDRKind.sdr, .hlg, .pq]), encoding: .utf8) == #"["sdr","hlg","pq"]"#)
    #expect(String(data: try enc.encode([ExportSpec.Format.reel, .original]), encoding: .utf8) == #"["reel","original"]"#)
    #expect(String(data: try enc.encode([ExportSpec.Cut.exact, .quick]), encoding: .utf8) == #"["exact","quick"]"#)
    #expect(String(data: try enc.encode([ExportSpec.Quality.standard, .high]), encoding: .utf8) == #"["standard","high"]"#)
  }

  @Test func publicTypesAreSendable() {
    func needsSendableHashable<T: Sendable & Hashable>(_: T.Type) {}
    needsSendableHashable(ExportSpec.Format.self)
    needsSendableHashable(ExportSpec.Cut.self)
    needsSendableHashable(ExportSpec.Quality.self)
    needsSendableHashable(Framing.self)
    needsSendableHashable(HDRKind.self)
    needsSendableHashable(Join.self)
    needsSendableHashable(LayerEffect.self)
    needsSendableHashable(JSONValue.self)
    needsSendableHashable(PixelSize.self)
    needsSendableHashable(Selection.self)
    needsSendableHashable(Reel.self)
  }
}
