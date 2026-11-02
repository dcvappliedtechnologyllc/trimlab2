import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import TrimlabModel

/// §4.2, §5.3. Plays the composited Reel: the same `CompositionBuilder` + `ReelCompositor` path as export, so the
/// preview shows what export writes (the flash fix and the v1 HDR LUT included).
///
/// After an edit the caller hands over the new plan with `show`: the composition is built off the main actor, a
/// new `AVPlayerItem` is made here on the main actor (F22), it replaces the current one, and an exact seek puts
/// the playhead back. Rebuilds coalesce: at most one is in flight, and while it runs only the latest request is
/// kept; a build that has been overtaken is thrown away instead of shown.
@MainActor
public final class PreviewEngine {
  public let player = AVPlayer()
  /// The Reel time during playback, every Reel frame. Quiet while an item is being swapped in.
  public var onTime: (@MainActor (RationalTime) -> Void)?
  /// Playback stopped by itself: the end with loop off, or 0:00 in reverse.
  public var onEnd: (@MainActor () -> Void)?
  /// Loop Reel (§4.2): at the end, wrap to 0:00 and keep playing.
  public var loop = true
  public var muted: Bool {
    get { player.isMuted }
    set { player.isMuted = newValue }
  }

  /// The plan on screen (nil before the first `show`).
  public private(set) var shownPlan: CompositionPlan?
  /// Builds started so far (tests check the coalescing with it).
  public private(set) var buildCount = 0
  /// Test seam: runs on each new item before it goes into the player (e.g. to add an `AVPlayerItemVideoOutput`).
  var itemPrepared: ((AVPlayerItem) -> Void)?
  /// How long a new item may take to become ready before it's dropped, so the drain never waits forever.
  var readyTimeout: Duration = .seconds(5)
  /// The item for a built composition (a seam: tests swap in one that never becomes ready).
  var makeItem: @MainActor (BuiltComposition) -> AVPlayerItem = PreviewEngine.defaultItem

  static let defaultItem: @MainActor (BuiltComposition) -> AVPlayerItem = { built in
    let item = AVPlayerItem(asset: built.composition)
    item.videoComposition = built.videoComposition
    item.audioMix = built.audioMix
    return item
  }

  private struct Request {
    let plan: CompositionPlan
    let assets: [UUID: AVURLAsset]
    let at: RationalTime
    let play: Bool
  }

  /// The newest request not yet taken by the drain loop.
  private var pending: Request?
  /// Where the playhead should land and whether to play once the item in flight is in: the last `show`, updated
  /// by any `seek` or `setRate` that comes in while it builds, so a click or Space during a rebuild isn't lost.
  private var wantAt = RationalTime.zero
  private var wantPlay = false
  /// The drain loop, while it runs.
  private var drain: Task<Void, Never>?
  /// The rate asked for (0 = paused); `playRate` is the last non-zero one, which `show(play: true)` resumes.
  private var rate: Double = 0
  private var playRate: Double = 1
  /// True while an item is swapped in, so the time observer doesn't report the new item's 0:00.
  private var swapping = false
  private var timeObserver: Any?
  private var observedFrame: RationalTime?
  private var endObserver: (any NSObjectProtocol)?
  private var rateObservation: NSKeyValueObservation?

