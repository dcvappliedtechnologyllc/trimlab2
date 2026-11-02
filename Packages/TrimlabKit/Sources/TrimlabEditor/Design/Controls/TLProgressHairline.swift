import SwiftUI

/// v1's export bar (§4.9): a 2 px `--line` hairline, radius 1, with the gold run growing from the left to `progress`
/// (0...1), eased linearly over 200 ms; no motion under Reduce Motion.
public struct TLProgressHairline: View {
  let progress: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(progress: Double) { self.progress = progress }

  public static let height: CGFloat = 2

  public var body: some View {
    let p = min(max(progress, 0), 1)
    Capsule(style: .continuous)
      .fill(Tokens.line)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(Tokens.brandGold)
          .scaleEffect(x: p, y: 1, anchor: .leading)
          .animation(Tokens.Motion.progress(reduce: reduceMotion), value: p)
      }
      .clipShape(Capsule(style: .continuous))
      .frame(height: Self.height)
      .accessibilityElement()
      .accessibilityLabel("Export progress")
      .accessibilityValue("\(Int((p * 100).rounded(.down))) percent")
  }
}
