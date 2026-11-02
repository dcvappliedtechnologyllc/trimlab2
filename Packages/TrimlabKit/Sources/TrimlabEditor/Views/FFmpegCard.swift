import SwiftUI
import TrimlabModel

/// §4.1: the card a refused .mkv or .avi opens. v1's ffmpeg card (440 px, `--bg-1`, radius 12, 1 px `--line`,
/// 24 / 28 inside) over a scrim: the §4.1 sentence, then the command on a `--bg-2` strip with Copy at its end, then
/// Close. The app rechecks on window focus (`EditorModel.recheckFFmpeg`); with ffmpeg found the card closes itself
/// and the refused files come in. It doesn't move in or out (§6.0).
public struct FFmpegCard: View {
  let model: EditorModel

  public init(model: EditorModel) { self.model = model }

  public static let command = "brew install ffmpeg-full"
  public static let sentence = "trimlab needs ffmpeg to open .mkv and .avi files. Install it with Homebrew:"
  static let width: CGFloat = 440
  /// `sentence` laid out as two lines: what's needed, then how.
  static let lines = ["trimlab needs ffmpeg to open .mkv and .avi files.", "Install it with Homebrew:"]

  public var body: some View {
    ZStack {
      Tokens.scrim
        .contentShape(Rectangle())
        .onTapGesture { model.closeFFmpegCard() }
        .accessibilityHidden(true)
      card.padding(32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The §4.1 sentence in its two parts, one per line, so "with Homebrew:" never strands alone (critique).
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Self.lines, id: \.self) { line in
          Text(line)
            .font(.tl(.inter(.regular), 13))
            .foregroundStyle(Tokens.text)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
      .padding(.bottom, 16)
      commandRow
      HStack {
        Spacer(minLength: 0)
        TLButton("Close", action: model.closeFFmpegCard)
          .tlFocusID(EditorModel.ffmpegClose)
      }
      .padding(.top, 20)
    }
    .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
    .frame(width: Self.width)
    .background(Tokens.bg1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onTapGesture {}  // a click on the card isn't a click on the scrim
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }

  /// v1's `.cmd`: the command in Inter 13/500 `--brand-ink`, selectable, and Copy behind a 1 px `--line` rule.
  private var commandRow: some View {
    HStack(spacing: 0) {
      Text(Self.command)
        .font(.tl(.inter(.medium), 13))
        .foregroundStyle(Tokens.brandInk)
        .lineLimit(1)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      TLButton(style: .bare, label: "Copy", action: model.copyFFmpegCommand) {
        CopyFace()
      }
      .tlFocusID(EditorModel.ffmpegCopy)
    }
    .frame(height: 30)
    .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/// Copy's face: Inter 13/500 `--text` (hover `--brand-ink`), 12 px either side, a 1 px `--line` rule on its left.
private struct CopyFace: View {
  @State private var hover = false

  var body: some View {
    Text("Copy")
      .font(.tl(.inter(.medium), 13))
      .foregroundStyle(hover ? Tokens.brandInk : Tokens.text)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .overlay(alignment: .leading) { Rectangle().fill(Tokens.line).frame(width: 1) }
      .onHover { hover = $0 }
  }
}
