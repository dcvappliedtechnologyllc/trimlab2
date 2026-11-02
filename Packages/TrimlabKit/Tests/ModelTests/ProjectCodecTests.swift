import Foundation
import Testing
@testable import TrimlabModel

@Suite struct ProjectCodecTests {
  // MARK: support

  /// The committed golden file (§8.3): never regenerated, every future version must open it.
  static let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Golden/schema1.trimlab")

  static func golden() throws -> Data { try Data(contentsOf: goldenURL) }

  static func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The golden as a mutable JSON object, re-serialised after `edit`.
  static func editedGolden(_ edit: (inout [String: Any]) -> Void) throws -> Data {
    var obj = try object(try golden())
    edit(&obj)
    return try JSONSerialization.data(withJSONObject: obj)
  }

  /// A fresh temp folder, removed by the caller.
  static func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProjectCodecTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: golden

  @Test func goldenOpens() throws {
    let reel = try ProjectCodec.decode(try Self.golden())
    #expect(reel.schema == 1)
    #expect(reel.name == "Spa Tour")
    #expect(reel.clips.count == 3)
    #expect(reel.clips[0].source.relativePath == "IMG_4821.MOV")
    #expect(reel.clips[0].facts.captureDate == Date(timeIntervalSinceReferenceDate: 783_000_000.25))
    #expect(reel.clips[0].source.modified == Date(timeIntervalSinceReferenceDate: 783_000_123.5))
    #expect(reel.clips[1].join == .crossfade(RationalTime(1, 4)))
    #expect(reel.clips[1].inTime == RationalTime(1001, 1000))
    #expect(reel.clips[1].outTime == RationalTime(1001, 125))
    #expect(reel.clips[2].framing == .fit)
    #expect(reel.clips[2].inTime == RationalTime(1, 2))
    #expect(reel.export.folder == "/Users/me/Movies/Reels")
    #expect(reel.export.format == .original)
    #expect(reel.export.removeAudio)
  }

  @Test func roundTripIsByteStable() throws {
    let once = ProjectCodec.encode(try ProjectCodec.decode(try Self.golden()))
    let twice = ProjectCodec.encode(try ProjectCodec.decode(once))
    #expect(once == twice)
  }

  @Test func goldenIsExactlyWhatTheEncoderWrites() throws {
    // Byte for byte, no trailing newline, slashes unescaped.
    let golden = try Self.golden()
    #expect(ProjectCodec.encode(try ProjectCodec.decode(golden)) == golden)
    #expect(golden.last == UInt8(ascii: "}"))
    #expect(String(decoding: golden, as: UTF8.self).contains(#""/Users/me/Movies/Reels""#))
  }

  @Test func goldenSurvivesRoundTripUnchanged() throws {
    let reel = try ProjectCodec.decode(try Self.golden())
    #expect(try ProjectCodec.decode(ProjectCodec.encode(reel)) == reel)
  }

  @Test func unknownKeysKept() throws {
    let obj = try Self.object(ProjectCodec.encode(try ProjectCodec.decode(try Self.golden())))
    #expect(obj["futureNote"] as? String == "keep me")
    let clips = try #require(obj["clips"] as? [[String: Any]])
    #expect(clips[0]["futureNote"] as? String == "keep me")
    let export = try #require(obj["export"] as? [String: Any])
    #expect(export["futureNote"] as? String == "keep me")
  }

