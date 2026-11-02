import SwiftUI
import TrimlabMedia
import TrimlabModel

/// §4.9. v1's export sheet: 560 px, `--bg-1`, a 1 px `--line` edge open at the top, the bottom corners 12 px, hung
/// from under the header over the stage. Padding 22 / 28 / 24; "Export" 15/600 `--brand-ink`; rows on a 104 px key
/// column, 30 px tall, 14 px apart; the summary under a hairline (20 px down, 16 px in); Cancel and Export at the foot.
/// Every field goes through the model (`ExportForm`); nothing here decides a rule. While an export runs the rows give
/// way to the progress pane, then to Done or Error (Task 36), in the same sheet.
public struct ExportSheetView: View {
  let model: EditorModel

  public init(model: EditorModel) { self.model = model }

  public static let width: CGFloat = 560
  static let keyColumn: CGFloat = 104

  public var body: some View {
    if let pane = pane {
      pane
      .padding(EdgeInsets(top: 22, leading: 29, bottom: 24, trailing: 29))  // 28 inside the 1 px edge
      .frame(width: Self.width, alignment: .leading)
      .background(Tokens.bg1, in: Self.shape)
      .overlay(Self.edge.stroke(Tokens.line, lineWidth: 1))
      .contentShape(Self.shape)
      .onTapGesture {}  // a click on the sheet isn't a click on the scrim
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Export")
      .accessibilityAddTraits(.isModal)
    }
  }

  /// The pane the export's state calls for; nil with no Reel to export.
  private var pane: AnyView? {
    switch model.exportState {
    case .running(let progress, _): return AnyView(ExportProgressView(model: model, progress: progress))
    case .done(let result): return AnyView(DoneView(model: model, done: ExportDone(result)))
    case .failed: return AnyView(ErrorView(model: model))
    case .idle, .editing:
      guard let form = model.exportForm else { return nil }
      return AnyView(VStack(alignment: .leading, spacing: 0) {
        Self.title("Export")
        rows(form)
        summary
        notes(form)
        foot
      })
    }
  }

  /// A pane's title: Inter 15/600 `--brand-ink`, 18 px above what follows.
  static func title(_ text: String) -> some View {
    Text(text)
      .font(.tl(.inter(.semibold), 15))
      .foregroundStyle(Tokens.brandInk)
      .frame(height: 20)
      .padding(.bottom, 18)
  }

