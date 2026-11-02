import CoreGraphics
import Foundation
import TrimlabModel

/// A press on the deck not yet released: on a handle (a trim drag on `draftReel`) or anywhere else (a scrub).
struct DeckPress {
  var handle: DeckLayout.Handle?
  var clipID: UUID
  /// Pointer x less the bar's x at the press: the bar keeps its distance from the pointer (v1).
  var offset: CGFloat
  /// The deck playhead when the handle was picked up: what it snaps to, and where the deck draws its playhead
  /// while the stage shows the handle's frame.
  var snapTo: RationalTime?
  /// The draft differs from the Reel.
  var changed = false
}

/// §4.2, §4.4. The deck's pointer intents, hit-tested in the model against `deckLayout()`.
///
/// - A press on a handle picks it up: the drag moves it on `draftReel` (strip, total and 3:00 marker follow live),
///   the stage peeks at its frame, it snaps to the playhead within 6 px (⌥ disables) and stops at the minimum span
///   rather than crossing. Release is one `.setIn` / `.setOut` (coalesced per handle and clip, then `endGesture`),
///   and the playhead returns to the clip's In, as v1.
/// - A press anywhere else moves the deck playhead to that source frame; dragging scrubs. Inside the span the Reel
///   playhead goes there; outside it peeks. The selection never changes: the deck is the primary clip's.
/// - Ruling (T32 carry, v1 wins): the 20 px side margins belong to the deck. A handle at either end of the source
///   owns its tab out there (v1's 13 px reach), and a press in a margin otherwise lands on the nearest end.
extension EditorModel {
  // MARK: what the views read

  /// The Reel's total as shown: the draft's during a handle drag.
  public var displayTotal: RationalTime {
    if let draftReel { return draftPlan?.total ?? Planner.plan(draftReel, missing: missing).total }
    return plan?.total ?? reel?.total(missing: missing) ?? .zero
  }

  /// The held handle's time for the floating timecode (`m:ss.ff`): In, or Out (exclusive) as the inspector shows it.
  public var deckHandleTimecode: String? {
    guard let grab = deckGrab, let clip = deckClip else { return nil }
    return Formatting.timecode(grab == .in ? clip.inTime : clip.outTime, frame: clip.facts.frameDuration)
  }

  /// v1's 9:16 guide on the stage: in peek, for a clip wider than 9:16 that is Fill in a Reel-format export.
  public var stageGuideVisible: Bool {
    guard let peek, let reel, reel.export.format == .reel,
          let clip = reel.clips.first(where: { $0.id == peek.clipID }), clip.framing == .fill
    else { return false }
    return max(clip.facts.displayWidth, 1) * 16 > max(clip.facts.displayHeight, 1) * 9
  }

  /// The handle under `p` (the view's hover cursor).
  public func deckHandle(at p: CGPoint) -> DeckLayout.Handle? {
    guard let clip = deckClip, !deckMissing(clip) else { return nil }
    return deckLayout()?.handle(at: p)
  }

  // MARK: press, drag, release

  /// A press at `p` in deck coordinates. Pauses playback without moving the selection.
  public func deckPress(at p: CGPoint) {
    pointerPressed()
    dropDeckPress()
    guard let clip = deckClip, !deckMissing(clip), let layout = deckLayout() else { return }
    if isPlaying {
      preview.setRate(0)
      playState = .paused
    }
    guard let handle = layout.handle(at: p) else {
      deckPressed = DeckPress(handle: nil, clipID: clip.id, offset: 0)
      deckScrub(to: p.x, in: layout)
      return
    }
    if loadingClipIDs.contains(clip.id) {
      note("Wait for \(Self.fileName(clip)) to finish loading.")
      return
    }
    let bar = layout.x(forSource: handle == .in ? clip.inTime : clip.outTime)
    deckPressed = DeckPress(handle: handle, clipID: clip.id, offset: p.x - bar, snapTo: deckSourcePlayhead)
    draftReel = reel
    draftPlan = plan
    deckGrab = handle
    showHandleFrame()
  }

