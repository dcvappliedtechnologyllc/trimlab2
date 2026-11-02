import CoreGraphics
import Foundation
import TrimlabMedia
import TrimlabModel

/// One piece of deck media for one source file.
public struct DeckFetch: Hashable, Sendable {
  public enum Kind: Hashable, Sendable { case peaks, keyframes }
  public var kind: Kind
  public var source: SourceRef
}

/// §4.4. The trim deck's model side: the clip it shows, its layout, its playhead in source time, the media it draws
/// (fetched here through `url(for:)`, never in a view) and its zoom: ⌘= / ⌘−, the caption's "− Zoom clip +", pinch
/// and ⌘-scroll, from 1× to frame level. Another primary clip resets it to 1×.
extension EditorModel {
  /// A deck fetch that failed this many times isn't asked for again this session.
  static let deckMediaAttempts = 2
  /// Zoomed playback pages the deck so its playhead comes back this far inside the edge (as the strip).
  static let deckPageMargin: CGFloat = 40

  // MARK: what the deck shows

  /// The primary clip as the deck shows it: from the draft during a handle drag (Task 33), the Reel otherwise.
  public var deckClip: ReelClip? {
    guard let id = selection.primary else { return nil }
    return (draftReel ?? reel)?.clips.first { $0.id == id }
  }

  /// The deck's geometry at `width` (the view's last width by default) and the current zoom; nil without a clip.
  public func deckLayout(width: CGFloat? = nil) -> DeckLayout? {
    deckClip.map { DeckLayout(clip: $0, width: width ?? deckWidth, zoom: deckZoom, offset: deckOffset) }
  }

  /// The deck playhead in source time: the peeked frame in peek, otherwise the Reel playhead mapped into the clip
  /// (held to its kept span while the Reel playhead is elsewhere).
  public var deckSourcePlayhead: RationalTime? {
    guard let clip = deckClip else { return nil }
    // A handle held: the stage peeks at its frame, but the deck's playhead (its snap target) stays where it was.
    if deckGrab != nil, let press = deckPressed, press.clipID == clip.id { return press.snapTo }
    if let peek, peek.clipID == clip.id { return peek.sourceTime }
    guard let placement = plan?.placements.first(where: { $0.clipID == clip.id }) else { return clip.inTime }
    let t = placement.sourceIn + (playhead - placement.reelSpan.start)
    return min(max(t, clip.inTime), max(clip.outTime - clip.facts.frameDuration, clip.inTime))
  }

  /// "starts at 3.00 s, keyframe": where a Quick cut really starts (the last keyframe at or before In), shown only
  /// while Quick is chosen and the keyframes are in.
  public var keyframeHint: String? {
    guard reel?.export.cut == .quick, let clip = deckClip, let index = deckKeyframes[clip.source] else { return nil }
    return String(format: "starts at %.2f s, keyframe", index.snappedIn(clip.inTime).seconds)
  }

  // MARK: media

  /// The file the deck's media comes from, or nil when it shouldn't ask: missing, still loading, or unknown.
  private var deckMediaURL: (ReelClip, URL)? {
    guard let clip = deckClip, let committed = reel?.clips.first(where: { $0.id == clip.id }),
          let url = spriteURL(for: committed)
    else { return nil }
    return (committed, url)
  }

  /// Asks for whatever the deck needs and hasn't got: the sprite (through the strip's queue, which it shares),
  /// peaks, and keyframes when Quick is chosen. Each is asked once at a time and retried once after a failure.
  public func requestDeckMedia() {
    guard let (clip, url) = deckMediaURL else { return }
    requestStripSprites()
    fetchDeck(DeckFetch(kind: .peaks, source: clip.source), have: deckPeaks[clip.source] != nil) { [media] in
      let peaks = try await media.peaks(clip, at: url)
      return { $0.deckPeaks[clip.source] = peaks }
    }
    guard reel?.export.cut == .quick else { return }
    fetchDeck(DeckFetch(kind: .keyframes, source: clip.source), have: deckKeyframes[clip.source] != nil) { [media] in
      let index = try await media.keyframes(clip, at: url)
      return { $0.deckKeyframes[clip.source] = index }
    }
  }

  /// What `requestDeckMedia` keys its view task on: the clip and file, the cut, and whether the clip can ask.
  public var deckMediaKey: [String] {
    guard let (clip, url) = deckMediaURL else { return [] }
    return [clip.id.uuidString, url.path, reel?.export.cut.rawValue ?? ""]
  }

