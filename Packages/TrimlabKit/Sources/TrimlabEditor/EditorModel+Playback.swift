import AVFoundation
import Foundation
import TrimlabMedia
import TrimlabModel

/// §4.2, §5.3. One playhead in Reel time drives the stage; the preview engine follows the model. Selection follows
/// the playhead only while paused: pausing, a seek or a step selects the clip under the playhead (the incoming one
/// in a crossfade overlap); playback itself never changes it.
extension EditorModel {
  /// Fastest shuttle, either way (J/L repeat: 1×, 2×, 4×).
  static let maxShuttle: Double = 4

  public var isPlaying: Bool {
    if case .playing = playState { true } else { false }
  }

  /// The playing rate; 0 while paused.
  var currentRate: Double {
    if case .playing(let r) = playState { r } else { 0 }
  }

  // MARK: transport

  /// Space: plays from the playhead at 1×. From peek, from the selected clip's In; from the last frame, from 0:00.
  public func play() { startPlaying(rate: 1) }

  public func pause() {
    if isPlaying { preview.setRate(0) }
    playState = .paused
    selectUnderPlayhead()
  }

  public func togglePlay() { if isPlaying { pause() } else { play() } }

  /// J / K / L. L plays forward, and doubles while it already does (to 4×); J the same backwards; K stops. J at
  /// 0:00 does nothing: reverse stops at the start (v1 ruling).
  public func shuttle(_ d: ShuttleDir) {
    let r = currentRate
    switch d {
    case .stop:
      pause()
    case .forward:
      startPlaying(rate: r > 0 ? min(r * 2, Self.maxShuttle) : 1)
    case .back:
      if r >= 0, playhead <= .zero, peek == nil { return }
      startPlaying(rate: r < 0 ? max(r * 2, -Self.maxShuttle) : -1)
    }
  }

  /// Moves the playhead (clamped to `[0, total − frame]`) and lands the preview there exactly. Ends a peek; while
  /// paused, selects the clip under the playhead (during playback the selection stays put).
  public func seek(reelTime t: RationalTime) {
    guard let plan else { return }
    if peek != nil { endPeek() }
    playhead = Self.clamped(t, in: plan)
    seekPreview()
    if !isPlaying { selectUnderPlayhead() }
  }

  /// ← / →: one frame (Reel frames; source frames in peek). Pauses playback.
  public func step(_ frames: Int) {
    if let peek, let clip = reel?.clips.first(where: { $0.id == peek.clipID }) {
      self.peek(sourceTime: peek.sourceTime + clip.facts.frameDuration * Int64(frames))
      return
    }
    guard let plan else { return }
    if isPlaying { pause() }
    seek(reelTime: playhead + plan.frameDuration * Int64(frames))
  }

  /// ⇧← / ⇧→ and the transport's ◀◀ ▶▶: `seconds` along the Reel. Playback carries on, selection with it.
  public func jump(_ seconds: Int) {
    seek(reelTime: playhead + RationalTime(Int64(seconds), 1))
  }

  /// The deck's peek (§4.2): shows the selected clip's source frame at `sourceTime` from its scrub player and parks
  /// the Reel playhead on the clip's nearest kept frame. Pauses playback.
  public func peek(sourceTime t: RationalTime) {
    guard let reel, let plan, let id = selection.primary, let clip = reel.clips.first(where: { $0.id == id })
    else { return }
    if isPlaying {
      preview.setRate(0)
      playState = .paused
    }
    let fd = clip.facts.frameDuration
    let source = min(max(t, .zero), Self.lastFrameStart(clip))
    peek = Peek(clipID: id, sourceTime: source)
    if let placement = plan.placements.first(where: { $0.clipID == id }) {
      let kept = min(max(source, clip.inTime), max(clip.outTime - fd, clip.inTime))
      let parked = Self.clamped(placement.reelSpan.start + (kept - clip.inTime), in: plan)
      // A drag peeks on every event; the hidden Reel player seeks only when the parked frame moves.
      if parked != playhead {
        playhead = parked
        seekPreview()
      }
    }
    showPeekFrame(clip, at: source)
  }