  /// The pointer moved with the button down; ⌥ is read from the platform.
  public func deckDrag(to p: CGPoint) {
    deckDrag(to: p, option: platform.modifierKeys().contains(.option))
  }

  /// The pointer moved with the button down. `option` (⌥) turns the snap off.
  public func deckDrag(to p: CGPoint, option: Bool) {
    guard let press = deckPressed, let layout = deckLayout() else { return }
    guard let handle = press.handle else {
      deckScrub(to: p.x, in: layout)
      return
    }
    guard let draft = draftReel, let i = draft.index(of: press.clipID) else { return }
    let clip = draft.clips[i]
    var x = p.x - press.offset
    if layout.overviewVisible { x = min(max(x, DeckLayout.pad), layout.width - DeckLayout.pad) }
    var t: RationalTime
    if let snap = press.snapTo, !option, abs(x - layout.x(forSource: snap)) <= DeckLayout.snapDistance {
      t = snap
    } else {
      t = Self.onGrid(layout.source(at: x), clip, rounding: true)
    }
    let edit: ReelEdit
    switch handle {
    case .in:
      t = min(max(t, .zero), Self.latestIn(clip))
      edit = .setIn(clip.id, t)
    case .out:
      t = max(min(t, clip.facts.duration), Self.earliestOut(clip))
      edit = .setOut(clip.id, t)
    }
    // The rules hold the handle where it is rather than throw: no note during a drag.
    guard let next = try? apply(edit, to: draft), next != draft else { return }
    draftReel = next
    draftPlan = Planner.plan(next, missing: missing)
    deckPressed?.changed = next != reel
    showHandleFrame()
  }

  /// Release: a moved handle commits one step; after any handle press the playhead returns to the clip's In.
  public func deckRelease() {
    guard let press = deckPressed else { return }
    let draft = draftReel?.clips.first { $0.id == press.clipID }
    dropDeckPress()
    guard let handle = press.handle else { return }
    if press.changed, let draft {
      let edit: ReelEdit = handle == .in ? .setIn(draft.id, draft.inTime) : .setOut(draft.id, draft.outTime)
      perform(edit, coalesce: "deck.\(handle == .in ? "in" : "out").\(draft.id.uuidString)")
      endGesture()
    }
    returnToIn(press.clipID)
  }

  /// Esc during a press: a handle drag is dropped (nothing commits) and the playhead goes back to the clip's In.
  /// Returns whether there was one.
  @discardableResult
  public func deckCancel() -> Bool {
    guard let press = deckPressed else { return false }
    dropDeckPress()
    if press.handle != nil { returnToIn(press.clipID) }
    return true
  }

  /// Forgets the press and its draft, touching nothing else (another primary, undo, a reset).
  func dropDeckPress() {
    deckPressed = nil
    if draftReel != nil { draftReel = nil }
    draftPlan = nil
    if deckGrab != nil { deckGrab = nil }
  }

  // MARK: internals

  private func deckMissing(_ clip: ReelClip) -> Bool { missing.contains(clip.id) || loading[clip.id] == .missing }

  /// A press or scrub at `x`: the source frame there. Inside the kept span the Reel playhead goes to it; outside,
  /// peek shows it and parks the Reel playhead on the nearest kept frame.
  private func deckScrub(to x: CGFloat, in layout: DeckLayout) {
    guard let id = deckPressed?.clipID, let clip = reel?.clips.first(where: { $0.id == id }) else { return }
    let t = Self.onGrid(layout.source(at: x), clip, rounding: false)
    guard t >= clip.inTime, t < clip.outTime, let plan,
          let placement = plan.placements.first(where: { $0.clipID == id })
    else {
      peek(sourceTime: t)
      return
    }
    if peek != nil { endPeek() }
    playhead = Self.clamped(placement.reelSpan.start + (t - clip.inTime), in: plan)
    seekPreview()
  }

