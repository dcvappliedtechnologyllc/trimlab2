import SwiftUI

/// §4.3.1. A crossfade's mark: a thin ivory ╳ at 70 % across the overlap (at least 10 px wide), 14 px inside the
/// tile row top and bottom.
enum JoinMark {
  static func draw(in ctx: inout GraphicsContext, over tile: StripLayout.Tile) {
    let w = max(10, tile.overlapLeft)
    let x0 = tile.rect.minX + tile.overlapLeft / 2 - w / 2
    let y0 = tile.rect.minY + 14, y1 = tile.rect.maxY - 14
    var p = Path()
    p.move(to: CGPoint(x: x0, y: y0))
    p.addLine(to: CGPoint(x: x0 + w, y: y1))
    p.move(to: CGPoint(x: x0 + w, y: y0))
    p.addLine(to: CGPoint(x: x0, y: y1))
    ctx.stroke(p, with: .color(Tokens.ivoryX), lineWidth: 1)
  }
}
