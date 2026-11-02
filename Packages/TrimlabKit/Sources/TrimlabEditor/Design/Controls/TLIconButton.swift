import SwiftUI

/// The mockup's icon glyphs, drawn from its 16 × 16 SVG paths.
public enum TLGlyph: Sendable, Equatable {
  case back, play, pause, forward, minus, plus
  /// A text glyph (the header's `?`).
  case text(String)
}

/// v1's icon button (§6.3): 30 × 30, radius 7, no border, 16 px glyph in `--muted`; hover fills `--bg-2` and lifts
/// the glyph to `--text`. `.play` is 34 × 34 with a `--text` glyph; `.small` is 24 × 24, radius 6, 14 px glyph
/// (the caption row); `.ring` is the header's 26 px hairline circle (v1 `#help`).
public struct TLIconButton: View {
  public enum Size: Sendable { case regular, play, small, ring }

  let glyph: TLGlyph
  let size: Size
  let label: String
  let tip: String?
  let tipPlacement: TLTipPlacement
  let action: () -> Void

  public init(_ glyph: TLGlyph, size: Size = .regular, label: String, tip: String? = nil,
              tipPlacement: TLTipPlacement = .above, action: @escaping () -> Void) {
    self.glyph = glyph
    self.size = size
    self.label = label
    self.tip = tip
    self.tipPlacement = tipPlacement
    self.action = action
  }

  var side: CGFloat {
    switch size {
    case .regular: 30
    case .play: 34
    case .small: 24
    case .ring: 26
    }
  }

  private var glyphSide: CGFloat { size == .small ? 14 : 16 }

  private var focusShape: TLFocusShape {
    switch size {
    case .ring: .circle
    case .small: .rounded(6)
    default: .rounded(7)
    }
  }

  public var body: some View {
    TLInteractive(shape: focusShape, label: label, tip: tip, tipPlacement: tipPlacement, isToggle: false,
                  value: nil, action: action) { state in
      face(state)
    }
  }

  @ViewBuilder private func face(_ state: TLControlState) -> some View {
    let lit = state.hover || state.pressed
    let ink = size == .play || lit ? Tokens.text : Tokens.muted
    ZStack {
      switch size {
      case .ring:
        Circle().strokeBorder(lit ? Tokens.muted : Tokens.line, lineWidth: 1)
      default:
        focusShape.shape.fill(lit && size != .play ? Tokens.bg2 : .clear)
      }
      GlyphView(glyph: glyph, side: glyphSide).foregroundStyle(ink)
    }
    .frame(width: side, height: side)
  }
}

/// A glyph at `side` points (the SVGs' 16-unit box scaled).
struct GlyphView: View {
  let glyph: TLGlyph
  let side: CGFloat

  var body: some View {
    switch glyph {
    case .text(let s):
      Text(s).font(.tl(.inter(.semibold), 13))
    case .minus, .plus:
      GlyphShape(glyph: glyph)
        .stroke(style: StrokeStyle(lineWidth: 1.5 * side / 16, lineCap: .round))
        .frame(width: side, height: side)
    default:
      GlyphShape(glyph: glyph).fill().frame(width: side, height: side)
    }
  }
}

struct GlyphShape: Shape {
  let glyph: TLGlyph

  func path(in rect: CGRect) -> Path {
    let k = min(rect.width, rect.height) / 16
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
    var p = Path()
    func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
      p.move(to: a)
      p.addLine(to: b)
      p.addLine(to: c)
      p.closeSubpath()
    }
    switch glyph {
    case .back:  // M7.5 3.5v9L1.5 8z  M14.5 3.5v9L8.5 8z
      triangle(pt(7.5, 3.5), pt(7.5, 12.5), pt(1.5, 8))
      triangle(pt(14.5, 3.5), pt(14.5, 12.5), pt(8.5, 8))
    case .forward:  // M1.5 3.5v9L7.5 8z  M8.5 3.5v9L14.5 8z
      triangle(pt(1.5, 3.5), pt(1.5, 12.5), pt(7.5, 8))
      triangle(pt(8.5, 3.5), pt(8.5, 12.5), pt(14.5, 8))
    case .play:  // M4.5 2.8v10.4c0 .5.5.8.9.5l8-5.2a.6.6 0 0 0 0-1L5.4 2.3c-.4-.3-.9 0-.9.5z
      p.move(to: pt(4.5, 2.8))
      p.addLine(to: pt(4.5, 13.2))
      p.addCurve(to: pt(5.4, 13.7), control1: pt(4.5, 13.7), control2: pt(5.0, 14.0))
      p.addLine(to: pt(13.4, 8.5))
      p.addCurve(to: pt(13.4, 7.5), control1: pt(13.75, 8.27), control2: pt(13.75, 7.73))
      p.addLine(to: pt(5.4, 2.3))
      p.addCurve(to: pt(4.5, 2.8), control1: pt(5.0, 2.0), control2: pt(4.5, 2.3))
      p.closeSubpath()
    case .pause:
      p.addRoundedRect(in: CGRect(origin: pt(4, 3), size: CGSize(width: 2.8 * k, height: 10 * k)),
                       cornerSize: CGSize(width: 0.7 * k, height: 0.7 * k))
      p.addRoundedRect(in: CGRect(origin: pt(9.2, 3), size: CGSize(width: 2.8 * k, height: 10 * k)),
                       cornerSize: CGSize(width: 0.7 * k, height: 0.7 * k))
    case .minus:  // M3.5 8h9
      p.move(to: pt(3.5, 8))
      p.addLine(to: pt(12.5, 8))
    case .plus:  // M3.5 8h9M8 3.5v9
      p.move(to: pt(3.5, 8))
      p.addLine(to: pt(12.5, 8))
      p.move(to: pt(8, 3.5))
      p.addLine(to: pt(8, 12.5))
    case .text:
      break
    }
    return p
  }
}
