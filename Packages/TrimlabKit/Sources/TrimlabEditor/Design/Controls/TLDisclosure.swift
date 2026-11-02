import SwiftUI

/// A Details disclosure (§4.9 Error): a quiet row, a 10 px chevron in `--muted` that turns down when open, then the
/// title (Inter 13/500 `--text`); the content shows under it while open. One focus stop; Space or Return toggles.
public struct TLDisclosure<Content: View>: View {
  let title: String
  @Binding var isOpen: Bool
  let content: Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(_ title: String, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content) {
    self.title = title
    _isOpen = isOpen
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TLInteractive(shape: .rounded(6), label: title, tip: nil, tipPlacement: .above, isToggle: true,
                    value: isOpen ? "open" : "closed", action: { isOpen.toggle() }) { state in
        HStack(spacing: 6) {
          Chevron()
            .stroke(Tokens.muted, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .animation(Tokens.Motion.chevron(reduce: reduceMotion), value: isOpen)
          Text(title)
            .font(.tl(.inter(.medium), 13))
            .foregroundStyle(state.hover ? Tokens.brandInk : Tokens.text)
        }
        .frame(height: 24)
      }
      if isOpen { content }
    }
  }
}

/// A right-pointing chevron in a square.
private struct Chevron: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.2))
    p.addLine(to: CGPoint(x: r.minX + r.width * 0.7, y: r.midY))
    p.addLine(to: CGPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.8))
    return p
  }
}
