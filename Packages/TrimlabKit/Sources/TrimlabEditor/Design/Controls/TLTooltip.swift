import SwiftUI

/// Where a tooltip sits against its control: above (the default) or below (header controls), centred on it or
/// lined up with its leading or trailing edge (a control near the window's edge), or beside it (v1's in-sheet `.tip`:
/// 10 px to the right, vertically centred, 206 px wide and wrapping). The arrow always points at the control's centre.
public struct TLTipPlacement: Sendable, Equatable {
  public enum Edge: Sendable { case above, below, beside }
  public enum Align: Sendable { case center, leading, trailing }
  public var edge: Edge
  public var align: Align

  public init(_ edge: Edge = .above, align: Align = .center) {
    self.edge = edge
    self.align = align
  }

  public static let above = TLTipPlacement(.above)
  public static let below = TLTipPlacement(.below)
  public static let beside = TLTipPlacement(.beside)
}

/// v1's tooltip (§6.3): `--tip-bg`, 1 px `--line`, radius 6, padding 6 × 10, Inter 12/16 `--text`, at most 240 px
/// wide, a 5 px arrow in the same fill, 8 px from the control. Shows after 350 ms of hover, at once on keyboard
/// focus; a press hides it. No `.help()`.
public struct TLTooltip: View {
  public static let hoverDelay: Duration = .milliseconds(350)
  nonisolated static let gap: CGFloat = 8
  static let arrow: CGFloat = 5
  static let maxWidth: CGFloat = 240
  /// v1's `.tip` beside its control: 10 px off, 206 px wide (padding included).
  static let besideGap: CGFloat = 10
  static let besideWidth: CGFloat = 206

  let text: String
  let edge: TLTipPlacement.Edge
  /// The arrow's centre, from the bubble's leading edge; nil centres it.
  let arrowX: CGFloat?

  public init(_ text: String, edge: TLTipPlacement.Edge = .above, arrowX: CGFloat? = nil) {
    self.text = text
    self.edge = edge
    self.arrowX = arrowX
  }

  public var body: some View {
    if edge == .beside { beside } else { floating }
  }

  /// Beside the control: wraps at 206 px, the arrow on the left, pointing at the control's middle.
  private var beside: some View {
    Text(text)
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .lineSpacing(16 - 14.5)  // 16 px lines (Inter 12's natural line is 14.5)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: Self.besideWidth - 20, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Tokens.tipBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
      .overlay(alignment: .leading) {
        TipArrowLeft()
          .fill(Tokens.tipBg)
          .frame(width: Self.arrow, height: Self.arrow * 2)
          .offset(x: -Self.arrow)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var floating: some View {
    Text(text)
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .lineLimit(1)
      .frame(height: 16)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: Self.maxWidth)
      .background(Tokens.tipBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
      .overlay(alignment: edge == .above ? .bottomLeading : .topLeading) {
        GeometryReader { g in
          TipArrow(pointsDown: edge == .above)
            .fill(Tokens.tipBg)
            .frame(width: Self.arrow * 2, height: Self.arrow)
            .offset(x: (arrowX ?? g.size.width / 2) - Self.arrow, y: edge == .above ? g.size.height : -Self.arrow)
        }
      }
      .fixedSize()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct TipArrowLeft: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.midY))
    p.closeSubpath()
    return p
  }
}

private struct TipArrow: Shape {
  let pointsDown: Bool
  func path(in r: CGRect) -> Path {
    var p = Path()
    if pointsDown {
      p.move(to: CGPoint(x: r.minX, y: r.minY))
      p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
      p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
    } else {
      p.move(to: CGPoint(x: r.minX, y: r.maxY))
      p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
      p.addLine(to: CGPoint(x: r.midX, y: r.minY))
    }
    p.closeSubpath()
    return p
  }
}

/// Hover timing and placement for `tlTooltip`.
struct TLTooltipModifier: ViewModifier {
  let text: String?
  let placement: TLTipPlacement
  let focused: Bool
  let suppressed: Bool

  @State private var hover = false
  @State private var hoverShown = false
  @Environment(\.tlStillRender) private var still
  @Environment(\.tlStillHover) private var stillHover
  @Environment(\.tlControlID) private var controlID
  @State private var controlWidth: CGFloat = 0
  @State private var bubbleWidth: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onHover { hover = $0 }
      .task(id: hover) {
        hoverShown = false
        guard hover else { return }
        try? await Task.sleep(for: TLTooltip.hoverDelay)
        if !Task.isCancelled { hoverShown = true }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlWidth = $0 }
      .overlay(alignment: alignment) {
        if let text, (hoverShown || focused || stillHovered), !suppressed, placement.edge == .beside {
          // An offset, not an alignment guide: the bubble's leading edge 10 px past the control's trailing one.
          TLTooltip(text, edge: .beside)
            .fixedSize(horizontal: true, vertical: true)
            .offset(x: controlWidth + TLTooltip.besideGap)
        } else if let text, (hoverShown || focused || stillHovered), !suppressed {
          TLTooltip(text, edge: placement.edge, arrowX: arrowX)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bubbleWidth = $0 }
            .alignmentGuide(placement.edge == .above ? .top : .bottom) { d in
              placement.edge == .above ? d[.bottom] + TLTooltip.gap : d[.top] - TLTooltip.gap
            }
        }
      }
      .zIndex(hoverShown || focused || stillHovered ? 10 : 0)
  }

  /// A still's stand-in for hover (`tlStillHover`).
  private var stillHovered: Bool { still && stillHover != nil && stillHover == controlID }

  private var alignment: Alignment {
    switch (placement.edge, placement.align) {
    case (.above, .center): .top
    case (.above, .leading): .topLeading
    case (.above, .trailing): .topTrailing
    case (.below, .center): .bottom
    case (.below, .leading): .bottomLeading
    case (.below, .trailing): .bottomTrailing
    case (.beside, _): .leading
    }
  }

  private var arrowX: CGFloat? {
    switch placement.align {
    case .center: nil
    case .leading: controlWidth / 2
    case .trailing: bubbleWidth - controlWidth / 2
    }
  }
}

extension View {
  /// The v1 tooltip on this view. `focused` shows it at once (keyboard focus); `suppressed` hides it (a press).
  public func tlTooltip(_ text: String?, placement: TLTipPlacement = .above, focused: Bool = false,
                        suppressed: Bool = false) -> some View {
    modifier(TLTooltipModifier(text: text, placement: placement, focused: focused, suppressed: suppressed))
  }
}
