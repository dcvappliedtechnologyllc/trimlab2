import CoreGraphics
import Foundation
import TrimlabModel

/// §4.3.3. A drag over the strip once it counts: a reorder past `threshold`, or Finder files over it. The caret
/// (`caretGap`) and, for a reorder, the 80 % ghost at `current` are all that move.
public struct StripDrag: Equatable {
  public enum Kind: Equatable {
    /// The clips being moved, in Reel order when they land.
    case reorder(Set<UUID>)
    /// Finder files over the strip.
    case finder(count: Int)
  }

  public var kind: Kind
  /// Strip coordinates.
  public var start: CGPoint
  public var current: CGPoint
  /// The nearest gap (`StripLayout.gap(at:)`): where a release lands.
  public var caretGap: Int?
  /// The tile the reorder was pressed on (the ghost shows it), and where on it the press was.
  public var grabbed: UUID?
  public var grabOffset: CGFloat = 0

  /// A press becomes a drag after moving this far.
  public static let threshold: CGFloat = 4
  /// Zoomed, a reorder this close to either edge auto-scrolls.
  public static let autoScrollEdge: CGFloat = 32
  /// One auto-scroll step on `EditorModel.clock` (60 a second).
  public static let autoScrollTick: Duration = .milliseconds(16)
  /// The fastest auto-scroll, at the very edge, per tick.
  public static let autoScrollMax: CGFloat = 12

  public init(kind: Kind, start: CGPoint, current: CGPoint, caretGap: Int?, grabbed: UUID? = nil,
              grabOffset: CGFloat = 0) {
    self.kind = kind
    self.start = start
    self.current = current
    self.caretGap = caretGap
    self.grabbed = grabbed
    self.grabOffset = grabOffset
  }

  /// The auto-scroll step for a pointer at `x` on a strip `width` wide: up to `autoScrollMax` px a tick, faster
  /// nearer the edge; negative scrolls back; 0 outside the edge zones.
  static func autoScrollStep(at x: CGFloat, width: CGFloat) -> CGFloat {
    let edge = autoScrollEdge
    let depth: CGFloat
    if x < edge {
      depth = -(edge - max(x, 0))
    } else if x > width - edge {
      depth = min(x, width) - (width - edge)
    } else {
      return 0
    }
    guard depth != 0 else { return 0 }
    let speed = max(1, (autoScrollMax * abs(depth) / edge).rounded())
    return depth < 0 ? -speed : speed
  }
}

/// A press on the strip not yet released: on a join (a click cycles it) or on a tile (a click selects it, a drag
/// past the threshold reorders).
struct StripPress {
  enum Target { case tile(UUID), join(UUID) }
  var target: Target
  var at: CGPoint
  var extend: Bool
  var toggle: Bool
  /// Where on the tile the press was (the ghost keeps it under the pointer).
  var grabOffset: CGFloat
  /// The pointer has gone past the threshold since the press.
  var moved = false
}

/// §4.3.2–4.3.5. The strip's pointer intents, hit-tested in the model against `stripLayout()`. A press tests
/// `joinHit` before `tile(at:)`, so inside a crossfade overlap (or within `StripLayout.cutSlop` of a cut) it is a
/// join click, never a tile.
extension EditorModel {
  /// Zoomed playback pages so the playhead lands this far inside the strip.
  static let stripPageMargin: CGFloat = 24

  /// The strip as it is drawn now: the draft Reel during a handle drag, at the current zoom and scroll.
  public func stripLayout(width: CGFloat? = nil) -> StripLayout { layoutStrip(width: width, zoom: stripZoom) }

  /// `stripLayout` at any zoom (the scroll applies only when zoomed).
  func layoutStrip(width: CGFloat? = nil, zoom: StripZoom) -> StripLayout {
    let shown = draftReel ?? reel ?? .empty(name: "")
    let plan = (draftReel == nil ? self.plan : draftPlan) ?? Planner.plan(shown, missing: missing)
    return StripLayout(plan: plan, clips: shown.clips, width: width ?? stripWidth, zoom: zoom,
                       scrollX: zoom == .fit ? 0 : stripScrollX, format: shown.export.format)
  }

