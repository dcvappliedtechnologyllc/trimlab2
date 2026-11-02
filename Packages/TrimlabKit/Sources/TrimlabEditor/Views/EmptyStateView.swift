import SwiftUI

/// v1's empty screen (SPEC §6.2): "Drop clips." in Bodoni Moda italic 64/72 ivory, "or press ⌘O" in Inter 13/18
/// `--muted`, 8 px apart, centred on the stage.
public struct EmptyStateView: View {
  public init() {}

  public var body: some View {
    VStack(spacing: 8) {
      Text("Drop clips.")
        .font(.tl(.bodoni(italic: true, weight: 400), 64))
        .tracking(-0.005 * 64)
        .foregroundStyle(Tokens.brandInk)
        .frame(height: 72)
      Text("or press ⌘O")
        .font(.tl(.inter(.regular), 13))
        .foregroundStyle(Tokens.muted)
        .frame(height: 18)
    }
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}