  static let shape = UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)

  /// The edge on three sides: the top meets the header.
  static var edge: some Shape { SheetEdge() }

  // MARK: rows

  @ViewBuilder private func rows(_ form: ExportForm) -> some View {
    row("Format", top: true) {
      VStack(alignment: .leading, spacing: 6) {
        TLSegmented(options: [(ExportSpec.Format.reel, "Reel"), (.original, "Original")], selection: form.spec.format,
                    label: "Format", onSelect: model.setExportFormat,
                    onFocusChange: { model.controlFocus("export-format", focused: $0) })
          .tlFocusID("export-format")
        caption(form.caption)
      }
    }
    row("Cut") {
      TLSegmented(options: [(ExportSpec.Cut.exact, "Exact"), (.quick, "Quick")], selection: form.spec.cut,
                  label: "Cut", disabled: form.quickTip.map { [.quick: $0] } ?? [:], onSelect: model.setExportCut,
                  onFocusChange: { model.controlFocus("export-cut", focused: $0) })
        .tlFocusID("export-cut")
    }
    row("Quality") {
      TLSegmented(options: [(ExportSpec.Quality.standard, "Standard"), (.high, "High")],
                  selection: form.spec.quality, label: "Quality", onSelect: model.setExportQuality,
                  onFocusChange: { model.controlFocus("export-quality", focused: $0) })
        .tlFocusID("export-quality")
    }
    if form.showsHDRRow {
      row("HDR") {
        TLSwitch("Convert HDR to SDR", isOn: form.spec.convertHDR) {
          model.setExportConvertHDR(!form.spec.convertHDR)
        }
        .rowHeight(30)
        .fixedSize()
        .tlFocusID("export-hdr")
      }
    }
    row("File name") {
      TLTextField("File name", value: form.fieldText, onCommit: model.setExportFileName)
        .tlFocusID("export-name")
    }
    row("Save to", top: form.folderNote != nil) {
      VStack(alignment: .leading, spacing: 6) {
        TLFolderWell(name: ExportForm.plainName(form.folder)) { model.chooseExportFolder() }
          .tlFocusID("export-choose")  // its Choose… button
        if let note = form.folderNote { caption(note) }
      }
    }
    if model.exportAsksReplace {
      row("") {
        VStack(alignment: .leading, spacing: 8) {
          Text(ExportForm.existsLine)
            .font(.tl(.inter(.regular), 12))
            .foregroundStyle(Tokens.text)
            .frame(height: 17)
          HStack(spacing: 8) {
            TLButton("Replace", action: model.exportReplace)
              .tlFocusID("export-replace")
              .overlay { if model.canExport { Self.chosenMark } }
            TLButton("Keep both", action: model.exportKeepBoth)
              .tlFocusID("export-keep-both")
          }
        }
      }
    }
  }

  /// Replace, once chosen: its edge in gold.
  static var chosenMark: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .strokeBorder(Tokens.brandGold, lineWidth: 1)
      .allowsHitTesting(false)
  }

  private func row<Content: View>(_ key: String, top: Bool = false,
                                  @ViewBuilder _ content: () -> Content) -> some View {
    HStack(alignment: top ? .top : .center, spacing: 0) {
      Text(key)
        .font(.tl(.inter(.regular), 13))
        .foregroundStyle(Tokens.muted)
        .frame(width: Self.keyColumn, height: 30, alignment: .leading)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 30)
    .padding(.bottom, 14)
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .foregroundStyle(Tokens.muted)
      .frame(height: 17, alignment: .leading)
      .padding(.bottom, 12)  // the mockup's `.cap` keeps its paragraph's 1em bottom margin
  }

  // MARK: summary, notes, foot

  private var summary: some View {
    Text(model.exportSummary ?? " ")
      .font(.tl(.inter(.medium), 13))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .lineLimit(1)
      .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
      .padding(.top, 16)
      .frame(minHeight: 34, alignment: .top)
      .overlay(alignment: .top) { Rectangle().fill(Tokens.line).frame(height: 1) }
      .padding(.top, 6)  // 20 px below the last row's 14 px gap
  }

  /// The over-3:00 line in `--warn`, and what stops Export (a Reel file, a missing clip, an unwritable folder).
  @ViewBuilder private func notes(_ form: ExportForm) -> some View {
    if let after = model.exportSheet.note { note(after, Tokens.text) }
    if let over = form.overLimitLine { note(over, Tokens.warn) }
    if let block = model.exportBlockLine { note(block, Tokens.warn) }
  }

  private func note(_ text: String, _ colour: Color) -> some View {
    Text(text)
      .font(.tl(.inter(.regular), 12))
      .monospacedDigit()
      .lineSpacing(2.5)
      .foregroundStyle(colour)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
  }

  private var foot: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)
      TLButton("Cancel", action: model.closeExportSheet)
        .tlFocusID("export-cancel")
      TLPrimaryButton("Export", height: 30, looksDisabled: !model.canExport, action: model.startExport)
        .tlFocusID("export-go")
        .accessibilityIdentifier("export-confirm")
        // Export refuses a click until the clips have loaded; this lets VoiceOver and the smoke test see it.
        .accessibilityValue(model.canExport ? "ready" : "waiting")
        .frame(width: 78)
    }
    .padding(.top, 20)
  }
}

/// The sheet's edge: down the sides and round the bottom corners, open along the top.
private struct SheetEdge: Shape {
  func path(in r: CGRect) -> Path {
    let rad: CGFloat = 12
    var p = Path()
    p.move(to: CGPoint(x: r.minX + 0.5, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX + 0.5, y: r.maxY - rad))
    p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.maxY - 0.5), control: CGPoint(x: r.minX + 0.5, y: r.maxY - 0.5))
    p.addLine(to: CGPoint(x: r.maxX - rad, y: r.maxY - 0.5))
    p.addQuadCurve(to: CGPoint(x: r.maxX - 0.5, y: r.maxY - rad), control: CGPoint(x: r.maxX - 0.5, y: r.maxY - 0.5))
    p.addLine(to: CGPoint(x: r.maxX - 0.5, y: r.minY))
    return p
  }
}

/// The sheet over the editor: the scrim under the header (a click on it closes the sheet), and the sheet sliding down
/// from under the header, centred over the stage: in 220 ms ease-out, out in 180 ms; no motion under Reduce Motion.
struct ExportSheetLayer: View {
  let model: EditorModel
  /// The inspector's width beside the stage (the sheet centres over the stage only).
  let inspectorWidth: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let open = model.exportSheetOpen
    ZStack(alignment: .top) {
      if open {
        Tokens.scrim
          .contentShape(Rectangle())
          .onTapGesture { model.closeExportSheet() }
          .transition(.opacity)
          .accessibilityHidden(true)
        // Top-aligned: the inspector's spacer is as tall as the window, and a centred row would hang the sheet
        // mid-stage instead of from the header.
        HStack(alignment: .top, spacing: 0) {
          ExportSheetView(model: model)
            .frame(maxWidth: .infinity, alignment: .top)
          Color.clear.frame(width: inspectorWidth).allowsHitTesting(false)
        }
        .transition(.move(edge: .top))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .clipped()
    .allowsHitTesting(open)
    .animation(Tokens.Motion.sheetSlide(reduce: reduceMotion, opening: open), value: open)
  }
}
