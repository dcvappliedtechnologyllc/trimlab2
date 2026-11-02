import SwiftUI

/// §4.3.1 / §4.3.6. Over 3:00: everything in the tile row past 3:00 dimmed with `--deck-out`, a 1 px `--warn` line
/// from the top of the cap row to the bottom of the tiles, and "3:00" in 11 px `--warn` just left of it in the cap row.
enum ThreeMinuteMarker {
  static func draw(in ctx: inout GraphicsContext, at x: CGFloat, contentEnd: CGFloat, size: CGSize) {
    let lx = x.rounded()
    let top = Tokens.Layout.stripCap, h = Tokens.Layout.stripTile
    let end = min(contentEnd, size.width)
    if end > lx { ctx.fill(Path(CGRect(x: lx, y: top, width: end - lx, height: h)), with: .color(Tokens.deckOut)) }
    ctx.fill(Path(CGRect(x: lx, y: 0, width: 1, height: top + h)), with: .color(Tokens.warn))
    let label = ctx.resolve(Text("3:00").font(.tl(.inter(.medium), 11)).monospacedDigit().foregroundStyle(Tokens.warn))
    ctx.draw(label, at: CGPoint(x: lx - 4, y: top / 2), anchor: .trailing)
  }
}
