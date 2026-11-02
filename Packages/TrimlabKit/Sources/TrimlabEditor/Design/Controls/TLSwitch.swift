import SwiftUI

/// v1's small switch row (§6.3): a 28 × 16 track (radius 8), then the label (Inter 13/500 `--text`) and the key
/// hint (12 `--muted`, right-aligned), 10 px apart, 32 px tall; the whole row is the hit target. Off: `--bg-2` with
/// a 1 px `--line` edge and a 12 px `--muted` knob. On: gold track, `--bg-0` knob 12 px to the right, sliding in
/// 140 ms (not at all under reduced motion). `compact` is the narrow inspector row's (v1): as wide as its label, 8 px
/// between track and label, 2 px either side, and no key hint.
public struct TLSwitch: View {
  let title: String
  let isOn: Bool
  let key: String?
  let tip: String?
  let compact: Bool
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(_ title: String, isOn: Bool, key: String? = nil, tip: String? = nil, compact: Bool = false,
              action: @escaping () -> Void) {
    self.title = title
    self.isOn = isOn
    self.key = key
    self.tip = tip
    self.compact = compact
    self.action = action
  }

  public static let track = CGSize(width: 28, height: 16)
  /// The row's height: v1's 32 px in the inspector, 30 in a sheet row (`.row .sw`).
  var height: CGFloat = 32

  /// The same switch at `height` px tall.
  public func rowHeight(_ height: CGFloat) -> TLSwitch {
    var copy = self
    copy.height = height
    return copy
  }
  static let knob: CGFloat = 12

  public var body: some View {
    TLInteractive(shape: .rounded(6), label: title, tip: tip, tipPlacement: .above, isToggle: true,
                  value: isOn ? "on" : "off", action: action) { _ in
      HStack(spacing: compact ? 8 : 10) {
        track
        Text(title)
          .font(.tl(.inter(.medium), 13))
          .foregroundStyle(Tokens.text)
          .lineLimit(1)
          .fixedSize(horizontal: compact, vertical: false)
          .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        if !compact, let key {
          Text(key)
            .font(.tl(.inter(.regular), 12))
            .foregroundStyle(Tokens.muted)
            .frame(minWidth: 12, alignment: .trailing)
        }
      }
      .padding(.horizontal, compact ? 2 : 0)
      .frame(height: height)
    }
  }

  private var track: some View {
    ZStack(alignment: .leading) {
      Capsule()
        .fill(isOn ? Tokens.brandGold : Tokens.bg2)
        .overlay(Capsule().strokeBorder(isOn ? .clear : Tokens.line, lineWidth: 1))
      Circle()
        .fill(isOn ? Tokens.bg0 : Tokens.muted)
        .frame(width: Self.knob, height: Self.knob)
        .offset(x: isOn ? Self.track.width - Self.knob - 2 : 2)
    }
    .frame(width: Self.track.width, height: Self.track.height)
    .animation(Tokens.Motion.knob(reduce: reduceMotion), value: isOn)
  }
}
