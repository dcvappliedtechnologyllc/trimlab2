import SwiftUI
import TrimlabModel

/// §4.4. The trim deck under the caption row: hosts `DeckCanvas` for the primary clip, drawn from
/// `model.draftReel ?? model.reel` so a live handle drag (Task 33) moves it without a commit. It spans the bottom
/// block's full width (the timeline sits `DeckLayout.pad` in from each side) and is 130 px tall: the 122 px deck and
/// the 8 px row under it where the overview rail shows when zoomed. The view reports its width and frame, pinch and
/// the pointer (press, drag, release, hover for the resize cursor); everything else (media, zoom, ⌘-scroll through
/// the app's monitor, handles, snap, peek) is the model's. A held handle shows v1's floating timecode above it, and
/// a span it moves lights v1's span glow.
public struct TrimDeckView: View {
  let model: EditorModel
  @State private var pinch: CGFloat = 1
  @State private var pressing = false
  /// True while the pointer gesture runs; SwiftUI resets it when the gesture ends or is cancelled (a sheet, the
  /// window losing key), which `onEnded` never reports.
  @GestureState private var gesturing = false
  @State private var overHandle = false
  @State private var floatWidth: CGFloat = 0
  /// When a handle drag last moved the kept span (v1's span glow); cleared once the glow has gone.
  @State private var glowAt: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(model: EditorModel) { self.model = model }

