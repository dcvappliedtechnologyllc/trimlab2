import SwiftUI

/// v1's Save to row (§4.9): a 30 px `--bg-0` well (radius 7, 1 px `--line`) with a 14 px folder glyph in `--muted`
/// and the folder's plain name (Inter 13/500 `--text`, cut short with an ellipsis), then Choose… 8 px to its right.
public struct TLFolderWell: View {
  let name: String
  let onChoose: () -> Void

  public init(name: String, onChoose: @escaping () -> Void) {
    self.name = name
    self.onChoose = onChoose
  }

  public var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        FolderGlyph()
          .stroke(Tokens.muted, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
          .frame(width: 14, height: 14)
        Text(name)
          .font(.tl(.inter(.medium), 13))
          .foregroundStyle(Tokens.text)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(Tokens.bg0, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Save to \(name)")
      TLButton("Choose…", action: onChoose)
    }
  }
}

/// v1's folder icon (16-unit box): a tab on the left, the body below it.
private struct FolderGlyph: Shape {
  func path(in r: CGRect) -> Path {
    let k = r.width / 16
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
    var path = Path()
    path.move(to: p(1.8, 4.2))
    path.addQuadCurve(to: p(3, 3), control: p(1.8, 3))
    path.addLine(to: p(6, 3))
    path.addLine(to: p(7.5, 4.6))
    path.addLine(to: p(13, 4.6))
    path.addQuadCurve(to: p(14.2, 5.8), control: p(14.2, 4.6))
    path.addLine(to: p(14.2, 11.8))
    path.addQuadCurve(to: p(13, 13), control: p(14.2, 13))
    path.addLine(to: p(3, 13))
    path.addQuadCurve(to: p(1.8, 11.8), control: p(1.8, 13))
    path.closeSubpath()
    return path
  }
}