  /// The stage shows the held handle's frame: In's first kept frame, or the last one before Out.
  private func showHandleFrame() {
    guard let grab = deckGrab, let id = deckPressed?.clipID,
          let clip = draftReel?.clips.first(where: { $0.id == id })
    else { return }
    peek(sourceTime: grab == .in ? clip.inTime : Self.frameBefore(clip.outTime, clip))
  }

  /// The Reel changed under a drag (a probe, an edit from elsewhere): the draft becomes the new Reel with the held
  /// clip's draft In and Out on it, where the rules still allow them. The held clip gone ends the press.
  func refreshDraft() {
    guard let press = deckPressed, let old = draftReel?.clips.first(where: { $0.id == press.clipID }),
          let reel, let i = reel.index(of: press.clipID)
    else {
      dropDeckPress()
      return
    }
    let id = reel.clips[i].id
    let inFirst = (try? apply(.setOut(id, old.outTime), to: apply(.setIn(id, old.inTime), to: reel)))
    let outFirst = (try? apply(.setIn(id, old.inTime), to: apply(.setOut(id, old.outTime), to: reel)))
    let next = inFirst ?? outFirst ?? reel
    draftReel = next
    draftPlan = Planner.plan(next, missing: missing)
    deckPressed?.changed = next != reel
  }

  /// Peek off, the playhead on the clip's In.
  private func returnToIn(_ id: UUID) {
    if peek != nil { endPeek() }
    guard let plan, let start = plan.placements.first(where: { $0.clipID == id })?.reelSpan.start else { return }
    let at = Self.clamped(start, in: plan)
    if playhead != at {
      playhead = at
      seekPreview()
    }
  }

  /// A source time on the clip's frame grid (rounded to the nearest frame edge for a handle, floored to the frame
  /// under it for a scrub), never past the clip's last frame for a scrub.
  static func onGrid(_ t: RationalTime, _ clip: ReelClip, rounding: Bool) -> RationalTime {
    let fd = clip.facts.frameDuration
    guard fd.value > 0, fd.timescale > 0 else { return t }
    let duration = clip.facts.duration
    if rounding { return t >= duration ? duration : min(t.rounded(toFrame: fd), duration) }
    return min(t.floored(toFrame: fd), lastFrameStart(clip))
  }

  /// The start of the last frame before `t` (exclusive), never past the clip's last frame: for Out, which may sit
  /// off the frame grid at the duration.
  static func frameBefore(_ t: RationalTime, _ clip: ReelClip) -> RationalTime {
    let fd = clip.facts.frameDuration
    guard fd.value > 0, fd.timescale > 0 else { return max(t - fd, .zero) }
    let floor = t.floored(toFrame: fd)
    return max(min(floor < t ? floor : floor - fd, lastFrameStart(clip)), .zero)
  }

  /// The start of the clip's last source frame (its duration may sit off the frame grid).
  static func lastFrameStart(_ clip: ReelClip) -> RationalTime {
    let fd = clip.facts.frameDuration, duration = clip.facts.duration
    guard fd.value > 0, fd.timescale > 0 else { return max(duration - fd, .zero) }
    let floor = duration.floored(toFrame: fd)
    return max(floor < duration ? floor : floor - fd, .zero)
  }

  /// The latest In that keeps the minimum span: a frame start.
  static func latestIn(_ clip: ReelClip) -> RationalTime {
    let latest = clip.outTime - min(Limits.minSpan, clip.facts.duration)
    let fd = clip.facts.frameDuration
    return fd.value > 0 && fd.timescale > 0 ? latest.floored(toFrame: fd) : latest
  }

  /// The earliest Out that keeps the minimum span: a frame start, or the duration.
  static func earliestOut(_ clip: ReelClip) -> RationalTime {
    let earliest = clip.inTime + min(Limits.minSpan, clip.facts.duration)
    let fd = clip.facts.frameDuration
    guard fd.value > 0, fd.timescale > 0 else { return earliest }
    let floor = earliest.floored(toFrame: fd)
    return min(floor < earliest ? floor + fd : floor, clip.facts.duration)
  }
}
