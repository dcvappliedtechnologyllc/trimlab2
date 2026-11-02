import SwiftUI

/// §4.3.3. The reorder / Finder-drop caret: 2 px gold in the gap, 4 px proud of the tile row top and bottom.
/// Neighbours never slide; this is the only thing that moves.
enum DropCaret {
  static func draw(in ctx: inout GraphicsContext, gap: Int, layout: StripLayout) {
    guard let x = centre(gap: gap, layout: layout) else { return }
    let top = Tokens.Layout.stripCap, h = Tokens.Layout.stripTile
    ctx.fill(Path(CGRect(x: x, y: top - 4, width: 2, height: h + 8)), with: .color(Tokens.brandGold))
  }

  /// The caret's left edge for gap `gap` (before tile `gap`), nil without tiles.
  static func centre(gap: Int, layout: StripLayout) -> CGFloat? {
    let tiles = layout.tiles
    guard !tiles.isEmpty else { return nil }
    let g = min(max(gap, 0), tiles.count)
    if g == 0 { return (tiles[0].rect.minX - Tokens.Layout.tileGap / 2).rounded() - 1 }
    return (tiles[g - 1].rect.maxX + Tokens.Layout.tileGap / 2).rounded() - 1
  }
}