  public var body: some View {
    GeometryReader { g in
      TimelineView(.animation(paused: glowAt == nil)) { timeline in
        Self.canvas(model, width: g.size.width,
                    glow: glowAt.map { DeckGlow.level(elapsed: timeline.date.timeIntervalSince($0),
                                                      reduceMotion: reduceMotion) } ?? 0)
      }
      .contentShape(Rectangle())
      .gesture(pointer)
      .simultaneousGesture(magnify)
      .onContinuousHover { phase in
        switch phase {
        case .active(let p): overHandle = model.deckHandle(at: p) != nil
        case .ended: overHandle = false
        }
      }
      .pointerStyle(overHandle || model.deckGrab != nil ? .columnResize : .default)
      .overlay(alignment: .topLeading) { floatingTimecode(width: g.size.width) }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        model.deckResized(width: frame.width)
        model.deckFrameChanged(frame)
      }
    }
    .frame(height: DeckCanvas.height)
    .onDisappear {
      model.deckFrameChanged(nil)
      pressing = false
      model.deckCancel()
    }
    .onChange(of: gesturing) { _, now in
      guard !now else { return }
      // A normal release runs `onEnded` in the same update and clears `pressing` first; only a cancelled gesture
      // is still pressing on the next turn of the main actor.
      Task { @MainActor in
        guard pressing else { return }
        pressing = false
        model.deckCancel()
      }
    }
    .task(id: model.deckMediaKey) { model.requestDeckMedia() }
    .onChange(of: heldSpan) { old, new in
      if old != nil, new != nil, old?.first == new?.first, !reduceMotion { glowAt = .now }
    }
    .task(id: glowAt) {
      guard glowAt != nil else { return }
      try? await Task.sleep(for: .seconds(DeckGlow.duration + 0.02))
      if !Task.isCancelled { glowAt = nil }  // the glow is out: the timeline pauses
    }
  }

  /// The held clip's id and kept span while a handle is grabbed: a change mid-drag lights the span glow.
  private var heldSpan: [String]? {
    guard model.deckGrab != nil, let clip = model.deckClip else { return nil }
    return [clip.id.uuidString, "\(clip.inTime.value)/\(clip.inTime.timescale)",
            "\(clip.outTime.value)/\(clip.outTime.timescale)"]
  }

  /// Press, drag and release, in the deck's own coordinates (the canvas sits at the view's origin).
  private var pointer: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .updating($gesturing) { _, state, _ in state = true }
      .onChanged { v in
        if !pressing {
          pressing = true
          model.deckPress(at: v.startLocation)
        }
        model.deckDrag(to: v.location)
      }
      .onEnded { v in
        if pressing { model.deckDrag(to: v.location) }
        pressing = false
        model.deckRelease()
      }
  }

  /// v1's `#float-tc`: 22 px, `--bg-2` with a 1 px `--line` inset, radius 5, 12 px medium ivory, centred over the
  /// held handle 2 px above the deck and kept inside it.
  @ViewBuilder private func floatingTimecode(width: CGFloat) -> some View {
    if let text = model.deckHandleTimecode, let grab = model.deckGrab, let clip = model.deckClip {
      let layout = DeckLayout(clip: clip, width: width, zoom: model.deckZoom, offset: model.deckOffset)
      let x = layout.x(forSource: grab == .in ? clip.inTime : clip.outTime)
      let left = max(0, min(width - floatWidth, x - floatWidth / 2)).rounded()
      Text(text)
        .font(.tl(.inter(.medium), 12))
        .monospacedDigit()
        .foregroundStyle(Tokens.brandInk)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { floatWidth = $0 }
        .offset(x: left, y: -24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  /// Pinch zooms around where the fingers started.
  private var magnify: some Gesture {
    MagnifyGesture()
      .onChanged { v in
        let step = v.magnification / pinch
        pinch = v.magnification
        model.zoomDeck(by: Double(step), around: v.startLocation.x)
      }
      .onEnded { _ in pinch = 1 }
  }

  /// The canvas for the model's primary clip at `width`.
  static func canvas(_ model: EditorModel, width: CGFloat, glow: Double = 0) -> DeckCanvas {
    guard let clip = model.deckClip else {
      return DeckCanvas(layout: nil, sprite: nil, peaks: nil, state: DeckState())
    }
    let layout = DeckLayout(clip: clip, width: width, zoom: model.deckZoom, offset: model.deckOffset)
    let sprite = model.stripSprites[clip.source]
    let peaks = model.deckPeaks[clip.source]
    let waiting = model.loadingClipIDs.contains(clip.id)
    var keyframes: [RationalTime]?
    var landing: RationalTime?
    if model.reel?.export.cut == .quick, let index = model.deckKeyframes[clip.source] {
      keyframes = index.times
      landing = index.snappedIn(clip.inTime)
    }
    let state = DeckState(
      playhead: model.deckSourcePlayhead, grabbed: model.deckGrab,
      removeAudio: model.reel?.export.removeAudio ?? false, keyframes: keyframes, keyframeLanding: landing,
      framesLoading: waiting || (sprite == nil && model.spritePending.contains(clip.source)),
      peaksLoading: waiting || (peaks == nil && model.deckPending.contains(DeckFetch(kind: .peaks, source: clip.source))),
      missing: model.missing.contains(clip.id) || model.loading[clip.id] == .missing, spanGlow: glow)
    return DeckCanvas(layout: layout, sprite: sprite, peaks: peaks, state: state)
  }
}

/// The deck caption's "− Zoom clip +" (§4.4, §6.4): the deck zoom, beside the deck it zooms (`CaptionRow`).
public struct DeckZoomControl: View {
  let model: EditorModel

  public init(model: EditorModel) { self.model = model }

  public var body: some View {
    HStack(spacing: 2) {
      TLIconButton(.minus, size: .small, label: "Zoom the clip out", tip: "Zoom the clip out (⌘−)") {
        model.deckZoomStep(-1)
      }
      Text("Zoom clip")
        .font(.tl(.inter(.regular), 12))
        .foregroundStyle(Tokens.muted)
        .padding(.horizontal, 4)
      TLIconButton(.plus, size: .small, label: "Zoom the clip in", tip: "Zoom the clip in (⌘=)",
                   tipPlacement: TLTipPlacement(.above, align: .trailing)) { model.deckZoomStep(1) }
    }
  }
}
