import AVFoundation
import CoreGraphics
import SwiftUI
import TrimlabModel

/// The window's content (§6.4). With no clips: the header over v1's empty stage ("Drop clips."). With clips: the
/// stage and the 300 px inspector side by side, and the 278 px bottom block under both (transport 40, strip 80,
/// caption 28, deck 122, 8 px pad, 20 px side padding). Under 1000 px wide (`RootLayout`) the inspector becomes the
/// 64 px row under the stage; the strip and deck are unchanged (§4.11).
///
/// Over it all: the export sheet (under the header), then the ffmpeg card and the key map over the whole window. The
/// Design controls follow the model's focus id (`TLFocusLink`), so Tab in the top modal and a modal's close move the
/// gold ring (§4.10).
public struct RootView<Surface: View>: View {
  let model: EditorModel
  let logo: CGImage?
  let onHelp: () -> Void
  let onExport: () -> Void
  let surface: (AVPlayer) -> Surface

  /// The window's width, as last laid out.
  @State private var width: CGFloat = 1240

  /// `surface` hosts a player on the stage (the app's `PlayerSurface`).
  public init(model: EditorModel, logo: CGImage? = nil, onHelp: @escaping () -> Void = {},
              onExport: @escaping () -> Void = {}, @ViewBuilder surface: @escaping (AVPlayer) -> Surface) {
    self.model = model
    self.logo = logo
    self.onHelp = onHelp
    self.onExport = onExport
    self.surface = surface
  }

  /// The bottom block's height at any window size.
  public static var bottomHeight: CGFloat {
    Tokens.Layout.transport + Tokens.Layout.strip + Tokens.Layout.caption + Tokens.Layout.deck
      + Tokens.Layout.bottomPad
  }

  public var body: some View {
    let narrow = RootLayout.mode(width: width) == .narrow
    // One layout that changes axis, so the stage (and its player view) keeps its identity across the break.
    let main = narrow ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    VStack(spacing: 0) {
      HeaderView(title: Self.title(model.reel), reelName: Self.reelName(model), logo: logo, narrow: narrow,
                 onHelp: onHelp)
        .zIndex(1)  // the `?` tooltip hangs below the header, over the stage
      if model.reel?.clips.isEmpty == false {
        main {
          StageView(model: model, surface: surface)
          InspectorView(model: model, narrow: narrow, onExport: onExport)
        }
        bottom
      } else {
        EmptyStateView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Tokens.bg0)
          .overlay(alignment: .bottom) {
            if let note = model.notes.last {
              NoteLine(note: note) { model.dismissNote(note.id) }.padding(.bottom, 16)
            }
          }
      }
    }
    .background(Tokens.bg0)
    // The export sheet hangs from under the header (§4.9), centred over the stage (the whole width when narrow).
    .overlay(alignment: .top) {
      ExportSheetLayer(model: model, inspectorWidth: narrow ? 0 : Tokens.Layout.inspector)
        .padding(.top, Tokens.Layout.header)
    }
    .overlay { if model.ffmpegCardOpen { FFmpegCard(model: model) } }
    .overlay { if model.keyMapOpen { KeyMapOverlay(model: model) } }
    .overlay { if model.dropArmed { Self.armedFrame } }
    // Finder files anywhere but the strip (which takes its own drop, at the caret) append (§4.1, §4.3.3).
    .modifier(FinderDropTarget(model: model, overStrip: false))
    .tlFocusLink(TLFocusLink(current: model.focusedControl, ring: model.focusRing,
                             set: { [model] in model.setFocusedControl($0) }))
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .ignoresSafeArea()
  }

  /// v1's armed hairline frame while Finder files are over the window: 1 px `--gold-hair`, inset and rounded by
  /// the `dropFrame` tokens.
  static var armedFrame: some View {
    RoundedRectangle(cornerRadius: Tokens.Layout.dropFrameRadius, style: .continuous)
      .strokeBorder(Tokens.goldHair, lineWidth: 1)
      .padding(Tokens.Layout.dropFrameInset)
      .allowsHitTesting(false)
  }

  /// The strip, then the caption row (its hairline runs the full width) and the deck. The deck reaches into the
  /// side padding (its timeline is inset by the same 20 px) and into the bottom pad, where its overview rail shows
  /// when zoomed.
  private var bottom: some View {
    VStack(spacing: 0) {
      TransportView(model: model, onZoom: model.stripZoomStep)
      ReelStripView(model: model)
      CaptionRow(model: model)
      TrimDeckView(model: model)
        .padding(.horizontal, -Tokens.Layout.deckPad)
    }
    .padding(.horizontal, Tokens.Layout.deckPad)
    .frame(height: Self.bottomHeight)
    .frame(maxWidth: .infinity)
    .background(Tokens.bg1)
    .overlay(alignment: .top) { Rectangle().fill(Tokens.line).frame(height: 1) }
  }

  /// The header's renameable Reel name (§6.1): nil for a one-clip Reel (its file name shows) or no Reel.
  static func reelName(_ model: EditorModel) -> HeaderView.ReelName? {
    guard let reel = model.reel, reel.clips.count >= 2 else { return nil }
    let editing = model.editingReelName && model.canRenameReel
    return HeaderView.ReelName(name: editing ? model.reelNameDraft : reel.name, editing: editing,
                               focusReset: model.focusResetToken, begin: model.beginRenameReel,
                               edit: model.setReelNameDraft, commit: { model.commitRenameReel(keyboard: $0) },
                               cancel: { model.cancelRenameReel(keyboard: $0) })
  }

  /// The header's name: the file for a one-clip Reel (`IMG_4821.MOV`), otherwise the Reel's name; none when empty.
  static func title(_ reel: Reel?) -> String? {
    guard let reel, !reel.clips.isEmpty else { return nil }
    if reel.clips.count == 1 {
      return URL(filePath: reel.clips[0].source.absolutePath, directoryHint: .notDirectory).lastPathComponent
    }
    return reel.name
  }
}

/// §4.11: the window's layout by width. Under 1000 px the inspector becomes a row under the stage.
public enum RootLayout: Equatable, Sendable {
  case wide, narrow

  public static func mode(width: CGFloat) -> RootLayout { width < Tokens.Layout.narrowBreak ? .narrow : .wide }
}
