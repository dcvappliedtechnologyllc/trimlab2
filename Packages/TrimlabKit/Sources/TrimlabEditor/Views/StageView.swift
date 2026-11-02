import AVFoundation
import SwiftUI
import TrimlabModel

/// §4.2. The stage, `--bg-0`: the composited Reel at its render size, fitted inside the mockup's 16 × 32 px
/// padding (radius 3). In peek it shows the selected clip's source frame from its scrub player, letterboxed, with
/// v1's 9:16 gold guide (outside dimmed 40 %) when a wider clip is Fill in a Reel. The newest note sits at the
/// bottom. `surface` hosts a player (the app's `PlayerSurface`; a still in screen tests).
public struct StageView<Surface: View>: View {
  let model: EditorModel
  let surface: (AVPlayer) -> Surface

  public init(model: EditorModel, @ViewBuilder surface: @escaping (AVPlayer) -> Surface) {
    self.model = model
    self.surface = surface
  }

  static var padding: EdgeInsets {
    EdgeInsets(top: 16, leading: Tokens.Layout.stagePad, bottom: 16, trailing: Tokens.Layout.stagePad)
  }

  public var body: some View {
    ZStack {
      Tokens.bg0
      if let peek = model.peek, let player = model.peekPlayer,
         let clip = model.reel?.clips.first(where: { $0.id == peek.clipID }) {
        peekFrame(player, clip: clip)
      } else if let line = Self.missingLine(model) {
        // The selected clip is missing: the addendum's #missing-clip line in place of the preview.
        Text(line)
          .font(.tl(.inter(.regular), 13))
          .foregroundStyle(Tokens.muted)
          .multilineTextAlignment(.center)
          .lineSpacing(2)
          .padding(Self.padding)
      } else if let plan = model.plan, !plan.placements.isEmpty {
        surface(model.preview.player)
          .aspectRatio(CGSize(width: plan.renderSize.width, height: plan.renderSize.height), contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
          .padding(Self.padding)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { model.pointerPressed() })  // focus leaves the caption controls
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(model))
    .overlay(alignment: .bottom) { notes }
    .clipped()
  }

  /// "IMG_4826.MOV is missing. Locate it or remove it from the Reel." while paused with the primary clip missing.
  /// Playing, the preview shows (it plays without the missing clip, §5.1).
  static func missingLine(_ model: EditorModel) -> String? {
    guard !model.isPlaying, let id = model.selection.primary,
          model.missing.contains(id) || model.loading[id] == .missing,
          let clip = model.reel?.clips.first(where: { $0.id == id }) else { return nil }
    let name = URL(filePath: clip.source.absolutePath, directoryHint: .notDirectory).lastPathComponent
    return ExportForm.missingLine(first: name, others: 0)
  }

  /// "Reel preview, 48.2 s"; "Source frame of IMG_4821" in peek; "Reel preview, empty". Not the playhead: the
  /// stage mustn't redraw on every frame of playback (the transport timecode reads it).
  static func accessibilityLabel(_ model: EditorModel) -> String {
    if let peek = model.peek, let clip = model.reel?.clips.first(where: { $0.id == peek.clipID }) {
      return "Source frame of \(InspectorView.clipName(clip))"
    }
    if let line = missingLine(model) { return line }
    guard let plan = model.plan, !plan.placements.isEmpty else { return "Reel preview, empty" }
    return "Reel preview, \(Formatting.total(plan.total))"
  }

  @ViewBuilder private var notes: some View {
    if let note = model.notes.last {
      NoteLine(note: note) { model.dismissNote(note.id) }
        .padding(.horizontal, Tokens.Layout.stagePad)
        .padding(.bottom, 16)
    }
  }

  private func peekFrame(_ player: AVPlayer, clip: ReelClip) -> some View {
    let w = max(clip.facts.displayWidth, 1), h = max(clip.facts.displayHeight, 1)
    let guided = model.stageGuideVisible
    return surface(player)
      .aspectRatio(CGSize(width: w, height: h), contentMode: .fit)
      .overlay { if guided { GuideOverlay() } }
      .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      .padding(Self.padding)
  }
}

/// v1's 9:16 guide: a centred 9:16 box with a 1 px `--gold-hair` edge; everything outside it dimmed by `--guide-dim`.
struct GuideOverlay: View {
  var body: some View {
    GeometryReader { g in
      let box = CGRect(x: (g.size.width - g.size.height * 9 / 16) / 2, y: 0,
                       width: g.size.height * 9 / 16, height: g.size.height)
      ZStack(alignment: .topLeading) {
        Path { p in
          p.addRect(CGRect(origin: .zero, size: g.size))
          p.addRect(box)
        }
        .fill(Tokens.guideDim, style: FillStyle(eoFill: true))
        Rectangle()
          .strokeBorder(Tokens.goldHair, lineWidth: 1)
          .frame(width: box.width, height: box.height)
          .offset(x: box.minX)
      }
    }
    .allowsHitTesting(false)
  }
}