  /// The view reports its width; the scroll is clamped to it.
  public func stripResized(width: CGFloat) {
    guard width != stripWidth else { return }
    stripWidth = width
    if stripZoom != .fit { setStripScroll(stripScrollX) }
  }

  /// The view reports where the strip sits in its window (nil when it goes away).
  public func stripFrameChanged(_ frame: CGRect?) { stripFrame = frame }

  // MARK: press, drag, release

  /// A press at `p`: on a join, or on a tile. The modifier keys are read now, from the platform: ⇧ extends and ⌘
  /// toggles the click's selection.
  public func stripPress(at p: CGPoint) {
    pointerPressed()
    let mods = platform.modifierKeys()
    stripPress(at: p, extend: mods.contains(.shift), toggle: mods.contains(.command))
  }

  /// `stripPress(at:)` with the modifiers given.
  func stripPress(at p: CGPoint, extend: Bool, toggle: Bool) {
    endStripInteraction()
    let layout = stripLayout()
    if let id = layout.joinHit(at: p) {
      stripPressed = StripPress(target: .join(id), at: p, extend: extend, toggle: toggle, grabOffset: 0)
    } else if let id = layout.tile(at: p), let tile = layout.tiles.last(where: { $0.id == id }) {
      stripPressed = StripPress(target: .tile(id), at: p, extend: extend, toggle: toggle,
                                grabOffset: p.x - tile.rect.minX)
    }
  }

  /// The pointer moved with the button down. Past `StripDrag.threshold` a tile press becomes a reorder of the
  /// selection (when the tile is in it) or of the tile alone (which becomes the selection).
  public func stripDrag(to p: CGPoint) {
    guard var press = stripPressed else { return }
    if !press.moved, hypot(p.x - press.at.x, p.y - press.at.y) >= StripDrag.threshold {
      press.moved = true
      stripPressed = press
    }
    guard press.moved, case .tile(let id) = press.target else { return }
    if activeDrag == nil {
      if !selection.all.contains(id) { select(id, extend: false, toggle: false) }
      activeDrag = StripDrag(kind: .reorder(selection.all), start: press.at, current: p, caretGap: nil, grabbed: id,
                             grabOffset: press.grabOffset)
    }
    activeDrag?.current = p
    activeDrag?.caretGap = stripLayout().gap(at: p.x)
    updateAutoScroll()
  }

  /// Release: a reorder moves (one step; nothing when the order wouldn't change); a click on a tile selects it and
  /// puts the playhead at its In; a click on a join cycles it.
  public func stripRelease() {
    defer { endStripInteraction() }
    guard let press = stripPressed else { return }
    if let drag = activeDrag, case .reorder(let ids) = drag.kind {
      if let gap = drag.caretGap { move(ids, toGap: gap) }
      return
    }
    guard !press.moved else { return }
    switch press.target {
    case .join(let id): clickJoin(id)
    case .tile(let id): selectAndSeek(id, extend: press.extend, toggle: press.toggle)
    }
  }

  /// Esc during a press or reorder, or the view's gesture ending without a release: nothing moves. Returns
  /// whether there was one to cancel.
  @discardableResult
  public func stripCancel() -> Bool {
    var had = stripPressed != nil
    if case .reorder? = activeDrag?.kind { had = true }
    guard had else { return false }
    endStripInteraction()
    return true
  }

  /// Clears every press, drag, armed frame and auto-scroll.
  func endStripInteraction() {
    stripPressed = nil
    if activeDrag != nil { activeDrag = nil }
    if dropArmed { dropArmed = false }
    stopAutoScroll()
  }

  /// One `.move` step, or nothing when the clips would land where they are.
  private func move(_ ids: Set<UUID>, toGap gap: Int) {
    guard let reel, let next = try? apply(.move(ids, toGap: gap), to: reel),
          next.clips.map(\.id) != reel.clips.map(\.id)
    else { return }
    perform(.move(ids, toGap: gap), coalesce: nil)
  }

