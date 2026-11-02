import CoreText
import CryptoKit
import Foundation
import Testing
import TrimlabEditor

@Suite struct FontTests {
  static let fontsDir = SourceScan.repoRoot / "Resources/Fonts"

  private func ctFamily(_ postScriptName: String) -> String {
    CTFontCopyFamilyName(CTFontCreateWithName(postScriptName as CFString, 12, nil)) as String
  }
  private func postScript(of face: TLFont, size: CGFloat) -> String {
    CTFontCopyPostScriptName(face.ctFont(size: size)) as String
  }
  private func familyName(of face: TLFont, size: CGFloat) -> String {
    CTFontCopyFamilyName(face.ctFont(size: size)) as String
  }
  private func isItalic(_ face: TLFont, size: CGFloat) -> Bool {
    CTFontGetSymbolicTraits(face.ctFont(size: size)).contains(.italicTrait)
  }
  private func axisValue(_ face: TLFont, size: CGFloat, tag: UInt32) -> Double? {
    let vars = CTFontCopyVariation(face.ctFont(size: size)) as? [NSNumber: NSNumber]
    return vars?[NSNumber(value: tag)]?.doubleValue
  }
  private let wght: UInt32 = 0x7767_6874
  private let opsz: UInt32 = 0x6F70_737A

  @Test("fonts resolve") func bundledFontsResolve() {
    FontRegistry.registerBundled(from: Self.fontsDir)
    for ps in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold"] {
      #expect(ctFamily(ps) == "Inter", "\(ps) did not resolve to Inter")
    }
    #expect(familyName(of: .bodoni(italic: true, weight: 400), size: 52) == "Bodoni Moda")
    #expect(familyName(of: .bodoni(italic: false, weight: 500), size: 28) == "Bodoni Moda")
    #expect(isItalic(.bodoni(italic: true, weight: 500), size: 64))
    #expect(!isItalic(.bodoni(italic: false, weight: 500), size: 28))
  }

  @Test func interWeightsMapToPostScriptNames() {
    FontRegistry.registerBundled(from: Self.fontsDir)
    let expected: [(Weight, String)] = [
      (.regular, "Inter-Regular"), (.medium, "Inter-Medium"),
      (.semibold, "Inter-SemiBold"), (.bold, "Inter-Bold"),
    ]
    for (weight, ps) in expected {
      #expect(postScript(of: .inter(weight), size: 13) == ps)
    }
  }

  @Test func bodoniAxesFollowWeightAndClampedSize() {
    FontRegistry.registerBundled(from: Self.fontsDir)
    #expect(axisValue(.bodoni(italic: false, weight: 500), size: 28, tag: wght) == 500)
    #expect(axisValue(.bodoni(italic: false, weight: 500), size: 28, tag: opsz) == 28)
    #expect(axisValue(.bodoni(italic: true, weight: 400), size: 4, tag: opsz) == 6)
    #expect(axisValue(.bodoni(italic: true, weight: 400), size: 200, tag: opsz) == 96)
  }

  /// The CTC wordmark pins `opsz` 11 (v1's static cut) at any point size; nil keeps following the size.
  @Test func bodoniOpticalSizeOverride() {
    FontRegistry.registerBundled(from: Self.fontsDir)
    let pinned = TLFont.bodoni(italic: false, weight: 500).ctFont(size: 40, opticalSize: 11)
    let vars = CTFontCopyVariation(pinned) as? [NSNumber: NSNumber]
    // 11 is the axis default, which CoreText leaves out of the variation dictionary.
    #expect((vars?[NSNumber(value: opsz)]?.doubleValue ?? 11) == 11)
    #expect(vars?[NSNumber(value: wght)]?.doubleValue == 500)
    #expect(TLFont.bodoni(italic: false, weight: 500).matches(pinned))
    #expect(axisValue(.bodoni(italic: false, weight: 500), size: 40, tag: opsz) == 40)
    // and the outlines really differ: opsz 11 capitals are wider than opsz 40's (1436 vs 1364 units for "C").
    func advanceOfC(_ font: CTFont) -> Double {
      var ch: UniChar = 0x43, glyph: CGGlyph = 0
      CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
      return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
    }
    let following = TLFont.bodoni(italic: false, weight: 500).ctFont(size: 40)
    #expect(advanceOfC(pinned) > advanceOfC(following) + 1)
  }

  @Test func registeringTwiceIsHarmless() {
    FontRegistry.registerBundled(from: Self.fontsDir)
    FontRegistry.registerBundled(from: Self.fontsDir)
    #expect(ctFamily("Inter-Bold") == "Inter")
  }

  @Test func registeringANonFontFileReportsFailure() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("font-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let junk = dir / "NotAFont.ttf"
    try Data("not a font".utf8).write(to: junk)
    let failures = FontRegistry.registerBundled(from: junk)
    #expect(failures.count == 1)
    #expect(failures.first?.path == junk.path)
  }

  @Test func registeringAMissingDirectoryReportsFailure() {
    let gone = FileManager.default.temporaryDirectory.appendingPathComponent("font-missing-\(UUID().uuidString)")
    let failures = FontRegistry.registerBundled(from: gone)
    #expect(failures.count == 1)
    #expect(failures.first?.path == gone.path)
  }

  @Test func goodRegistrationReportsNoFailures() {
    #expect(FontRegistry.registerBundled(from: Self.fontsDir).isEmpty)
    #expect(FontRegistry.registerBundled(from: Self.fontsDir).isEmpty)  // already registered is not a failure
  }

  @Test func systemFallbackIsDetected() {
    FontRegistry.registerBundled(from: Self.fontsDir)
    let fallback = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    #expect(!TLFont.inter(.bold).matches(fallback))
    #expect(!TLFont.bodoni(italic: true, weight: 400).matches(fallback))
    #expect(TLFont.inter(.bold).matches(TLFont.inter(.bold).ctFont(size: 12)))
    // An unregistered/unknown PostScript name falls back to the system font; matches() sees it without asserting.
    let unknown = CTFontCreateWithName("Inter-Nonexistent" as CFString, 12, nil)
    #expect(!TLFont.inter(.bold).matches(unknown))
  }

  @Test func shaSumsMatch() throws {
    let sums = try String(contentsOf: Self.fontsDir / "SHA256SUMS", encoding: .utf8)
    let lines = sums.split(separator: "\n").map(String.init)
    #expect(lines.count == 8)
    for line in lines {
      // "<64 hex>  <name>", as `shasum -a 256` writes it.
      let parts = line.components(separatedBy: "  ")
      #expect(parts.count == 2, "malformed line: \(line)")
      guard parts.count == 2 else { continue }
      let data = try Data(contentsOf: Self.fontsDir / parts[1])
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      #expect(digest == parts[0], "\(parts[1]) does not match its pinned hash")
    }
  }

  @Test("Info.plist declares ATSApplicationFontsPath")
  func infoPlistDeclaresFontsPath() throws {
    let data = try Data(contentsOf: SourceScan.repoRoot / "App/Info.plist")
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    #expect(plist?["ATSApplicationFontsPath"] as? String == "Fonts")
  }
}