  public init() {
    player.automaticallyWaitsToMinimizeStalling = false
    player.actionAtItemEnd = .pause
    // Reverse play ends at `reversePlaybackEndTime` (0:00) with the player stopped: no end notification, and the
    // last time callback may come a little before 0:00. The rate itself drops to 0 (KVO, from any thread).
    rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
      guard change.newValue == 0 else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, !self.swapping, self.rate < 0, self.player.rate == 0 else { return }
          self.reachedStart()
        }
      }
    }
  }

  isolated deinit {
    let item = player.currentItem
    player.replaceCurrentItem(with: nil)
    Offload.release(item: item)
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    rateObservation?.invalidate()
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
  }

  // MARK: show

  /// Shows `plan` at Reel time `t` (clamped to `[0, total − frame]`), paused or playing. Returns once the request
  /// that is newest when the drain loop goes idle has landed (or immediately for a request overtaken meanwhile).
  public func show(_ plan: CompositionPlan, assets: [UUID: AVURLAsset], at t: RationalTime, play: Bool) async {
    let replaced = pending
    pending = Request(plan: plan, assets: assets, at: t, play: play)
    Offload.release(consume replaced)  // a request overtaken here may hold the last references (`Offload`)
    wantAt = t
    wantPlay = play
    if drain == nil {
      drain = Task { [weak self] in await self?.runDrain() }
    }
    await drain?.value
  }

  private func runDrain() async {
    while let request = pending {
      pending = nil
      await install(request)
      Offload.release(consume request)  // may hold the last reference to its assets (`Offload`)
    }
    drain = nil
  }

  private func install(_ request: Request) async {
    let plan = request.plan
    guard !plan.placements.isEmpty else {
      setPlayerRate(0)
      let previous = player.currentItem
      player.replaceCurrentItem(with: nil)
      Offload.release(item: previous)  // after New Reel or Open: the old Reel's last references (`Offload`)
      shownPlan = plan
      return
    }
    buildCount += 1
    let built: BuiltComposition
    do {
      built = try await Self.build(plan, assets: request.assets)
    } catch {
      MediaLog.note("preview: build failed (\(error)); the previous item stays")
      return
    }
    if pending != nil { return }  // overtaken while building: discard

    let item = makeItem(built)
    item.reversePlaybackEndTime = .zero
    itemPrepared?(item)

    swapping = true
    defer { swapping = false }
    player.rate = 0
    let previous = player.currentItem
    player.replaceCurrentItem(with: item)
    Offload.release(item: previous)  // its composition holds the old assets (`Offload`)
    observeEnd(of: item)
    observeTime(every: plan.frameDuration)
    guard await Self.ready(item, timeout: readyTimeout) else {
      MediaLog.note(item.status == .failed
        ? "preview: item failed (\(String(describing: item.error))); dropped"
        : "preview: item not ready after \(readyTimeout); dropped")
      item.asset.cancelLoading()  // a stuck load would otherwise hold up the player's next item
      if player.currentItem === item {
        player.replaceCurrentItem(with: nil)
        shownPlan = nil
      }
      Offload.release(item: item)  // dropped: its composition holds the Reel's assets (`Offload`)
      return
    }
    if pending != nil { return }  // the next request replaces this item anyway
    shownPlan = plan
    _ = await exactSeek(clamped(wantAt, in: plan))
    if pending != nil { return }
    if wantPlay {
      setPlayerRate(playRate)
    } else {
      rate = 0
    }
  }

  @concurrent
  private static func build(_ plan: CompositionPlan, assets: [UUID: AVURLAsset]) async throws -> BuiltComposition {
    try await CompositionBuilder.build(plan, assets: assets)
  }

  /// Waits for `item` to become ready to play: false if it fails or `timeout` passes first.
  private static func ready(_ item: AVPlayerItem, timeout: Duration) async -> Bool {
    switch item.status {
    case .readyToPlay: return true
    case .failed: return false
    default: break
    }
    let gate = Gate()
    return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
        switch item.status {
        case .readyToPlay: gate.open(c, true)
        case .failed: gate.open(c, false)
        default: break
        }
      }
      gate.keep(observation)
      let timer = Task {
        try? await Task.sleep(for: timeout)
        gate.open(c, false)
      }
      gate.keep(timer)
    }
  }

  /// Resumes a continuation once, then drops the KVO observation and cancels the timeout.
  private final class Gate: Sendable {
    private let state = Mutex<(done: Bool, observation: NSKeyValueObservation?)>((false, nil))
    private let timer = Mutex<Task<Void, Never>?>(nil)

    func keep(_ task: Task<Void, Never>) {
      let done = state.withLock { $0.done }
      if done { task.cancel() } else { timer.withLock { $0 = task } }
    }

    func keep(_ observation: NSKeyValueObservation) {
      let drop = state.withLock { s -> Bool in
        if s.done { return true }
        s.observation = observation
        return false
      }
      if drop { observation.invalidate() }
    }

    func open(_ c: CheckedContinuation<Bool, Never>, _ value: Bool) {
      let (first, observation) = state.withLock { s -> (Bool, NSKeyValueObservation?) in
        if s.done { return (false, nil) }
        s.done = true
        defer { s.observation = nil }
        return (true, s.observation)
      }
      guard first else { return }
      observation?.invalidate()
      timer.withLock { $0?.cancel(); $0 = nil }
      c.resume(returning: value)
    }
  }

  // MARK: transport

  /// Exact (zero-tolerance) seek to Reel time `t`, clamped to the shown plan. False if it was cancelled by a later one.
  public func seek(_ t: RationalTime) async -> Bool {
    wantAt = t
    if let drain {
      // A rebuild is in flight: its item lands at `wantAt`. Then make sure (the build may have failed and left the
      // old item); a newer seek made meanwhile wins and this one reports false.
      await drain.value
      guard wantAt == t, let plan = shownPlan, player.currentItem != nil else { return false }
      if RationalTime(player.currentTime()) == clamped(t, in: plan) { return true }
      return await exactSeek(clamped(t, in: plan))
    }
    guard let plan = shownPlan, player.currentItem != nil else { return false }
    return await exactSeek(clamped(t, in: plan))
  }

  /// 0 pauses; negative plays in reverse (it stops at 0:00).
  public func setRate(_ r: Double) {
    if r < 0, player.currentTime() <= .zero {
      wantPlay = false
      setPlayerRate(0)
      return
    }
    wantPlay = r != 0
    setPlayerRate(r)
  }

  private func setPlayerRate(_ r: Double) {
    rate = r
    if r != 0 { playRate = r }
    player.rate = Float(r)
  }

  private func exactSeek(_ t: RationalTime) async -> Bool {
    await player.seek(to: CMTime(t), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  private func clamped(_ t: RationalTime, in plan: CompositionPlan) -> RationalTime {
    min(max(t, .zero), max(plan.total - plan.frameDuration, .zero))
  }

  // MARK: observers

  /// One periodic observer at the Reel's frame duration (replaced when the Reel's frame rate changes).
  private func observeTime(every frame: RationalTime) {
    guard frame != observedFrame else { return }
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    observedFrame = frame
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(frame), queue: .main) { [weak self] time in
      MainActor.assumeIsolated { self?.tick(time) }
    }
  }

  private func tick(_ time: CMTime) {
    guard !swapping else { return }
    if rate < 0, time <= .zero {
      reachedStart()
      return
    }
    onTime?(RationalTime(time))
  }

  private func observeEnd(of item: AVPlayerItem) {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.ended() }
    }
  }

  func ended() {
    // Only while playing: reverse play that already stopped at 0:00 (`reachedStart`) posts this too.
    guard !swapping, rate != 0 else { return }
    if rate < 0 {
      reachedStart()
    } else if loop, rate > 0 {
      let resume = rate
      let item = player.currentItem
      Task {
        // An edit may swap the item before this runs: the new item is not rewound or restarted.
        guard player.currentItem === item, !swapping else { return }
        _ = await exactSeek(.zero)
        // Only if nothing paused or swapped the item meanwhile.
        if rate == resume, player.currentItem === item, !swapping { player.rate = Float(resume) }
      }
    } else {
      setPlayerRate(0)
      onEnd?()
    }
  }

  /// Reverse shuttle stops at 0:00 (v1 ruling).
  private func reachedStart() {
    guard rate < 0 else { return }
    setPlayerRate(0)
    Task { _ = await exactSeek(.zero) }
    onEnd?()
  }
}
