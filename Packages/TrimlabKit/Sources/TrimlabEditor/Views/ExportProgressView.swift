import SwiftUI

/// §4.9's progress pane, in place of the sheet's rows: "Exporting", the file name, the 2 px hairline with its gold
/// run, "about 1 min left" and the percent under it, and Cancel. Esc and the scrim never stop an export; only Cancel
/// does (v1).
struct ExportProgressView: View {
  let model: EditorModel
  let progress: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExportSheetView.title("Exporting")
      Text(model.exportFileName ?? "")
        .font(.tl(.inter(.medium), 13))
        .foregroundStyle(Tokens.text)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(height: 18, alignment: .leading)
        .padding(.top, -8)
        .padding(.bottom, 18)
      TLProgressHairline(progress: progress)
      HStack(alignment: .firstTextBaseline) {
        Text(model.exportProgressLine ?? " ")
        Spacer(minLength: 12)
        Text(model.exportPercentLine ?? " ")
      }
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.muted)
      .frame(minHeight: 18)
      .padding(.top, 10)
      HStack {
        Spacer(minLength: 0)
        TLButton("Cancel") { model.cancelExport() }
          .tlFocusID("export-stop")
      }
      .padding(.top, 20)
    }
  }
}
