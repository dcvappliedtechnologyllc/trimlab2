import SwiftUI

/// The outline a control's focus ring follows.
public enum TLFocusShape: Sendable, Equatable {
  case rounded(CGFloat)
  case circle

  /// The control's own outline (hit target and fills).
  var shape: AnyShape {
    switch self {
    case .rounded(let r): AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    case .circle: AnyShape(Circle())
    }
  }

  /// The same outline grown by `d` on every side, corners kept concentric.
  func grown(by d: CGFloat) -> AnyShape {
    switch self {
    case .rounded(let r): AnyShape(RoundedRectangle(cornerRadius: r + d, style: .continuous))
    case .circle: AnyShape(Circle())
    }
  }
}

/// v1's focus ring (§6.3): 2 px `--brand-gold`, 2 px outside the control, on keyboard focus only. Never a blue glow.
public struct TLFocusRing: View {
  public static let width: CGFloat = 2
  public static let offset: CGFloat = 2

  let shape: TLFocusShape

  public init(_ shape: TLFocusShape) { self.shape = shape }

  public var body: some View {
    // The stroke is centred on its path: the path sits offset + width/2 outside the control.
    let out = Self.offset + Self.width / 2
    shape.grown(by: out)
      .stroke(Tokens.brandGold, lineWidth: Self.width)
      .padding(-out)
      .allowsHitTesting(false)
  }
}

/// Where a control is in its life: what its look depends on.
public struct TLControlState: Equatable, Sendable {
  public var hover = false
  public var pressed = false
  public var focused = false
}

/// The behaviour every Design control shares: a click (press inside, release inside), Space or Return when it has
/// keyboard focus, the focus ring, the optional tooltip and the accessibility element. Every control is a focus stop
/// with "Keyboard navigation" off (`.focusable()`, §4.10); focus a click gives it draws no ring and takes no keys
/// (`TLPointerFocus`), so the ring means the keyboard is there. Under a `TLFocusLink` it follows the owner's focus id.
struct TLInteractive<Label: View>: View {
  let shape: TLFocusShape
  let label: String
  let tip: String?
  let tipPlacement: TLTipPlacement
  let isToggle: Bool
  let value: String?
  let action: () -> Void
  @ViewBuilder let content: (TLControlState) -> Label

  @FocusState private var focused: Bool
  @State private var hover = false
  @State private var pressed = false
  @State private var down = false
  @State private var pressedAt = Date.distantPast
  @State private var focusedAt = Date.distantPast
  @State private var size = CGSize.zero

  @Environment(\.tlFocusLink) private var link
  @Environment(\.tlControlID) private var controlID

  private var keyboard: Bool {
    TLPointerFocus.keyboard(focused: focused, linked: link.holds(controlID), ring: link?.ring ?? true,
                            focusedAt: focusedAt, pressedAt: pressedAt)
  }

  var body: some View {
    content(TLControlState(hover: hover, pressed: pressed, focused: keyboard))
      .contentShape(shape.shape)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
      .onHover { hover = $0 }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            if !down {
              down = true
              pressedAt = .now
            }
            pressed = CGRect(origin: .zero, size: size).contains(g.location)
          }
          .onEnded { g in
            down = false
            pressed = false
            if CGRect(origin: .zero, size: size).contains(g.location) { action() }
          }
      )
      .focusable()
      .focused($focused)
      .focusEffectDisabled()
      .onChange(of: focused) { _, now in if now { focusedAt = .now } }
      .tlFocusSync($focused, keyboard: keyboard)
      .onKeyPress(keys: [.space, .return]) { _ in
        guard keyboard else { return .ignored }
        action()
        return .handled
      }
      .overlay { if keyboard { TLFocusRing(shape) } }
      .tlTooltip(tip, placement: tipPlacement, focused: keyboard, suppressed: pressed)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityValue(value ?? "")
      .accessibilityAddTraits(isToggle ? [.isButton, .isToggle] : .isButton)
      .accessibilityAction(.default, action)
  }
}
