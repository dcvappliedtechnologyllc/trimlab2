import CoreGraphics
import Foundation
import SwiftUI

/// Design tokens: `assets/brand.css` verbatim plus the v1 UI plan's derived tokens (SPEC §6.1).
/// Gold `#C9A86A` is the only accent; DCV cyan appears only in the DCV logo's rule.
/// The `hex` table is the single source of truth; every `Color` is built from it.
public enum Tokens {
  /// name -> `#RRGGBB` or `rgba(r,g,b,.a)`.
  public static let hex: [String: String] = [
    // brand.css
    "brandInk": "#F2EDE4", "brandGold": "#C9A86A", "brandSteel": "#D8DDE3", "brandCyan": "#5FA8C9",
    "bg0": "#0B0C0E", "bg1": "#14161A", "bg2": "#1C1F25", "line": "#2A2E36",
    "text": "#E6E6E6", "muted": "#8A9099", "ok": "#6FCF97", "warn": "#F2C94C", "err": "#EB5757",
    // derived
    "goldHover": "#D0B480", "goldPress": "#B2955F",
    "goldGlow": "rgba(201,168,106,.55)", "goldHair": "rgba(201,168,106,.85)",
    "guideDim": "rgba(11,12,14,.40)", "deckOut": "rgba(11,12,14,.70)", "scrim": "rgba(11,12,14,.62)",
    "wave": "#D8DDE3", "tipBg": "#20242A", "keyOnGold": "rgba(11,12,14,.55)",
    "select": "rgba(201,168,106,.35)",
  ]

  /// sRGB `Color` for a table entry.
  private static func color(_ name: String) -> Color {
    guard let spec = hex[name], let (r, g, b, a) = components(spec) else {
      preconditionFailure("Tokens.hex[\(name)] is missing or malformed")
    }
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  private static func components(_ spec: String) -> (Double, Double, Double, Double)? {
    if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
      return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, 1)
    }
    if spec.hasPrefix("rgba("), spec.hasSuffix(")") {
      let p = spec.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0) }
      if p.count == 4 { return (p[0] / 255, p[1] / 255, p[2] / 255, p[3]) }
    }
    return nil
  }

  // brand.css
  public static let brandInk = color("brandInk")
  public static let brandGold = color("brandGold")
  public static let brandSteel = color("brandSteel")
  public static let brandCyan = color("brandCyan")
  public static let bg0 = color("bg0")
  public static let bg1 = color("bg1")
  public static let bg2 = color("bg2")
  public static let line = color("line")
  public static let text = color("text")
  public static let muted = color("muted")
  public static let ok = color("ok")
  public static let warn = color("warn")
  public static let err = color("err")

  // derived
  public static let goldHover = color("goldHover")
  public static let goldPress = color("goldPress")
  public static let goldGlow = color("goldGlow")
  public static let goldHair = color("goldHair")
  public static let guideDim = color("guideDim")
  public static let deckOut = color("deckOut")
  public static let scrim = color("scrim")
  public static let wave = color("wave")
  public static let tipBg = color("tipBg")
  public static let keyOnGold = color("keyOnGold")
  public static let select = color("select")
  /// Ivory at 70 % (JoinMark).
  public static let ivoryX = brandInk.opacity(0.7)

  public enum Layout {
    public static let header: CGFloat = 56
    public static let inspector: CGFloat = 300
    public static let transport: CGFloat = 40
    public static let strip: CGFloat = 80
    public static let stripCap: CGFloat = 12
    public static let stripTile: CGFloat = 56
    public static let caption: CGFloat = 28
    public static let deck: CGFloat = 122
    public static let deckPad: CGFloat = 20
    public static let bottomPad: CGFloat = 8
    public static let minTile: CGFloat = 24
    public static let tileGap: CGFloat = 2
    public static let stagePad: CGFloat = 32
    public static let narrowBreak: CGFloat = 1000
    public static let minWindow = CGSize(width: 900, height: 720)
    /// The reorder ghost (§4.3.3, mockup): at most this wide, lifted this far above the tile row.
    public static let ghostMaxWidth: CGFloat = 96
    public static let ghostLift: CGFloat = 6
    /// v1's armed hairline frame while Finder files are over the window: inset and corner radius.
    public static let dropFrameInset: CGFloat = 6
    public static let dropFrameRadius: CGFloat = 10
  }

  /// The reorder ghost's opacity (§4.3.3).
  public static let ghostOpacity: Double = 0.8

  /// §6.0's motion, the only things that move: the sheet (220 ms ease-out in, 180 ms out, the scrim with it),
  /// "Saved." (420 ms), switch knobs (140 ms), and the hover colour of a few controls. Each animation is nil under
  /// Reduce Motion (§4.11), so a view passes `reduce` from `accessibilityReduceMotion` and gets no transition at all.
  public enum Motion {
    public static let sheetIn: Double = 0.22
    public static let sheetOut: Double = 0.18
    public static let savedRise: Double = 0.42
    public static let knob: Double = 0.14
    public static let hoverFade: Double = 0.12
    public static let chevronTurn: Double = 0.14
    public static let progressStep: Double = 0.2

    /// v1's ease-out curve.
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }

    /// (Not `sheet(…)`: the source scan reads `.sheet(` as SwiftUI's sheet.)
    public static func sheetSlide(reduce: Bool, opening: Bool = true) -> Animation? {
      reduce ? nil : easeOut(opening ? sheetIn : sheetOut)
    }
    public static func knob(reduce: Bool) -> Animation? { reduce ? nil : easeOut(knob) }
    public static func saved(reduce: Bool) -> Animation? { reduce ? nil : easeOut(savedRise) }
    public static func hover(reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: hoverFade) }
    public static func chevron(reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: chevronTurn) }
    public static func progress(reduce: Bool) -> Animation? { reduce ? nil : .linear(duration: progressStep) }
  }
}
