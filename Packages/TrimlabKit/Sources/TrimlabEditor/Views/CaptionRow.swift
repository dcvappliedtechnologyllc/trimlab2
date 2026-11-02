import SwiftUI
import TrimlabModel

/// §4.4. The 28 px row above the deck: "this clip". Left, the clip's name (13/500 `--text`), "clip 4 of 18" and,
/// with a multi-selection, "4 clips selected" (12 `--muted`), 16 px apart with no separator glyph; a one-clip Reel
/// shows only the name. Right, 16 px apart: Framing Fill | Fit (a primary that isn't 9:16, Reel format), Crossfade
/// in Cut | Short | Long (clip 2 on) and the deck's "− Zoom clip +". Each label is 12 `--muted`, 8 px before its
/// compact `TLSegmented`. The full-width hairline on top splits it from the strip. The view sits inside the bottom
/// block's 20 px side padding; the zoom's "+" reaches 6 px into it (14 px from the edge, under the transport's).
public struct CaptionRow: View {
  let model: EditorModel

  public init(model: EditorModel) { self.model = model }

  public var body: some View {
    HStack(spacing: 16) {
      if let c = model.caption {
        Text(c.name)
          .font(.tl(.inter(.medium), 13))
          .monospacedDigit()  // the mockup's body is tabular-nums: file names too
          .foregroundStyle(Tokens.text)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(1)
        if let position = c.position { meta(position) }
        if let selected = c.selected { meta(selected) }
        Spacer(minLength: 0)
        if let framing = c.framing {
          control("Framing") {
            TLSegmented(options: [(Framing.fill, "Fill"), (.fit, "Fit")], selection: framing, size: .compact,
                        label: "Framing", focusReset: model.focusResetToken, onSelect: model.captionSetFraming,
                        onFocusChange: { model.controlFocus(CaptionModel.framingControl, focused: $0) })
          }
        }
        if let join = c.join {
          control("Crossfade in") {
            TLSegmented(options: [(JoinChoice.cut, "Cut"), (.short, "Short"), (.long, "Long")], selection: join,
                        size: .compact, label: "Crossfade in", tip: c.joinTip, focusReset: model.focusResetToken,
                        onSelect: model.captionSetJoin,
                        onFocusChange: { model.controlFocus(CaptionModel.joinControl, focused: $0) })
          }
        }
      } else {
        Spacer(minLength: 0)
      }
      DeckZoomControl(model: model).padding(.trailing, -6)
    }
    .frame(height: Tokens.Layout.caption)
    .overlay(alignment: .top) {
      Rectangle().fill(Tokens.line).frame(height: 1).padding(.horizontal, -Tokens.Layout.deckPad)
    }
    .zIndex(1)  // the controls' tooltips hang above the row, over the strip
  }

  private func meta(_ text: String) -> some View {
    Text(text)
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.muted)
      .lineLimit(1)
      .fixedSize()
  }

  private func control(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.tl(.inter(.regular), 12))
        .foregroundStyle(Tokens.muted)
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)  // the control carries the same label
      content()
    }
  }
}
