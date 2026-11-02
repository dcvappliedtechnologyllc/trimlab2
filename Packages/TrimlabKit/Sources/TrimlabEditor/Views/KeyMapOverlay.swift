import SwiftUI
import TrimlabModel

/// `?` (§4.7, §4.10): v1's key map, every §4.7 row from `KeyMap.rows` in two columns, over a scrim that covers the
/// window (a click on it closes the map). The panel is `--bg-1`, radius 12, 1 px `--line`, 22 / 28 / 24 inside;
/// "Key map" 15/600 `--brand-ink` with Close on the right; each row is the keys in `TLKeyCap`s, then what they do in
/// Inter 13 `--text`, at least 30 px tall, set apart by space alone. It doesn't move in or out (§6.0).
public struct KeyMapOverlay: View {
  /// One line of the map: the chords of one §4.7 row, their caps and the row's words.
  public struct Line: Equatable, Sendable {
    public var chords: [KeyChord]
    public var caps: [String]
    public var text: String
  }

  let model: EditorModel

  public init(model: EditorModel) { self.model = model }

  /// `KeyMap.rows` with the chords that share a row's words on one line, in the table's order.
  public static let lines: [Line] = {
    var out: [Line] = []
    for (chord, _, text) in KeyMap.rows {
      if let last = out.last, last.text == text {
        out[out.count - 1].chords.append(chord)
        out[out.count - 1].caps.append(chord.display)
      } else {
        out.append(Line(chords: [chord], caps: [chord.display], text: text))
      }
    }
    return out
  }()

  /// The lines split in two, the first column taking the odd one.
  public static var columns: ([Line], [Line]) {
    let half = (lines.count + 1) / 2
    return (Array(lines[..<half]), Array(lines[half...]))
  }

  static let panelWidth: CGFloat = 860
  static let keysWidth: CGFloat = 120
  static let columnGap: CGFloat = 32

  public var body: some View {
    ZStack {
      Tokens.scrim
        .contentShape(Rectangle())
        .onTapGesture { model.closeKeyMap() }
        .accessibilityHidden(true)
      panel
        .padding(32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var panel: some View {
    let (left, right) = Self.columns
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Text("Key map")
          .font(.tl(.inter(.semibold), 15))
          .foregroundStyle(Tokens.brandInk)
          .frame(maxWidth: .infinity, alignment: .leading)
        TLButton("Close", action: model.closeKeyMap)
          .tlFocusID(EditorModel.keyMapClose)
      }
      .padding(.bottom, 12)
      HStack(alignment: .top, spacing: Self.columnGap) {
        column(left)
        column(right)
      }
    }
    .padding(EdgeInsets(top: 22, leading: 28, bottom: 24, trailing: 28))
    .frame(maxWidth: Self.panelWidth)
    .background(Tokens.bg1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onTapGesture {}  // a click on the panel isn't a click on the scrim
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Key map")
    .accessibilityAddTraits(.isModal)
  }

  private func column(_ lines: [Line]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        row(line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func row(_ line: Line) -> some View {
    HStack(alignment: .center, spacing: 12) {
      CapFlow(spacing: 4) {
        ForEach(Array(line.caps.enumerated()), id: \.offset) { _, cap in TLKeyCap(cap) }
      }
      .frame(width: Self.keysWidth, alignment: .leading)
      Text(line.text)
        .font(.tl(.inter(.regular), 13))
        .monospacedDigit()
        .foregroundStyle(Tokens.text)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)  // rows sit apart on space alone: no rule between them (critique, Task 38)
    .frame(minHeight: 30)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(line.caps.joined(separator: ", ")): \(line.text)")
  }
}

/// Caps left to right, wrapping onto the next line when they don't fit (Home End ⇧Home ⇧End).
private struct CapFlow: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let (frames, size) = arrange(subviews, width: proposal.width ?? .infinity)
    _ = frames
    return size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (frames, _) = arrange(subviews, width: bounds.width)
    for (view, frame) in zip(subviews, frames) {
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> ([CGRect], CGSize) {
    var frames: [CGRect] = []
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + spacing
        lineHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      widest = max(widest, x - spacing)
      lineHeight = max(lineHeight, size.height)
    }
    return (frames, CGSize(width: widest, height: y + lineHeight))
  }
}
