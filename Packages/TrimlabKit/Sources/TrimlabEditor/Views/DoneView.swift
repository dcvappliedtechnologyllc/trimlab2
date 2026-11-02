import SwiftUI
import TrimlabModel

/// §4.9 Done: the first frame (72×128 for a Reel; the output's shape, long side 128), "Saved." in Bodoni italic 52
/// rising and fading in once per export (420 ms; none under Reduce Motion), the file name, "84.1 MB, in Spa Tour",
/// the fallback line after a software retry, then Reveal in Finder, Open in QuickTime, AirDrop (only where the Mac
/// has it) and, pushed right, New Reel. Esc or the scrim goes back to the Reel.
struct DoneView: View {
  let model: EditorModel
  let done: ExportDone

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 22) {
        still
        VStack(alignment: .leading, spacing: 0) {
          Text("Saved.")
            .font(.tl(.bodoni(italic: true, weight: 400), 52))
            .foregroundStyle(Tokens.brandInk)
            .frame(height: 56, alignment: .leading)
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 4)
            .padding(.bottom, 10)
            .accessibilityIdentifier("done.saved")
          Text(done.fileName)
            .font(.tl(.inter(.medium), 13))
            .foregroundStyle(Tokens.text)
            .lineLimit(1)
            .truncationMode(.middle)
          small(done.whereLine)
          if let fallback = done.fallbackLine { small(fallback) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 8) {
        TLButton("Reveal in Finder") { model.exportDone(.reveal) }
          .tlFocusID("export-reveal")
        TLButton("Open in QuickTime") { model.exportDone(.quickTime) }
          .tlFocusID("export-quicktime")
        if model.exportCanAirDrop {
          TLButton("AirDrop") { model.exportDone(.airDrop) }
            .tlFocusID("export-airdrop")
        }
        Spacer(minLength: 8)
        TLButton("New Reel") { model.newReelFromDone() }
          .tlFocusID("export-new-reel")
      }
      .padding(.top, 24)
    }
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(Tokens.Motion.saved(reduce: reduceMotion)) { shown = true }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Saved \(done.fileName)")
  }

  /// The first frame, or its empty well when there's none.
  @ViewBuilder private var still: some View {
    let size = ExportDone.stillSize(model.plan?.renderSize)
    ZStack {
      Tokens.bg2
      if let image = done.thumbnail {
        Image(decorative: image, scale: 1)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
    .accessibilityHidden(true)
  }

  private func small(_ text: String) -> some View {
    Text(text)
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.muted)
      .lineLimit(1)
      .padding(.top, 2)
  }
}