  @Test func writesSchemaAndApp() throws {
    let data = ProjectCodec.encode(Builders.reel([3, 4], name: "Spa Tour"))
    let obj = try Self.object(data)
    #expect(obj["schema"] as? Int == 1)
    #expect(obj["app"] as? String == "trimlab 2.0")
    // Pretty and sorted: top-level keys appear in sorted order in the text.
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("\n  \"app\""))
    let order = ["\"app\"", "\"clips\"", "\"export\"", "\"id\"", "\"name\"", "\"schema\""]
      .map { text.range(of: "\n  \($0)")!.lowerBound }
    #expect(order == order.sorted())
  }

  @Test func appIsNotKeptInExtra() throws {
    let reel = try ProjectCodec.decode(try Self.golden())
    #expect(reel.extra["app"] == nil)
    #expect(reel.extra["futureNote"] == .string("keep me"))
    // An "app" smuggled into extra in memory is never written twice or over the real one.
    var odd = reel
    odd.extra["app"] = .string("someone else")
    #expect(try Self.object(ProjectCodec.encode(odd))["app"] as? String == "trimlab 2.0")
  }

  @Test func encodeAlwaysWritesCurrentSchema() throws {
    var reel = Builders.reel([3])
    reel.schema = 0
    #expect(try Self.object(ProjectCodec.encode(reel))["schema"] as? Int == Reel.currentSchema)
  }

  @Test func datesAreSecondsSinceReferenceDate() throws {
    // F6: pinned .deferredToDate, sub-second mtimes survive (change detection, §8.2).
    var reel = Builders.reel([3])
    reel.clips[0].source.modified = Date(timeIntervalSinceReferenceDate: 783_000_000.125)
    let obj = try Self.object(ProjectCodec.encode(reel))
    let clip = try #require((obj["clips"] as? [[String: Any]])?.first)
    let source = try #require(clip["source"] as? [String: Any])
    #expect(source["modified"] as? Double == 783_000_000.125)
  }

  // MARK: refusal

  @Test func newerSchemaRefused() throws {
    let data = try Self.editedGolden { $0["schema"] = 2 }
    #expect(throws: ProjectError.newerVersion(2)) { try ProjectCodec.decode(data) }
  }

  @Test func newerSchemaRefusedEvenWhenTheRestIsUnknown() throws {
    // A future file may be shaped nothing like schema 1; the schema is read first.
    let data = Data(#"{"schema": 7, "tracks": []}"#.utf8)
    #expect(throws: ProjectError.newerVersion(7)) { try ProjectCodec.decode(data) }
  }

  @Test func refusalMessagesArePlain() {
    #expect(ProjectError.newerVersion(2).message == "This Reel was made by a newer version of trimlab.")
    #expect(ProjectError.unreadable.message == "This Reel file can't be read.")
  }

  @Test func truncatedJsonIsUnreadable() throws {
    let data = try Self.golden().prefix(200)
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(Data(data)) }
  }

  @Test func notAProjectIsUnreadable() {
    for text in ["", "[]", "{}", #"{"schema": "one"}"#, #"{"schema": 1}"#, "not json"] {
      #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(Data(text.utf8)) }
    }
  }

  // MARK: migrations

  @Test func shippedMigrationsAreEmptyInV2() {
    #expect(Migrations.steps.isEmpty)
  }

  @Test func migrationStepsRunInOrder() throws {
    let data = try Self.editedGolden { $0["schema"] = 0 }
    let steps: [Int: Migrations.Step] = [
      0: { var o = $0; o["a"] = .string("from 0"); return o },
      1: { var o = $0; o["b"] = .string("must not run: 1 is current"); return o },
    ]
    let reel = try ProjectCodec.decode(data, steps: steps)
    #expect(reel.extra["a"] == .string("from 0"))
    #expect(reel.extra["b"] == nil)
    #expect(reel.schema == Reel.currentSchema)
  }

  @Test func migrationChainRunsEachStepOnce() throws {
    // Three steps up to a pretend schema 3: each sees the previous step's output, in order.
    let data = try Self.editedGolden { $0["schema"] = 0 }
    func step(_ n: Int) -> Migrations.Step {
      { var o = $0
        guard case .array(let trail)? = o["trail"] else { o["trail"] = .array([.number(Double(n))]); return o }
        o["trail"] = .array(trail + [.number(Double(n))])
        return o }
    }
    let reel = try ProjectCodec.decode(data, steps: [0: step(0), 1: step(1), 2: step(2), 3: step(3)], current: 3)
    #expect(reel.extra["trail"] == .array([.number(0), .number(1), .number(2)]))
    #expect(reel.schema == 3)
  }

  @Test func missingMigrationStepIsUnreadable() throws {
    let data = try Self.editedGolden { $0["schema"] = 0 }
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(data, steps: [:]) }
  }

  @Test func negativeSchemaIsUnreadable() throws {
    let data = try Self.editedGolden { $0["schema"] = -1 }
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(data) }
  }

  // MARK: sanitise on load (P17, reuses the Task 10 trim rules)

  /// The golden with clip 0's In / Out replaced.
  static func goldenWithClip0(in inTime: [Int], out outTime: [Int]) throws -> Data {
    try editedGolden { obj in
      var clips = obj["clips"] as! [[String: Any]]
      clips[0]["inTime"] = inTime
      clips[0]["outTime"] = outTime
      obj["clips"] = clips
    }
  }

  @Test func handEditedTrimIsSanitised() throws {
    let reel = try ProjectCodec.decode(try Self.goldenWithClip0(in: [5, 1], out: [2, 1]))
    #expect(reel.clips[0].inTime == .zero)
    #expect(reel.clips[0].outTime == reel.clips[0].facts.duration)
  }

  @Test func offGridTrimIsFloored() throws {
    // 1.0 s at 29.97 floors to frame 29 (29029/30000); 5.0 s floors to frame 149.
    let reel = try ProjectCodec.decode(try Self.goldenWithClip0(in: [1, 1], out: [5, 1]))
    #expect(reel.clips[0].inTime == RationalTime(29029, 30000))
    #expect(reel.clips[0].outTime == RationalTime(149149, 30000))
  }

  @Test func outPastTheEndIsClamped() throws {
    let reel = try ProjectCodec.decode(try Self.goldenWithClip0(in: [0, 1], out: [99, 1]))
    #expect(reel.clips[0].outTime == reel.clips[0].facts.duration)
  }

  @Test func legacySpanBelowMinimumKeepsOutAndPullsInBack() throws {
    // In 2.002 s, Out 2.2022 s: a 0.2 s span from an older build. Out stays; In moves back to keep ≥ 0.5 s.
    let reel = try ProjectCodec.decode(try Self.goldenWithClip0(in: [2002, 1000], out: [66066, 30000]))
    let clip = reel.clips[0]
    #expect(clip.outTime == RationalTime(66066, 30000))
    #expect(clip.trimmed >= Limits.minSpan)
    #expect(clip.inTime == RationalTime(66066 - 15015, 30000))  // 15 frames back: the latest frame start giving ≥ 0.5 s
  }

  @Test func legacySpanTooShortNearTheStartResetsToFullSource() throws {
    // Out 0.2 s: nothing to pull In back into, so the clip is reset to the whole source.
    let reel = try ProjectCodec.decode(try Self.goldenWithClip0(in: [0, 1], out: [6006, 30000]))
    #expect(reel.clips[0].inTime == .zero)
    #expect(reel.clips[0].outTime == reel.clips[0].facts.duration)
  }

  // MARK: bounded decode (fix round 1): damaged numbers are refused, never trap

  /// The golden with clip 0's facts / trim fields replaced by raw JSON numbers.
  static func goldenWithClip0Times(_ fields: [String: [Any]]) throws -> Data {
    try editedGolden { obj in
      var clips = obj["clips"] as! [[String: Any]]
      var facts = clips[0]["facts"] as! [String: Any]
      for (key, pair) in fields {
        if key == "inTime" || key == "outTime" { clips[0][key] = pair } else { facts[key] = pair }
      }
      clips[0]["facts"] = facts
      obj["clips"] = clips
    }
  }

  @Test func reviewerOverflowFileIsUnreadable() throws {
    let data = try Self.goldenWithClip0Times([
      "duration": [9_000_000_000_000_000_000 as Int64, 1], "inTime": [5_000_000_000_000_000_000 as Int64, 1],
      "outTime": [9_000_000_000_000_000_000 as Int64, 1],
    ])
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(data) }
  }

  @Test func largeTimeAtFrameTimescaleIsUnreadable() throws {
    // ~3×10^14 at 30000 (coprime, so it doesn't reduce on decode) is past |value| < 2^40.
    let data = try Self.goldenWithClip0Times(["inTime": [300_000_000_000_001 as Int64, 30000]])
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(data) }
  }

  @Test func justOverEachBoundIsUnreadable() throws {
    let cases: [[String: [Any]]] = [
      ["inTime": [1 << 40 as Int64, 1]],                         // |value| = 2^40
      ["outTime": [-(1 << 40) as Int64, 1]],
      ["inTime": [1, 1_000_000_001]],                            // timescale > 1e9
      ["duration": [86401, 1]],                                  // > 24 h
      ["duration": [-1, 1]],                                     // negative
      ["duration": [0, 1], "outTime": [0, 1]],                   // zero-length clip (Phase 2 review)
      ["frameDuration": [0, 1]],                                 // not > 0
      ["frameDuration": [1001, 1000]],                           // > 1 s
      ["inTime": [1, 9_999_991]],                                // clip timescales' lcm > 1e7
    ]
    for fields in cases {
      let data = try Self.goldenWithClip0Times(fields)
      #expect(throws: ProjectError.unreadable, "\(fields)") { try ProjectCodec.decode(data) }
    }
  }

  @Test func hugeTimescalesInsideScalarBoundsAreUnreadable() throws {
    // Every number is inside the scalar bounds, yet flooring In (≈ 9 999 s) to a 1/999 999 937 s frame multiplies
    // ≈ 10^12 by ≈ 10^9 and traps. The per-clip common-timescale bound (≤ 10^7) refuses it first.
    let data = try Self.goldenWithClip0Times([
      "duration": [86400, 1], "outTime": [86400, 1], "frameDuration": [1, 999_999_937],
      "inTime": [999_999_999_999 as Int64, 100_000_007],
    ])
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(data) }
  }

  @Test func atEachBoundStillOpens() throws {
    let cases: [[String: [Any]]] = [
      ["inTime": [(1 << 40) - 1, 1]],                            // past the end: snaps, handles cross → full source
      ["duration": [86400, 1], "outTime": [86400, 1]],           // exactly 24 h
      ["frameDuration": [1, 1]],                                 // exactly 1 s
      ["inTime": [0, 1_000_000_000]],                            // normalises to [0,1]
    ]
    for fields in cases {
      let reel = try ProjectCodec.decode(try Self.goldenWithClip0Times(fields))
      #expect(reel.clips[0].trimmed >= Limits.minSpan, "\(fields)")
    }
  }

  @Test func validTrimsAreUntouched() throws {
    let data = try Self.golden()
    let reel = try ProjectCodec.decode(data)
    let raw = try JSONDecoder().decode(Reel.self, from: data)
    #expect(reel.clips.map(\.inTime) == raw.clips.map(\.inTime))
    #expect(reel.clips.map(\.outTime) == raw.clips.map(\.outTime))
  }

  // MARK: atomic write and the refused-file guard (§8.2; Task 31 `refusedProjectIsNeverAutosaved`)

  /// Writes `reel` encoded, passing its own id.
  static func save(_ reel: Reel, to url: URL) throws(ProjectWriteError) {
    try ProjectFile.write(ProjectCodec.encode(reel), to: url, reelID: reel.id)
  }

  static func listing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }

  @Test func writeCreatesTheFileAndLeavesNoTemp() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    let reel = Builders.reel([3, 4])
    try Self.save(reel, to: url)
    #expect(try Data(contentsOf: url) == ProjectCodec.encode(reel))
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
  }

  @Test func writeReplacesOurOwnEarlierSave() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    var reel = Builders.reel([3, 4], name: "First")
    try Self.save(reel, to: url)
    reel.name = "Second"
    reel.clips.append(Builders.clip(5))
    try Self.save(reel, to: url)
    #expect(try Data(contentsOf: url) == ProjectCodec.encode(reel))
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
  }

  @Test func writeNeverReplacesAnotherReel() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    let theirs = ProjectCodec.encode(Builders.reel([3, 4], name: "Theirs"))
    try theirs.write(to: url)
    #expect(throws: ProjectWriteError.wouldReplaceAnotherReel) { try Self.save(Builders.reel([3, 4]), to: url) }
    #expect(try Data(contentsOf: url) == theirs)
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
  }

  @Test func writeNeverReplacesANewerSchemaFile() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    let newer = try Self.editedGolden { $0["schema"] = 2 }
    try newer.write(to: url)
    #expect(throws: ProjectWriteError.wouldReplaceRefusedFile) { try Self.save(Builders.reel([3, 4]), to: url) }
    #expect(try Data(contentsOf: url) == newer)
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
  }

  @Test func writeNeverReplacesAnUnreadableFile() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    let junk = Data("not a reel".utf8)
    try junk.write(to: url)
    #expect(throws: ProjectWriteError.wouldReplaceRefusedFile) { try Self.save(Builders.reel([3, 4]), to: url) }
    #expect(try Data(contentsOf: url) == junk)
  }

  @Test func writeIntoAMissingFolderFailsCleanly() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("gone/Spa Tour.trimlab")
    #expect(throws: ProjectWriteError.self) { try Self.save(Builders.reel([3, 4]), to: url) }
    #expect(try Self.listing(folder).isEmpty)
  }

  @Test func writeGoesThroughASymlink() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    try fm.createDirectory(at: folder.appendingPathComponent("real"), withIntermediateDirectories: true)
    let real = folder.appendingPathComponent("real/Spa Tour.trimlab")
    let link = folder.appendingPathComponent("Spa Tour.trimlab")
    var reel = Builders.reel([3, 4], name: "First")
    try Self.save(reel, to: real)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    reel.name = "Second"
    try Self.save(reel, to: link)
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)
    #expect(try Data(contentsOf: real) == ProjectCodec.encode(reel))
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab", "real"])
    #expect(try Self.listing(folder.appendingPathComponent("real")) == ["Spa Tour.trimlab"])
  }

  @Test func replaceKeepsCreationDateAndExtendedAttributes() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    var reel = Builders.reel([3, 4])
    try Self.save(reel, to: url)
    let created = Date(timeIntervalSinceReferenceDate: 700_000_000)
    try fm.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    let tag = Array("keep".utf8)
    #expect(setxattr(url.path, "com.dcv.trimlab2.test", tag, tag.count, 0, 0) == 0)
    reel.name = "Edited"
    try Self.save(reel, to: url)
    #expect(try fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date == created)
    var buffer = [UInt8](repeating: 0, count: 16)
    let n = getxattr(url.path, "com.dcv.trimlab2.test", &buffer, buffer.count, 0, 0)
    #expect(n == tag.count && Array(buffer.prefix(max(n, 0))) == tag)
    #expect(try Data(contentsOf: url) == ProjectCodec.encode(reel))
  }

  @Test func staleTempFilesAreSweptFreshOnesKept() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    let stale = folder.appendingPathComponent(".Spa Tour.trimlab.\(UUID().uuidString).tmp")
    let fresh = folder.appendingPathComponent(".Spa Tour.trimlab.\(UUID().uuidString).tmp")
    let otherName = folder.appendingPathComponent(".Other.trimlab.\(UUID().uuidString).tmp")
    for f in [stale, fresh, otherName] { try Data("x".utf8).write(to: f) }
    let old = Date(timeIntervalSinceNow: -120)
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: otherName.path)
    try Self.save(Builders.reel([3, 4]), to: url)
    #expect(!fm.fileExists(atPath: stale.path))
    #expect(fm.fileExists(atPath: fresh.path))       // another write may still be in flight
    #expect(fm.fileExists(atPath: otherName.path))   // not ours to touch
  }

  @Test func writeErrorMessagesArePlain() {
    let errors: [ProjectWriteError] = [.wouldReplaceRefusedFile, .wouldReplaceAnotherReel,
                                       .failed("rename: No space left on device (/Users/me/x.trimlab)")]
    for e in errors {
      #expect(!e.message.isEmpty)
      #expect(!e.message.contains("/"))
      #expect(!e.message.localizedCaseInsensitiveContains("rename"))
      #expect(!e.message.localizedCaseInsensitiveContains("No space left"))
    }
    #expect(ProjectWriteError.failed("detail").logDetail.contains("detail"))
  }

  @Test func readOpensWhatWriteWrote() throws {
    let folder = try Self.tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("Spa Tour.trimlab")
    let reel = try ProjectCodec.decode(try Self.golden())
    try Self.save(reel, to: url)
    #expect(try ProjectFile.read(url) == reel)
    #expect(throws: ProjectError.unreadable) { try ProjectFile.read(folder.appendingPathComponent("none.trimlab")) }
  }

  // MARK: Reel-wide bounds and crossfade snap (Phase 2 review)

  /// Decodes, then plans whatever opened. Before the fix these inputs decoded and the plan trapped.
  static func decodeAndPlan(_ data: Data) throws(ProjectError) -> Reel {
    let reel = try ProjectCodec.decode(data)
    _ = Planner.plan(reel)
    return reel
  }

  /// The golden with clip 0 a 2.002 s whole source and the given join into clip 1.
  static func goldenWithJoin1(_ join: [String: Any]) throws -> Data {
    try editedGolden { obj in
      var clips = obj["clips"] as! [[String: Any]]
      var facts = clips[0]["facts"] as! [String: Any]
      facts["duration"] = [60061, 30000]
      clips[0]["facts"] = facts
      clips[0]["outTime"] = [60061, 30000]
      clips[1]["join"] = join
      obj["clips"] = clips
    }
  }

  @Test func craftedCrossfadeSnapsAndPlans() throws {
    // [1, 2^31 − 1] decoded fine and the plan trapped narrowing an lcm timescale to Int32.
    let reel = try Self.decodeAndPlan(try Self.goldenWithJoin1(["crossfade": [1, 2_147_483_647]]))
    #expect(reel.clips[1].join == .crossfade(Limits.shortFade))
  }

  @Test func crossfadeSnapsToTheNearerFadeOrCut() throws {
    let cases: [([Int64], Join)] = [
      ([0, 1], .cut), ([-1, 4], .cut), ([1, 10], .crossfade(Limits.shortFade)),
      ([1, 4], .crossfade(Limits.shortFade)), ([5, 8], .crossfade(Limits.shortFade)),  // halfway: the shorter
      ([5_000_001, 8_000_000], .crossfade(Limits.longFade)), ([1, 1], .crossfade(Limits.longFade)),
      ([7, 1], .crossfade(Limits.longFade)), ([9_223_372_036_854_775_807, 1], .crossfade(Limits.longFade)),
    ]
    for (pair, expected) in cases {
      let reel = try Self.decodeAndPlan(try Self.goldenWithJoin1(["crossfade": pair]))
      #expect(reel.clips[1].join == expected, "\(pair)")
    }
    let cut = try Self.decodeAndPlan(try Self.goldenWithJoin1(["cut": [String: Any]()]))
    #expect(cut.clips[1].join == .cut)
  }

  @Test func reelWideTimescaleMixIsUnreadable() throws {
    let reel = Reel(id: UUID(), name: "mix", clips: Builders.timescaleMix)
    #expect(reel.clips.allSatisfy(TimeBounds.isSane))  // each clip alone is in bounds
    #expect(throws: ProjectError.unreadable) { try Self.decodeAndPlan(ProjectCodec.encode(reel)) }
  }

  @Test func reelWideLcmAtTheBoundOpensAndJustOverIsUnreadable() throws {
    // 5^8 and 2^8 (with the 1/2 and 1/4 seeds and 1/25 frames) make exactly 10^8; a 1/3 s timescale makes 3 × 10^8.
    let fps = RationalTime(1, 25)
    let atBound = [Builders.clip(duration: RationalTime(390_626, 390_625), fps: fps),
                   Builders.clip(duration: RationalTime(257, 256), fps: fps)]
    let reel = try Self.decodeAndPlan(ProjectCodec.encode(Reel(id: UUID(), name: "at", clips: atBound)))
    #expect(reel.clips.count == 2)
    let over = atBound + [Builders.clip(duration: RationalTime(4, 3), fps: fps)]
    #expect(throws: ProjectError.unreadable) {
      try Self.decodeAndPlan(ProjectCodec.encode(Reel(id: UUID(), name: "over", clips: over)))
    }
  }

  @Test func clipCountIsBounded() throws {
    let thousand = Reel(id: UUID(), name: "1000", clips: (0..<1000).map { _ in Builders.clip(1) })
    #expect(try ProjectCodec.decode(ProjectCodec.encode(thousand)).clips.count == 1000)
    var more = thousand
    more.clips.append(Builders.clip(1))
    #expect(throws: ProjectError.unreadable) { try ProjectCodec.decode(ProjectCodec.encode(more)) }
  }

  /// The golden with clip 0's scalar facts replaced.
  static func goldenWithClip0Facts(_ fields: [String: Any]) throws -> Data {
    try editedGolden { obj in
      var clips = obj["clips"] as! [[String: Any]]
      var facts = clips[0]["facts"] as! [String: Any]
      for (key, value) in fields { facts[key] = value }
      clips[0]["facts"] = facts
      obj["clips"] = clips
    }
  }

  @Test func displaySizeAndRotationOutOfBoundsAreUnreadable() throws {
    let cases: [[String: Any]] = [
      ["displayWidth": 1], ["displayWidth": 16385], ["displayHeight": 0], ["displayHeight": -1080],
      ["displayHeight": 16385], ["rotation": 45], ["rotation": -90], ["rotation": 360],
    ]
    for fields in cases {
      #expect(throws: ProjectError.unreadable, "\(fields)") {
        try ProjectCodec.decode(try Self.goldenWithClip0Facts(fields))
      }
    }
  }

  @Test func displaySizeAndRotationAtTheBoundsOpen() throws {
    let cases: [[String: Any]] = [
      ["displayWidth": 2, "displayHeight": 2], ["displayWidth": 16384, "displayHeight": 16384],
      ["rotation": 0], ["rotation": 180], ["rotation": 270],
    ]
    for fields in cases {
      let reel = try ProjectCodec.decode(try Self.goldenWithClip0Facts(fields))
      #expect(reel.clips.count == 3, "\(fields)")
    }
  }
}