  /// Runs `work` for `key` unless it is in, running, or out of attempts; its result is stored on the main actor.
  private func fetchDeck(_ key: DeckFetch, have: Bool,
                         _ work: @escaping @Sendable () async throws -> @MainActor @Sendable (EditorModel) -> Void) {
    if have || deckPending.contains(key) || session.deckFailures[key, default: 0] >= Self.deckMediaAttempts { return }
    deckPending.insert(key)
    let task = Task { [weak self] in
      let outcome: Result<@MainActor @Sendable (EditorModel) -> Void, any Error>
      do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
      guard let self, !Task.isCancelled else { return }  // a reset cleared the state and owns it now
      self.deckFetches[key] = nil
      self.deckPending.remove(key)
      switch outcome {
      case .success(let store): store(self)
      case .failure(let error):
        self.session.deckFailures[key, default: 0] += 1
        MediaLog.note("deck: \(key.kind) for \(URL(filePath: key.source.absolutePath).lastPathComponent) failed: \(error)")
      }
    }
    deckFetches[key] = task
    pendingDeckMedia = task
  }

  // MARK: size and frame

  /// The view reports its width; a narrower ceiling clamps the zoom.
  public func deckResized(width: CGFloat) {
    guard width != deckWidth else { return }
    deckWidth = width
    if let layout = deckLayout(), deckZoom > layout.maxZoom { setDeckWindow(layout) }
  }

  /// The view reports where the deck sits in its window (nil when it goes away).
  public func deckFrameChanged(_ frame: CGRect?) { deckFrame = frame }

  // MARK: zoom

  func resetDeckZoom() {
    deckZoom = 1
    deckOffset = .zero
  }

  /// ⌘= / ⌘− and the caption's buttons: ×1.5 a step, around the playhead while it is in view, else the middle.
  public func deckZoomStep(_ d: Int) {
    guard d != 0, let layout = deckLayout() else { return }
    var anchor = layout.width / 2
    if let t = deckSourcePlayhead {
      let x = layout.x(forSource: t)
      if x >= DeckLayout.pad, x <= layout.width - DeckLayout.pad { anchor = x }
    }
    zoomDeck(by: pow(1.5, Double(d)), around: anchor)
  }

  /// Pinch and ⌘-scroll: the zoom times `factor` (1× to frame level), keeping the source time under `x` where it is.
  public func zoomDeck(by factor: Double, around x: CGFloat) {
    guard factor > 0, factor.isFinite, let before = deckLayout() else { return }
    let ax = min(max(x, DeckLayout.pad), before.width - DeckLayout.pad)
    let t = before.source(at: ax).seconds
    let z = min(max(before.zoom * factor, 1), before.maxZoom)
    let span = before.duration.seconds / z
    deckZoom = z
    deckOffset = z <= 1 ? .zero
      : RationalTime(seconds: t - Double((ax - DeckLayout.pad) / before.canvasWidth) * span, timescale: 60_000)
    if let after = deckLayout() { setDeckWindow(after) }
  }

  /// Zoomed: moves the visible window by `dx` px of the timeline (positive shows later source).
  public func deckPan(by dx: CGFloat) {
    guard let layout = deckLayout(), layout.overviewVisible else { return }
    let seconds = layout.visibleStart.seconds + Double(dx / layout.canvasWidth) * layout.visibleDuration
    deckOffset = RationalTime(seconds: seconds, timescale: 60_000)
    if let after = deckLayout() { setDeckWindow(after) }
  }

  /// Stores the layout's clamped zoom and window, so the model never holds a window the deck can't show.
  private func setDeckWindow(_ layout: DeckLayout) {
    if deckZoom != layout.zoom { deckZoom = layout.zoom }
    let offset = layout.overviewVisible ? layout.visibleStart : .zero
    if deckOffset != offset { deckOffset = offset }
  }

  /// A scroll-wheel event from the app at `point` in the window (the space of `deckFrame`), through the same
  /// monitor as the strip's. ⌘-scroll zooms around the pointer; zoomed, a two-finger swipe pans. Returns whether the
  /// deck used it.
  public func deckScrollWheel(dx: CGFloat, dy: CGFloat, command: Bool, precise: Bool, at point: CGPoint) -> Bool {
    guard let frame = deckFrame, frame.contains(point), modals.top == nil, deckClip != nil else { return false }
    if command {
      let steps = precise ? dy / 100 : max(-1, min(1, dy))
      if steps != 0 { zoomDeck(by: pow(1.5, Double(steps)), around: point.x - frame.minX) }
      return true
    }
    guard deckLayout()?.overviewVisible == true else { return false }
    let d = abs(dx) >= abs(dy) ? dx : dy
    deckPan(by: -(precise ? d : d * 10))
    return true
  }

  /// Zoomed playback pages the deck: a playhead that leaves the window comes back `deckPageMargin` inside the edge
  /// it travels away from.
  func pageDeckToPlayhead() {
    guard deckZoom > 1, let layout = deckLayout(), let t = deckSourcePlayhead else { return }
    let x = layout.x(forSource: t)
    guard x < DeckLayout.pad || x >= layout.width - DeckLayout.pad else { return }
    let lead = currentRate < 0 ? layout.width - DeckLayout.pad - Self.deckPageMargin
      : DeckLayout.pad + Self.deckPageMargin
    deckPan(by: x - lead)
  }
}