  /// Back to the Reel on the stage.
  public func endPeek() {
    peekGeneration += 1
    peek = nil
    peekPlayer = nil
  }

  // MARK: switches

  /// A: the export setting, and the preview mutes with it. Not an undo step (export settings never are, Task 13).
  public func toggleRemoveAudio() {
    guard let reel else { return }
    perform(.setRemoveAudio(!reel.export.removeAudio), coalesce: nil, record: false)
  }

  /// \: Loop Reel.
  public func toggleLoop() {
    prefs.loop.toggle()
    preview.loop = prefs.loop
  }

  /// A click on the transport timecode: `m:ss.ff` ↔ `12.40 s`.
  public func toggleTCMode() {
    prefs.tcMode = prefs.tcMode == .timecode ? .seconds : .timecode
  }

  // MARK: internals

  private func startPlaying(rate: Double) {
    // A handle held: the stage is showing its frame and the release returns to In; Space and J / L wait.
    guard deckGrab == nil, let plan, !plan.placements.isEmpty else { return }
    if let peek {
      let inPoint = plan.placements.first { $0.clipID == peek.clipID }?.reelSpan.start
      endPeek()
      if let inPoint {
        playhead = Self.clamped(inPoint, in: plan)
        seekPreview()
      }
    } else if rate > 0, playhead >= Self.lastFrame(of: plan) {
      playhead = .zero
      seekPreview()
    }
    playState = .playing(rate: rate)
    preview.setRate(rate)
  }

  func seekPreview() {
    let t = playhead
    let preview = self.preview
    pendingSeek = Task { _ = await preview.seek(t) }
  }

  /// The engine's clock during playback, floored onto the Reel's frame grid. Ignored while paused (a seek or a
  /// swapped item reports its own times).
  func previewTime(_ t: RationalTime) {
    guard isPlaying, let plan else { return }
    playhead = Self.clamped(t.floored(toFrame: plan.frameDuration), in: plan)
    pageStripToPlayhead()
    pageDeckToPlayhead()
  }

  /// Playback stopped by itself: on the last frame going forward, at 0:00 in reverse.
  func previewEnded() {
    guard let plan else { return }
    let reversing = currentRate < 0
    playState = .paused
    playhead = reversing ? .zero : Self.lastFrame(of: plan)
    seekPreview()
    selectUnderPlayhead()
  }

  /// The selection rule after a recorded edit, an undo or a redo while paused (Phase 4 review I4): when the clip under
  /// the playhead isn't the primary, the playhead goes to the primary's In, as `selectAndSeek` would. Returns
  /// whether it moved; the caller shows or seeks the preview.
  func followPrimary() -> Bool {
    guard !isPlaying, peek == nil, let plan, let primary = selection.primary,
          let start = plan.placements.first(where: { $0.clipID == primary })?.reelSpan.start,
          Self.clip(at: playhead, in: plan) != primary
    else { return false }
    playhead = Self.clamped(start, in: plan)
    return true
  }

  /// The clip under the playhead becomes the selection (kept as it is when it already leads it).
  func selectUnderPlayhead() {
    guard let plan, let id = Self.clip(at: playhead, in: plan), selection.primary != id else { return }
    if let peek, peek.clipID != id { endPeek() }
    selection = Selection(primary: id, all: [id])
    anchor = id
  }

  /// The clip on screen at Reel time `t`: in a crossfade overlap the incoming one (the later placement).
  static func clip(at t: RationalTime, in plan: CompositionPlan) -> UUID? {
    if let hit = plan.placements.last(where: { $0.reelSpan.start <= t && t < $0.reelSpan.end }) { return hit.clipID }
    return t >= plan.total ? plan.placements.last?.clipID : plan.placements.first?.clipID
  }

