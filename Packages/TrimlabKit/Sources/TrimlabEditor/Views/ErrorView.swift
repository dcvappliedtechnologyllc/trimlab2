import SwiftUI

/// §4.9 Error: "Not saved", the one plain sentence, a Details disclosure (the error's domain, code and description and
/// the log's last 30 lines, with Copy while it's open), then Close and Back to settings, the filled button.
struct ErrorView: View {
  let model: EditorModel
  @Environment(\.tlStillRender) private var still

  private var details: some View {
    Text(model.exportErrorDetails ?? "")
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.muted)
      .lineSpacing(2.5)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExportSheetView.title("Not saved")
      Text(model.exportErrorSentence ?? "")
        .font(.tl(.inter(.regular), 13))
        .foregroundStyle(Tokens.text)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isStaticText)
      TLDisclosure("Details", isOpen: Binding(get: { model.exportSheet.detailsOpen },
                                              set: { if $0 != model.exportSheet.detailsOpen { model.toggleExportDetails() } })) {
        Group {
          if still {
            // A still can't draw the AppKit-backed scroll view: its last 218 px, as it opens (bottom-anchored).
            details.fixedSize(horizontal: false, vertical: true).frame(height: 218, alignment: .bottom).clipped()
          } else {
            ScrollView { details }
              .scrollIndicators(.hidden)  // no system scroller in the brand (§6.0); it still scrolls
              .defaultScrollAnchor(.bottom)  // the last line is the one that says why (v1)
              .frame(maxHeight: 218)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Tokens.bg0, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
      }
      .tlFocusID("export-details")
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .topTrailing) {
        if model.exportSheet.detailsOpen {
          TLButton("Copy") { model.copyExportDetails() }
            .tlFocusID("export-copy")
            .offset(y: -3)  // centred on the disclosure's 24 px row
        }
      }
      .padding(.top, 14)
      HStack(spacing: 10) {
        Spacer(minLength: 0)
        TLButton("Close", action: model.closeExportSheet)
          .tlFocusID("export-close")
        TLPrimaryButton("Back to settings", height: 30, action: model.exportBackToSettings)
          .tlFocusID("export-back")
          .frame(width: 136)
      }
      .padding(.top, 20)
    }
  }
}