  /// A click on a tile (or ↑ / ↓): selects as `select` does and puts the playhead at the primary clip's In.
  public func selectAndSeek(_ id: UUID, extend: Bool, toggle: Bool) {
    select(id, extend: extend, toggle: toggle)
    guard let primary = selection.primary,
          let start = plan?.placements.first(where: { $0.clipID == primary })?.reelSpan.start
    else { return }
    seek(reelTime: start)
  }

  // MARK: joins

  /// A click on the join into `id`: cut → Short → Long → cut, one step each. Nothing on the first clip.
  public func clickJoin(_ id: UUID) {
    guard let reel, let i = reel.index(of: id), i > 0 else { return }
    let next: Join
    switch reel.clips[i].join {
    case .cut: next = .crossfade(Limits.shortFade)
    case .crossfade(let t): next = t <= Limits.shortFade ? .crossfade(Limits.longFade) : .cut
    }
    perform(.setJoin(id, next), coalesce: nil)
  }

  // MARK: Finder

  /// Finder files over the strip at `p` (the caret marks the gap they'd go in), or over the rest of the window
  /// (nil: the armed hairline frame; a drop appends).
  public func finderDragOver(at p: CGPoint?, count: Int) {
    guard modals.top == nil else { return }  // a drop now is refused: no caret, no armed frame
    guard let p, reel?.clips.isEmpty == false else {
      if case .finder? = activeDrag?.kind { activeDrag = nil }
      if !dropArmed { dropArmed = true }
      return
    }
    if dropArmed { dropArmed = false }
    let gap = stripLayout().gap(at: p.x)
    if case .finder? = activeDrag?.kind {
      activeDrag?.kind = .finder(count: count)
      activeDrag?.current = p
      activeDrag?.caretGap = gap
    } else {
      activeDrag = StripDrag(kind: .finder(count: count), start: p, current: p, caretGap: gap)
    }
  }

  /// The files left the strip (`strip`) or the window.
  public func finderDragLeft(strip: Bool) {
    if strip {
      if case .finder? = activeDrag?.kind { activeDrag = nil }
    } else if dropArmed {
      dropArmed = false
    }
  }

  /// The drop: through `importURLs` at the caret's gap, or appended when it isn't over the strip. Every import rule
  /// applies (skipped files, `.trimlab` opens, refused during an export).
  @discardableResult
  public func finderDrop(_ urls: [URL]) -> Task<Void, Never> { finderDrop(loading: { urls }) }

  /// The drop, for files whose URLs arrive later (the view's item providers): where it lands is taken now, then
  /// the URLs are awaited and imported as `finderDrop(_:)` does.
  @discardableResult
  public func finderDrop(loading urls: @escaping @MainActor () async -> [URL]) -> Task<Void, Never> {
    let gap = endFinderDrag()
    return Task {
      let loaded = await urls()
      guard !loaded.isEmpty else { return }
      await self.importURLs(loaded, at: gap).value
    }
  }

  /// Ends the Finder drag (caret and armed frame) and returns the gap a drop lands in: nil appends.
  private func endFinderDrag() -> Int? {
    var gap: Int?
    if case .finder? = activeDrag?.kind {
      gap = activeDrag?.caretGap
      activeDrag = nil
    }
    if dropArmed { dropArmed = false }
    return gap
  }

  // MARK: zoom and scroll

  /// ⌥⌘= / ⌥⌘− and the transport's "− Zoom +": ×1.5 per step from the real px/s (Fit's too), to 200 px/s; out
  /// past Fit is Fit. Around the playhead when it's in view, else the strip's middle.
  public func stripZoomStep(_ d: Int) {
    guard d != 0 else { return }
    let layout = stripLayout()
    let x = layout.x(for: playhead)
    let anchor = x >= 0 && x <= layout.width ? x : layout.width / 2
    zoomStrip(by: pow(1.5, CGFloat(d)), around: anchor)
  }

  /// ⌥⌘0: Fit.
  public func stripZoomFit() {
    stripZoom = .fit
    stripScrollX = 0
  }

