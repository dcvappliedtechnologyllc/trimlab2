import SwiftUI

/// v1's key cap (the key map's `.k`): at least 24 × 22, radius 5, `--bg-2` with a 1 px `--line` inset, Inter 12/500
/// `--text`, 6 px either side.
public struct TLKeyCap: View {
  let text: String

  public init(_ text: String) { self.text = text }

  public static let height: CGFloat = 22

  public var body: some View {
    Text(text)
      .font(.tl(.inter(.medium), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
      .frame(minWidth: 24, minHeight: Self.height, maxHeight: Self.height)
      .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
  }
}
