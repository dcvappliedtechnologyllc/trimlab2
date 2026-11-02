import Foundation
import SwiftUI
import Testing
@testable import TrimlabEditor

@Suite struct TokensTests {
  typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

  /// The colour SwiftUI actually resolves (sRGB, gamma-encoded), not Tokens' own table.
  func resolved(_ c: Color) -> RGBA {
    let r = c.resolve(in: EnvironmentValues())
    return (Double(r.red), Double(r.green), Double(r.blue), Double(r.opacity))
  }

  func rgba(hex: String) -> RGBA {
    let h = hex.dropFirst()
    let v = UInt32(h, radix: 16)!
    return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, 1)
  }

  func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> RGBA {
    (Double(r) / 255, Double(g) / 255, Double(b) / 255, a)
  }

  func expectClose(_ a: RGBA, _ b: RGBA, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let tol = 0.6 / 255
    #expect(abs(a.r - b.r) <= tol && abs(a.g - b.g) <= tol && abs(a.b - b.b) <= tol && abs(a.a - b.a) <= 0.005,
            "\(name): resolved \(a) != expected \(b)", sourceLocation: sourceLocation)
  }

  /// `--brand-ink` -> `brandInk`
  func camel(_ css: String) -> String {
    let parts = css.split(separator: "-").map(String.init)
    return parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
  }

  func brandCss() throws -> [(name: String, hex: String)] {
    let css = try String(contentsOf: SourceScan.repoRoot / "assets/brand.css", encoding: .utf8)
    let matches = css.matches(of: #/--([a-z0-9-]+):\s*(#[0-9A-Fa-f]{6})\s*;/#)
    return matches.map { (camel(String($0.1)), String($0.2)) }
  }

  /// Every token colour by name, as the real `Color` values.
  var colors: [String: Color] {
    [
      "brandInk": Tokens.brandInk, "brandGold": Tokens.brandGold, "brandSteel": Tokens.brandSteel,
      "brandCyan": Tokens.brandCyan, "bg0": Tokens.bg0, "bg1": Tokens.bg1, "bg2": Tokens.bg2,
      "line": Tokens.line, "text": Tokens.text, "muted": Tokens.muted, "ok": Tokens.ok,
      "warn": Tokens.warn, "err": Tokens.err,
      "goldHover": Tokens.goldHover, "goldPress": Tokens.goldPress, "goldGlow": Tokens.goldGlow,
      "goldHair": Tokens.goldHair, "guideDim": Tokens.guideDim, "deckOut": Tokens.deckOut,
      "scrim": Tokens.scrim, "wave": Tokens.wave, "tipBg": Tokens.tipBg,
      "keyOnGold": Tokens.keyOnGold, "select": Tokens.select,
    ]
  }

  @Test func brandCssTokensResolveToTheSameColours() throws {
    let tokens = try brandCss()
    #expect(tokens.count == 13, "brand.css parse found \(tokens.count) tokens")
    for (name, hex) in tokens {
      let color = try #require(colors[name], "no Tokens.\(name)")
      expectClose(resolved(color), rgba(hex: hex), name)
      #expect(Tokens.hex[name] == hex.uppercased(), "Tokens.hex[\(name)]")
    }
  }

  @Test func derivedTokensMatchV1Plan() {
    // Literal values from the v1 UI plan, independent of Tokens' table.
    expectClose(resolved(Tokens.goldHover), rgba(hex: "#D0B480"), "goldHover")
    expectClose(resolved(Tokens.goldPress), rgba(hex: "#B2955F"), "goldPress")
    expectClose(resolved(Tokens.goldGlow), rgba(201, 168, 106, 0.55), "goldGlow")
    expectClose(resolved(Tokens.goldHair), rgba(201, 168, 106, 0.85), "goldHair")
    expectClose(resolved(Tokens.guideDim), rgba(11, 12, 14, 0.40), "guideDim")
    expectClose(resolved(Tokens.deckOut), rgba(11, 12, 14, 0.70), "deckOut")
    expectClose(resolved(Tokens.scrim), rgba(11, 12, 14, 0.62), "scrim")
    expectClose(resolved(Tokens.keyOnGold), rgba(11, 12, 14, 0.55), "keyOnGold")
    expectClose(resolved(Tokens.select), rgba(201, 168, 106, 0.35), "select")
    expectClose(resolved(Tokens.wave), rgba(hex: "#D8DDE3"), "wave")
    expectClose(resolved(Tokens.tipBg), rgba(hex: "#20242A"), "tipBg")
    expectClose(resolved(Tokens.ivoryX), rgba(242, 237, 228, 0.7), "ivoryX")
    #expect(Tokens.hex["goldGlow"] == "rgba(201,168,106,.55)")
    #expect(Tokens.hex["deckOut"] == "rgba(11,12,14,.70)")
    #expect(Tokens.hex["guideDim"] == "rgba(11,12,14,.40)")
    #expect(Tokens.hex["scrim"] == "rgba(11,12,14,.62)")
    #expect(Tokens.hex["tipBg"] == "#20242A")
  }

  @Test func layoutAndMotionConstants() {
    typealias L = Tokens.Layout
    #expect([L.header, L.inspector, L.transport, L.strip, L.stripCap, L.stripTile, L.caption, L.deck,
             L.deckPad, L.bottomPad, L.minTile, L.tileGap, L.stagePad, L.narrowBreak]
      == [56, 300, 40, 80, 12, 56, 28, 122, 20, 8, 24, 2, 32, 1000])
    #expect(L.minWindow == CGSize(width: 900, height: 720))
    #expect([Tokens.Motion.sheetIn, Tokens.Motion.sheetOut, Tokens.Motion.savedRise, Tokens.Motion.knob]
      == [0.22, 0.18, 0.42, 0.14])
  }

  @Test func noColorLiteralsOutsideTokens() throws {
    let literal = #/\bColor\s*\(|\bColor\.init\s*\(|#colorLiteral|\bNSColor\b|\bUIColor\b|\bColor\.(red|green|blue|orange|yellow|pink|purple|brown|gray|grey|black|white|cyan|mint|teal|indigo|primary|secondary|accentColor)\b|[\s(,:=]\.(red|green|blue|orange|yellow|pink|purple|brown|gray|grey|black|white|cyan|mint|teal|indigo|accentColor)\b/#
    let files = SourceScan.swiftFiles(under: "Packages/TrimlabKit/Sources/TrimlabEditor")
    #expect(files.contains { $0.lastPathComponent == "Tokens.swift" })
    var hits: [String] = []
    for f in files where f.lastPathComponent != "Tokens.swift" {
      for (i, line) in SourceScan.lines(of: f).enumerated() where line.firstMatch(of: literal) != nil {
        hits.append("\(f.path):\(i + 1)")
      }
    }
    #expect(hits == [])
  }

  @Test func scannerCatchesPlantedColourLiteral() {
    let literal = #/\bColor\s*\(|\bColor\.(red|blue)\b/#
    #expect("let c = Color(red: 1)".firstMatch(of: literal) != nil)
    #expect("let c = Color.red".firstMatch(of: literal) != nil)
    #expect("let c = TLColor(x)".firstMatch(of: literal) == nil)
  }

  @Test func goldIsOnlyAccent() throws {
    let src = try String(contentsOf: SourceScan.repoRoot / "Packages/TrimlabKit/Sources/TrimlabEditor/Design/Tokens.swift", encoding: .utf8)
    let brand = Set(try brandCss().map { $0.hex.uppercased() })
    let derived: Set<String> = ["#D0B480", "#B2955F", "#20242A"]
    let hexes = Set(src.matches(of: #/#[0-9A-Fa-f]{6}\b/#).map { String($0.0).uppercased() })
    #expect(hexes.subtracting(brand).subtracting(derived).isEmpty, "unlisted hex: \(hexes.subtracting(brand).subtracting(derived))")
    // Every rgba is gold or bg-0 (or brand-ink for ivoryX-style mixes).
    let allowed: Set<String> = ["201,168,106", "11,12,14", "242,237,228"]
    for m in src.matches(of: #/rgba\((\d+),(\d+),(\d+),/#) {
      #expect(allowed.contains("\(m.1),\(m.2),\(m.3)"), "rgba(\(m.1),\(m.2),\(m.3)) is not gold/bg0/ink")
    }
    // The table and the resolved colours both cover the same names.
    #expect(Set(Tokens.hex.keys) == Set(colors.keys))
    // Cyan appears only as the brand token itself (DCV logo rule).
    #expect(Tokens.hex["brandCyan"] == "#5FA8C9")
  }
}