  /// Pinch and ⌘-scroll: the px/s times `factor`, keeping the time under `x` where it is.
  public func zoomStrip(by factor: CGFloat, around x: CGFloat) {
    let layout = stripLayout()
    guard !layout.tiles.isEmpty, factor > 0, factor.isFinite else { return }
    let fit = layout.fits ? layout.pxPerSecond : layoutStrip(zoom: .fit).pxPerSecond
    let target = min(layout.pxPerSecond * factor, StripLayout.maxPxPerSecond)
    let t = layout.time(at: x)
    if target <= fit * (1 + 1e-9) {
      stripZoomFit()
      return
    }
    stripZoom = .pxPerSecond(Double(target))
    stripScrollX = 0
    setStripScroll(stripLayout().x(for: t) - x)
  }

  /// A two-finger swipe (zoomed only): `dx` px further along the Reel.
  public func stripScroll(by dx: CGFloat) {
    guard stripZoom != .fit else { return }
    setStripScroll(stripLayout().scrollX + dx)
  }

  /// A scroll-wheel event from the app at `point` in the window (the same space as `stripFrame`). Used only over the
  /// strip with no modal on top: ⌘ zooms around the pointer; otherwise it scrolls when zoomed. `precise`
  /// (trackpad) deltas are px, others lines. Returns whether the strip used it.
  public func stripScrollWheel(dx: CGFloat, dy: CGFloat, command: Bool, precise: Bool, at point: CGPoint) -> Bool {
    guard let frame = stripFrame, frame.contains(point), modals.top == nil, reel?.clips.isEmpty == false
    else { return false }
    if command {
      let steps = precise ? dy / 100 : max(-1, min(1, dy))
      if steps != 0 { zoomStrip(by: pow(1.5, steps), around: point.x - frame.minX) }
      return true
    }
    guard stripZoom != .fit else { return false }
    let d = abs(dx) >= abs(dy) ? dx : dy
    stripScroll(by: -(precise ? d : d * 10))
    return true
  }

  /// Zoomed playback pages: a playhead that leaves the strip comes back `stripPageMargin` inside the edge it
  /// travels away from.
  func pageStripToPlayhead() {
    guard stripZoom != .fit, stripWidth > 0 else { return }
    let layout = stripLayout()
    let x = layout.x(for: playhead)
    guard x < 0 || x >= layout.width else { return }
    let lead = currentRate < 0 ? layout.width - Self.stripPageMargin : Self.stripPageMargin
    setStripScroll(layout.scrollX + x - lead)
  }

  /// Sets the scroll, clamped to the content.
  private func setStripScroll(_ x: CGFloat) {
    stripScrollX = x
    let clamped = stripLayout().scrollX
    if clamped != x { stripScrollX = clamped }
  }

  // MARK: auto-scroll

  /// Zoomed, a reorder within `StripDrag.autoScrollEdge` of an edge scrolls a step every tick of `clock`.
  private func updateAutoScroll() {
    guard let drag = activeDrag, case .reorder = drag.kind, stripZoom != .fit,
          StripDrag.autoScrollStep(at: drag.current.x, width: stripWidth) != 0
    else {
      stopAutoScroll()
      return
    }
    if pendingAutoScroll == nil { scheduleAutoScrollTick() }
  }

  private func stopAutoScroll() {
    autoScrollSleep?.cancel()
    autoScrollSleep = nil
    pendingAutoScroll?.cancel()
    pendingAutoScroll = nil
  }

  private func scheduleAutoScrollTick() {
    let current: any Clock<Duration> = clock
    let elapsed = sleeper(until: StripDrag.autoScrollTick, on: current)
    autoScrollSleep = elapsed
    pendingAutoScroll = Task { [weak self] in
      guard await elapsed.value, !Task.isCancelled else { return }
      self?.autoScrollTick()
    }
  }

  private func autoScrollTick() {
    pendingAutoScroll = nil
    autoScrollSleep = nil
    guard let drag = activeDrag, case .reorder = drag.kind, stripZoom != .fit else { return }
    let step = StripDrag.autoScrollStep(at: drag.current.x, width: stripWidth)
    guard step != 0 else { return }
    let before = stripLayout().scrollX
    setStripScroll(before + step)
    let after = stripLayout()
    activeDrag?.caretGap = after.gap(at: drag.current.x)
    if after.scrollX != before { scheduleAutoScrollTick() }  // at the end it rests until the pointer moves
  }
}
