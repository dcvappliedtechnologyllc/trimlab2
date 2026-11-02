import SwiftUI

/// v1's secondary button (§6.3): 30 px, radius 7, 1 px `--line`, padding 0 × 12, Inter 13/500 `--text`; hover lifts
/// the edge to `--muted` and the text to `--brand-ink`. `.bare` drops the edge (a quiet text button: the
/// transport timecode, the header's Reel name).
public struct TLButton<Label: View>: View {
  public enum Style: Sendable { case hairline, bare }

  let style: Style
  let label: String
  let tip: String?
  let tipPlacement: TLTipPlacement
  let action: () -> Void
  let content: Label

  public init(style: Style = .hairline, label: String, tip: String? = nil, tipPlacement: TLTipPlacement = .above,
              action: @escaping () -> Void, @ViewBuilder content: () -> Label) {
    self.style = style
    self.label = label
    self.tip = tip
    self.tipPlacement = tipPlacement
    self.action = action
    self.content = content()
  }

  public var body: some View {
    TLInteractive(shape: .rounded(style == .bare ? 6 : 7), label: label, tip: tip, tipPlacement: tipPlacement,
                  isToggle: false, value: nil, action: action) { state in
      let lit = state.hover || state.pressed
      switch style {
      case .hairline:
        content
          .font(.tl(.inter(.medium), 13))
          .monospacedDigit()
          .foregroundStyle(lit ? Tokens.brandInk : Tokens.text)
          .lineLimit(1)
          .padding(.horizontal, 13)  // v1's 12 px inside its 1 px border (the edge here is drawn inside the frame)
          .frame(height: 30)
          .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(lit ? Tokens.muted : Tokens.line, lineWidth: 1))
      case .bare:
        content
      }
    }
  }
}

extension TLButton where Label == Text {
  /// A hairline button with a text label.
  public init(_ title: String, tip: String? = nil, tipPlacement: TLTipPlacement = .above,
              action: @escaping () -> Void) {
    self.init(style: .hairline, label: title, tip: tip, tipPlacement: tipPlacement, action: action) { Text(title) }
  }
}