  static func lastFrame(of plan: CompositionPlan) -> RationalTime {
    max(plan.total - plan.frameDuration, .zero)
  }

  static func clamped(_ t: RationalTime, in plan: CompositionPlan) -> RationalTime {
    min(max(t, .zero), lastFrame(of: plan))
  }

  /// After every change to the plan: the same Reel time (clamped), or a trimmed primary clip's In, with the play
  /// state as it was. The preview mutes with Remove audio.
  func refreshPreview(after edit: ReelEdit?) {
    guard let plan, let reel else {
      showPreview(Planner.plan(.empty(name: "")))
      return
    }
    if let edit, let id = Self.trimmedClip(edit), id == selection.primary,
       let placement = plan.placements.first(where: { $0.clipID == id }) {
      if peek != nil { endPeek() }
      playhead = placement.reelSpan.start
    }
    playhead = Self.clamped(playhead, in: plan)
    preview.muted = reel.export.removeAudio
    showPreview(plan)
  }

  static func trimmedClip(_ edit: ReelEdit) -> UUID? {
    switch edit {
    case .setIn(let id, _), .setOut(let id, _), .resetIn(let id), .resetOut(let id): id
    default: nil
    }
  }

  /// Hands `plan` to the preview once its assets are loaded. A newer request made meanwhile wins. The playhead and
  /// play state are read when the assets are in, not when asked: a pause or seek during the load holds (review I3).
  private func showPreview(_ plan: CompositionPlan) {
    previewGeneration += 1
    let generation = previewGeneration
    pendingPreview = Task { [weak self] in
      guard let self else { return }
      let assets = await self.assets(for: plan)
      // If the Reel was closed meanwhile this is the last reference to them: let them go off the main actor.
      guard generation == self.previewGeneration else { return Offload.release(consume assets) }
      let at = self.reel == nil ? .zero : self.playhead
      await self.preview.show(plan, assets: assets, at: at, play: self.isPlaying)
      Offload.release(consume assets)
    }
  }

  /// Each placed clip's asset, for the file `url(for:)` names, loaded once per file.
  private func assets(for plan: CompositionPlan) async -> [UUID: AVURLAsset] {
    let clips = Dictionary((reel?.clips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out: [UUID: AVURLAsset] = [:]
    for placement in plan.placements {
      guard let clip = clips[placement.clipID], let asset = await asset(for: clip) else { continue }
      out[clip.id] = asset
    }
    return out
  }

  private func asset(for clip: ReelClip) async -> AVURLAsset? {
    guard let url = url(for: clip.id) else { return nil }
    if let hit = session.assetCache[url] { return hit }
    if let loading = session.assetLoads[url] { return await loading.value }
    let media = self.media
    let sessionID = session.id
    let load = Task<AVURLAsset?, Never> { try? await media.asset(clip, at: url) }
    session.assetLoads[url] = load
    let made = await load.value
    // A reset meanwhile started a new session: this asset belongs to no Reel now. The caller is stale and drops
    // it; never cache it in the new session, and let the load go off the main actor.
    guard session.id == sessionID else {
      Offload.release(consume load)
      return made
    }
    if session.assetLoads[url] == load { session.assetLoads[url] = nil }
    guard let made else { return nil }
    // Something filled the slot meanwhile (a relink): keep what is there, and let this load and its asset go off
    // the main actor (`Offload`) rather than drop them here.
    if let landed = session.assetCache[url] {
      Offload.release((consume made, consume load))
      return landed
    }
    session.assetCache[url] = made
    return made
  }

  private func showPeekFrame(_ clip: ReelClip, at t: RationalTime) {
    peekGeneration += 1
    let generation = peekGeneration
    Task { [weak self] in
      guard let self, let asset = await self.asset(for: clip) else { return }
      guard generation == self.peekGeneration else { return }
      let player = self.scrub.player(for: clip.id, asset: asset)
      if self.peekPlayer !== player { self.peekPlayer = player }
      await self.scrub.seek(clip.id, to: t)
    }
  }
}
