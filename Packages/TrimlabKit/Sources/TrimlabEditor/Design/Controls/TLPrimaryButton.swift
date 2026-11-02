import SwiftUI

/// v1's primary button (§6.3), the only filled control on any screen: 40 px (36 in the sheet), radius 8, gold fill,
/// `--bg-0` text 13.5/600, the key hint (`⌘E`) in `--key-on-gold` 10 px after it. Hover `--gold-hover`, pressed
/// `--gold-press`. Disabled-looking is 35 % opacity and still shows its tip (the action is the caller's to refuse).
public struct TLPrimaryButton: View {
  let title: String
  let key: String?
  let height: CGFloat
  let looksDisabled: Bool
  let tip: String?
  let action: () -> Void

  public init(_ title: String, key: String? = nil, height: CGFloat = 40, looksDisabled: Bool = false,
              tip: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.key = key
    self.height = height
    self.looksDisabled = looksDisabled
    self.tip = tip
    self.action = action
  }

  public var body: some View {
    TLInteractive(shape: .rounded(8), label: title, tip: tip, tipPlacement: .above, isToggle: false,
                  value: nil, action: action) { state in
      HStack(spacing: 10) {
        Text(title)
          .font(.tl(.inter(.semibold), 13.5))
          .foregroundStyle(Tokens.bg0)
        if let key {
          Text(key)
            .font(.tl(.inter(.medium), 13.5))
            .foregroundStyle(Tokens.keyOnGold)
        }
      }
      .monospacedDigit()
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .background(fill(state), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .opacity(looksDisabled ? 0.35 : 1)
    }
  }

  private func fill(_ state: TLControlState) -> Color {
    if looksDisabled { return Tokens.brandGold }
    if state.pressed { return Tokens.goldPress }
    return state.hover ? Tokens.goldHover : Tokens.brandGold
  }
}
