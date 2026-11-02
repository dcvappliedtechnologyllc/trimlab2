import SwiftUI
import TrimlabModel
import UniformTypeIdentifiers

/// §4.3. The 80 px Reel strip under the transport: hosts `StripCanvas`, drawn from `model.draftReel ?? model.reel`
/// so a live handle drag (Task 33) moves it without a commit. Every press, drag, pinch and Finder drop goes to the
/// model, which hit-tests it against `stripLayout()` and reads the modifier keys at the press; the view only reports
/// pointer positions and its frame. ⌘-scroll and two-finger scrolling arrive from the app
/// (`EditorModel.stripScrollWheel`, inside `stripFrame`), since SwiftUI has no scroll-wheel input; no scroll
/// indicators either way.
///
/// Everything built from the clips (layout, sprites, labels, tile states) is read here; only `LiveLayer` reads the
/// playhead and the drag, so playback ticks and pointer moves redraw the canvas without rebuilding any of it.
public struct ReelStripView: View {
  let model: EditorModel
  /// True from the press until the gesture ends or is cancelled; a cancel (it resets with no `onEnded`) cancels the
  /// model's press too.
  @GestureState private var pressing = false
  @State private var pinch: CGFloat = 1

  public init(model: EditorModel) { self.model = model }

  public var body: some View {
    GeometryReader { g in
      let content = Self.content(model, width: g.size.width)
      LiveLayer(model: model, content: content)
        .contentShape(Rectangle())
        .gesture(press)
        .simultaneousGesture(magnify)
        .modifier(FinderDropTarget(model: model, overStrip: true))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          model.stripResized(width: frame.width)
          model.stripFrameChanged(frame)
        }
    }
    .frame(height: Tokens.Layout.strip)
    .clipped()  // zoomed, the tiles stop at the 20 px gutters instead of running to the window's edges
    .onChange(of: pressing) { _, now in if !now { model.stripCancel() } }  // after a release this is a no-op
    .onDisappear { model.stripFrameChanged(nil) }
  }

  /// Press, drag and release in one gesture; under the threshold it is a click.
  private var press: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .updating($pressing) { v, pressing, _ in
        if !pressing {
          pressing = true
          model.stripPress(at: v.startLocation)
        }
      }
      .onChanged { v in model.stripDrag(to: v.location) }
      .onEnded { v in
        model.stripDrag(to: v.location)
        model.stripRelease()
      }
  }

  /// Pinch zooms around where the fingers started.
  private var magnify: some Gesture {
    MagnifyGesture()
      .onChanged { v in
        let step = v.magnification / pinch
        pinch = v.magnification
        model.zoomStrip(by: step, around: v.startLocation.x)
      }
      .onEnded { _ in pinch = 1 }
  }

  /// What the strip draws from the clips: everything but the playhead.
  struct Content {
    var layout: StripLayout
    var sprites: [UUID: StripSprite]
    var state: StripState
  }

  static func content(_ model: EditorModel, width: CGFloat) -> Content {
    Content(layout: layout(model, width: width), sprites: sprites(model), state: state(model))
  }

  /// The Reel the strip shows: the draft during a handle drag, the committed one otherwise.
  static func shown(_ model: EditorModel) -> Reel? { model.draftReel ?? model.reel }

  static func layout(_ model: EditorModel, width: CGFloat) -> StripLayout { model.stripLayout(width: width) }

  static func sprites(_ model: EditorModel) -> [UUID: StripSprite] {
    var out: [UUID: StripSprite] = [:]
    for clip in shown(model)?.clips ?? [] { out[clip.id] = model.stripFrames(for: clip.source) }
    return out
  }

  /// Selection, tile states and labels; no playhead.
  static func state(_ model: EditorModel) -> StripState {
    let clips = shown(model)?.clips ?? []
    let missing = model.missing.union(clips.filter { model.loading[$0.id] == .missing }.map(\.id))
    let waiting = model.loadingClipIDs
      .union(clips.filter { model.spritePending.contains($0.source) && model.stripFrames(for: $0.source) == nil }
        .map(\.id))
    var labels: [UUID: String] = [:]
    for (i, clip) in clips.enumerated() {
      labels[clip.id] = StripCanvas.label(index: i, count: clips.count, clip: clip, missing: missing.contains(clip.id))
    }
    return StripState(primary: model.selection.primary, selected: model.selection.all,
                      loading: waiting.subtracting(missing), missing: missing, labels: labels)
  }
}

/// The one view that reads the playhead and the drag: it adds them to the strip's state and draws the canvas. The
/// caret and the 80 % ghost are the only things a drag moves.
private struct LiveLayer: View {
  let model: EditorModel
  let content: ReelStripView.Content

  var body: some View {
    var state = content.state
    state.playhead = model.playhead
    if let drag = model.activeDrag {
      state.caretGap = drag.caretGap
      if case .reorder(let ids) = drag.kind {
        state.dragged = ids
        if let id = drag.grabbed {
          state.ghost = StripState.Ghost(id: id, x: drag.current.x, grabOffset: drag.grabOffset)
        }
      }
    }
    return StripCanvas(layout: content.layout, sprites: content.sprites, state: state) { id in
      model.selectAndSeek(id, extend: false, toggle: false)
    }
  }
}

/// Finder files over the strip (`overStrip`: the caret, insert there) or the rest of the window (the armed
/// hairline frame, append). No system highlight: the delegate draws nothing itself.
struct FinderDropDelegate: DropDelegate {
  let model: EditorModel
  let overStrip: Bool

  func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

  func dropEntered(info: DropInfo) { over(info) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    over(info)
    return DropProposal(operation: .copy)
  }

  func dropExited(info: DropInfo) { model.finderDragLeft(strip: overStrip) }

  func performDrop(info: DropInfo) -> Bool {
    let providers = info.itemProviders(for: [.fileURL])
    model.finderDrop(loading: { await Self.urls(providers) })
    return true
  }

  private func over(_ info: DropInfo) {
    model.finderDragOver(at: overStrip ? info.location : nil, count: info.itemProviders(for: [.fileURL]).count)
  }

  /// The dropped files' URLs, in drop order (file reference URLs resolved to paths).
  static func urls(_ providers: [NSItemProvider]) async -> [URL] {
    var out: [URL] = []
    for provider in providers {
      let url: URL? = await withCheckedContinuation { c in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
      }
      if let url { out.append((url as NSURL).filePathURL ?? url) }
    }
    return out
  }
}
