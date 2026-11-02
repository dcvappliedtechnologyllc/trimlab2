import SwiftUI

/// v1's segmented control (§6.3): a `--bg-0` well with a 1 px `--line` inset and 2 px inner padding; the chosen
/// segment is `--bg-2` with its own 1 px `--line` inset and `--brand-ink` text, the others `--muted` (hover
/// `--text`). `.regular` is the sheet's 28 px well with 90 px segments (Inter 13/500, radius 7, inner 5);
/// `.compact` the caption's 22 px well with 52 px segments (Inter 12/500, radius 6, inner 4).
///
/// One focus stop for the whole well, as a radio group, reachable with "Keyboard navigation" off (§4.10): a click picks
/// a segment, and any focus it gives the well isn't keyboard focus (no ring, no arrows, `TLPointerFocus`); with
/// keyboard focus (the 2 px gold ring) ← / → pick the neighbour, stopping at either end. `onFocusChange` tells the owner when
/// focus comes and goes, so the key monitor can leave those arrows to it (`EditorModel.controlFocus`); a change of
/// `focusReset` (a press elsewhere in the window) takes the focus away. Picking the chosen segment again still calls
/// `onSelect`: the owner decides whether that does anything (Framing unifies a mixed selection).
///
/// A value in `disabled` shows at 35 % with its reason as the segment's tooltip (on hover, and while the well has
/// keyboard focus); it can't be picked by click or arrow (the export sheet's Quick, §4.9).
public struct TLSegmented<T: Hashable>: View {
  public enum Size: Sendable { case regular, compact }

  let options: [(T, String)]
  let selection: T
  let size: Size
  let label: String
  let tip: String?
  let tipPlacement: TLTipPlacement
  let focusReset: Int
  let disabled: [T: String]
  let onSelect: (T) -> Void
  let onFocusChange: (Bool) -> Void

  @FocusState private var focused: Bool
  @State private var pressedAt = Date.distantPast
  @State private var focusedAt = Date.distantPast
  @State private var down = false

  @Environment(\.tlFocusLink) private var link
  @Environment(\.tlControlID) private var controlID

  private var keyboard: Bool {
    TLPointerFocus.keyboard(focused: focused, linked: link.holds(controlID), ring: link?.ring ?? true,
                            focusedAt: focusedAt, pressedAt: pressedAt)
  }

  public init(options: [(T, String)], selection: T, size: Size = .regular, label: String = "", tip: String? = nil,
              tipPlacement: TLTipPlacement = .above, focusReset: Int = 0, disabled: [T: String] = [:],
              onSelect: @escaping (T) -> Void,
              onFocusChange: @escaping (Bool) -> Void = { _ in }) {
    self.options = options
    self.selection = selection
    self.size = size
    self.label = label
    self.tip = tip
    self.tipPlacement = tipPlacement
    self.focusReset = focusReset
    self.disabled = disabled
    self.onSelect = onSelect
    self.onFocusChange = onFocusChange
  }

  /// The well's height, a segment's width, the outer and inner radii and the type size.
  public var height: CGFloat { size == .regular ? 28 : 22 }
  var segment: CGFloat { size == .regular ? 90 : 52 }
  var radius: CGFloat { size == .regular ? 7 : 6 }
  var inner: CGFloat { size == .regular ? 5 : 4 }
  var fontSize: CGFloat { size == .regular ? 13 : 12 }
  static var padding: CGFloat { 2 }

  /// The value `d` places from `value` in `values`, or nil past either end (or for a value not in the list).
  public static func neighbour(of value: T, in values: [T], by d: Int) -> T? {
    guard let i = values.firstIndex(of: value), values.indices.contains(i + d) else { return nil }
    return values[i + d]
  }

  public var body: some View {
    HStack(spacing: 0) {
      ForEach(options.indices, id: \.self) { i in
        let value = options[i].0
        Segment(title: options[i].1, chosen: value == selection, width: segment, inner: inner,
                fontSize: fontSize, disabledTip: disabled[value], wellFocused: keyboard) { onSelect(value) }
      }
    }
    .padding(Self.padding)
    .frame(height: height)
    .background(Tokens.bg0, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          if !down {
            down = true
            pressedAt = .now
          }
        }
        .onEnded { _ in down = false }
    )
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onChange(of: focused) { _, now in if now { focusedAt = .now } }
    .tlFocusSync($focused, keyboard: keyboard)
    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
      guard press.modifiers.isEmpty, keyboard else { return .ignored }
      step(press.key == .leftArrow ? -1 : 1)
      return .handled
    }
    .onChange(of: keyboard) { _, now in onFocusChange(now) }
    .onChange(of: focusReset) { focused = false }
    .onDisappear { if keyboard { onFocusChange(false) } }
    .overlay { if keyboard { TLFocusRing(.rounded(radius)) } }
    .tlTooltip(tip, placement: tipPlacement, focused: keyboard)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: step(1)
      case .decrement: step(-1)
      @unknown default: break
      }
    }
  }

  private func step(_ d: Int) {
    let open = options.map(\.0).filter { disabled[$0] == nil || $0 == selection }
    if let next = Self.neighbour(of: selection, in: open, by: d) { onSelect(next) }
  }
}

/// One segment: a press inside, released inside, picks it (as `TLInteractive`, without a focus stop of its own).
private struct Segment: View {
  let title: String
  let chosen: Bool
  let width: CGFloat
  let inner: CGFloat
  let fontSize: CGFloat
  let disabledTip: String?
  let wellFocused: Bool
  let action: () -> Void

  @State private var hover = false
  @State private var size = CGSize.zero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: inner, style: .continuous)
    Text(title)
      .font(.tl(.inter(.medium), fontSize))
      .foregroundStyle(chosen ? Tokens.brandInk : hover && disabledTip == nil ? Tokens.text : Tokens.muted)
      .lineLimit(1)
      .frame(width: width)
      .frame(maxHeight: .infinity)
      .background { if chosen { shape.fill(Tokens.bg2) } }
      .overlay { if chosen { shape.strokeBorder(Tokens.line, lineWidth: 1) } }
      .opacity(disabledTip == nil ? 1 : 0.35)
      .animation(Tokens.Motion.hover(reduce: reduceMotion), value: hover)
      .contentShape(shape)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
      .onHover { hover = $0 }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onEnded { g in
            if disabledTip == nil, CGRect(origin: .zero, size: size).contains(g.location) { action() }
          }
      )
      .tlTooltip(disabledTip, placement: .beside, focused: wellFocused)  // v1's in-sheet tip, right of the segment
  }
}
