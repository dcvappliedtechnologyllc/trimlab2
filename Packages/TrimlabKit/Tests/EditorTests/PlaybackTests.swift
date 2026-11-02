import AppKit
import Foundation
import Observation
import Synchronization
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 27: playback intents over the `PreviewDriving` stub (§4.2, §5.3). Three 10 s clips at 29.97 unless a test
/// says otherwise, so a, b and c sit at 0, 10 and 20 s.
@MainActor @Suite struct PlaybackTests {
  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }  // the transport's views

  private func seconds(_ s: Int64) -> RationalTime { RationalTime(s, 1) }

  private func threeClips() async throws -> (Harness, [UUID]) {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov", "c.mov"])
    await h.model.pendingPreview?.value
    let ids = try #require(h.model.reel?.clips.map(\.id))
    try #require(ids.count == 3)
    return (h, ids)
  }

  @Test func selectionFollowsPlayheadOnPause() async throws {
    let (h, ids) = try await threeClips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.play()
    #expect(h.model.playState == .playing(rate: 1))
    let fd = try #require(h.model.plan?.frameDuration)
    h.preview.onTime?(RationalTime(12, 1))  // playing across the a|b join
    #expect(h.model.playhead == seconds(12).floored(toFrame: fd))
    #expect(h.model.selection.primary == ids[0], "playback never moves the selection")
    h.model.pause()
    #expect(h.model.playState == .paused)
    #expect(h.preview.rate == 0)
    #expect(h.model.selection.primary == ids[1])
    #expect(h.model.selection.all == [ids[1]])
  }

  @Test func overlapSelectsIncoming() async throws {
    let (h, ids) = try await threeClips()
    #expect(h.model.perform(.setJoin(ids[1], .crossfade(Limits.longFade)), coalesce: nil))
    // a is [0, 10), b now starts at 9: [9, 10) is the overlap.
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.seek(reelTime: RationalTime(19, 2))
    await h.model.pendingSeek?.value
    #expect(h.model.playhead == RationalTime(19, 2))
    #expect(h.model.selection.primary == ids[1])
    #expect(h.preview.seeks.last == RationalTime(19, 2))
    h.model.seek(reelTime: RationalTime(17, 2))
    #expect(h.model.selection.primary == ids[0])
  }

  @Test func seekClampsToLastFrame() async throws {
    let (h, _) = try await threeClips()
    let fd = try #require(h.model.plan?.frameDuration)
    h.model.seek(reelTime: seconds(99))
    #expect(h.model.playhead == seconds(30) - fd)
    h.model.seek(reelTime: seconds(-3))
    #expect(h.model.playhead == .zero)
  }

  @Test func stepAndJump() async throws {
    let (h, ids) = try await threeClips()
    let fd = try #require(h.model.plan?.frameDuration)
    h.model.step(1)
    #expect(h.model.playhead == fd)
    h.model.step(-5)
    #expect(h.model.playhead == .zero)
    h.model.jump(11)
    #expect(h.model.playhead == seconds(11))
    #expect(h.model.selection.primary == ids[1])
  }

  @Test func editRestoresTimeAndPlayState() async throws {
    let (h, ids) = try await threeClips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.play()
    let fd = try #require(h.model.plan?.frameDuration)
    h.preview.onTime?(seconds(12))
    #expect(h.model.perform(.setOut(ids[2], seconds(8)), coalesce: nil))
    await h.model.pendingPreview?.value
    let last = try #require(h.preview.shown.last)
    #expect(last.at == seconds(12).floored(toFrame: fd))
    #expect(last.play)
    #expect(last.plan == h.model.plan)
    let c = try #require(h.model.reel?.clips[2])
    #expect(c.outTime == seconds(8).floored(toFrame: c.facts.frameDuration))
    #expect(last.plan.total == seconds(20) + c.trimmed)
    #expect(h.preview.assetIDs.last == Set(ids))
    #expect(h.model.playState == .playing(rate: 1))
  }

  @Test func trimReturnsPlayheadToClipIn() async throws {
    let (h, ids) = try await threeClips()
    h.model.select(ids[1], extend: false, toggle: false)
    h.model.seek(reelTime: seconds(15))
    #expect(h.model.perform(.setIn(ids[1], seconds(2)), coalesce: nil))
    await h.model.pendingPreview?.value
    #expect(h.model.playhead == seconds(10))
    #expect(h.preview.shown.last?.at == seconds(10))
    #expect(h.preview.shown.last?.play == false)
  }

  /// Many edits in one turn reach the engine as one `show` of the last plan.
  @Test func editsCoalesceToLatest() async throws {
    let (h, ids) = try await threeClips()
    let before = h.preview.shown.count
    for s in 3...7 { h.model.perform(.setOut(ids[2], seconds(Int64(s))), coalesce: "trim") }
    await h.model.pendingPreview?.value
    #expect(h.preview.shown.count == before + 1)
    let c = try #require(h.model.reel?.clips[2])
    #expect(c.outTime == seconds(7).floored(toFrame: c.facts.frameDuration))
    #expect(h.preview.shown.last?.plan == h.model.plan)
  }

  /// The engine's clock lands between frames; the playhead stays on the Reel's frame grid.
  @Test func playbackTickSnapsToFrame() async throws {
    let (h, _) = try await threeClips()
    let fd = try #require(h.model.plan?.frameDuration)
    h.model.play()
    let offGrid = fd * 100 + RationalTime(1, 1000)
    h.preview.onTime?(offGrid)
    #expect(h.model.playhead == fd * 100)
  }

  /// Selection follows the playhead only while paused: ⇧→ / ▶▶ during playback leave it alone.
  @Test func jumpWhilePlayingKeepsSelection() async throws {
    let (h, ids) = try await threeClips()
    h.model.select(ids[0], extend: false, toggle: false)
    h.model.play()
    h.model.jump(11)
    #expect(h.model.playhead == seconds(11))
    #expect(h.model.selection.primary == ids[0])
    #expect(h.model.isPlaying)
    h.model.pause()
    #expect(h.model.selection.primary == ids[1])
  }

  /// A note goes by itself after `NoteLine.lifetime` on the model's clock.
  @Test func notesDismissOnModelClock() async throws {
    let h = Harness()
    h.model.note("Skipped 1 file trimlab can't open.")
    #expect(h.model.notes.count == 1)
    h.clock.advance(by: NoteLine.lifetime - .seconds(1))
    await h.clock.waitForParked(1)  // the dismissal is parked short of its deadline: it can't run
    #expect(h.clock.parkedSleepers == 1)
    #expect(h.model.notes.count == 1)
    h.clock.advance(by: .seconds(1))
    await h.model.pendingNoteDismissal?.value
    #expect(h.model.notes.isEmpty)
  }

  @Test func shuttleRates() async throws {
    let (h, _) = try await threeClips()
    h.model.shuttle(.forward)
    #expect(h.preview.rate == 1)
    h.model.shuttle(.forward)
    #expect(h.preview.rate == 2)
    h.model.shuttle(.forward)
    #expect(h.preview.rate == 4)
    h.model.shuttle(.forward)
    #expect(h.preview.rate == 4, "4× is the fastest")
    #expect(h.model.playState == .playing(rate: 4))
    h.model.shuttle(.stop)
    #expect(h.preview.rate == 0)
    #expect(h.model.playState == .paused)

    h.model.seek(reelTime: .zero)
    let count = h.preview.rates.count
    h.model.shuttle(.back)
    #expect(h.preview.rates.count == count, "J at 0:00 does nothing")
    #expect(h.model.playState == .paused)

    h.model.seek(reelTime: seconds(5))
    h.model.shuttle(.back)
    #expect(h.preview.rate == -1)
    h.model.shuttle(.back)
    #expect(h.preview.rate == -2)
    h.model.shuttle(.forward)
    #expect(h.preview.rate == 1, "L while reversing plays forward at 1×")
  }

  /// Reverse shuttle ends at 0:00; forward without loop ends on the last frame.
  @Test func endParksPlayhead() async throws {
    let (h, _) = try await threeClips()
    let fd = try #require(h.model.plan?.frameDuration)
    h.model.play()
    h.preview.onEnd?()
    #expect(h.model.playState == .paused)
    #expect(h.model.playhead == seconds(30) - fd)
    h.model.seek(reelTime: seconds(3))
    h.model.shuttle(.back)
    h.preview.onEnd?()
    #expect(h.model.playhead == .zero)
    #expect(h.model.playState == .paused)
  }

  @Test func playFromEndStartsAtZero() async throws {
    let (h, _) = try await threeClips()
    h.model.seek(reelTime: seconds(30))
    h.model.play()
    await h.model.pendingSeek?.value
    #expect(h.model.playhead == .zero)
    #expect(h.preview.seeks.last == .zero)
  }

  @Test func removeAudioMutes() async throws {
    let (h, _) = try await threeClips()
    #expect(h.model.plan?.hasAudioOut == true)
    h.model.toggleRemoveAudio()
    #expect(h.preview.muted)
    #expect(h.model.reel?.export.removeAudio == true)
    #expect(h.model.plan?.hasAudioOut == false)
    #expect(h.model.history.canUndo, "the import is still the only step")
    h.model.undo()
    #expect(h.model.reel?.clips.isEmpty == true)
    h.model.redo()
    h.model.toggleRemoveAudio()
    #expect(!h.preview.muted)
  }

  @Test func loopAndTimecodeToggles() async throws {
    let (h, _) = try await threeClips()
    #expect(h.preview.loop)
    h.model.toggleLoop()
    #expect(!h.model.prefs.loop)
    #expect(!h.preview.loop)
    h.model.toggleTCMode()
    #expect(h.model.prefs.tcMode == .seconds)
  }

  /// Task 42 acceptance 2, miss 6: a playback tick re-renders only the playhead's digits. The transport row and the
  /// timecode button around them (focus, hover, tooltip and accessibility modifiers) don't read the playhead while
  /// playing; rebuilding them, and re-laying out the window for a new `Text`, every frame was most of the main
  /// thread's per-tick time and pushed passes past the stall watchdog's 16 ms.
  @Test func playbackTickRebuildsOnlyTheDigits() async throws {
    let (h, _) = try await threeClips()
    h.model.play()
    try #require(h.model.isPlaying)
    let around = Mutex(false)
    withObservationTracking {
      _ = TransportView(model: h.model).body
      _ = TimecodeReadout(model: h.model).body
    } onChange: { around.withLock { $0 = true } }
    let digits = Mutex(false)
    withObservationTracking {
      _ = PlayheadDigits(model: h.model, mode: .timecode, frame: RationalTime(1001, 30000)).body
    } onChange: { digits.withLock { $0 = true } }
    h.model.previewTime(seconds(3))  // one tick
    #expect(h.model.playhead == seconds(3).floored(toFrame: RationalTime(1001, 30000)))
    #expect(!around.withLock { $0 }, "a tick rebuilt the transport or the timecode button")
    #expect(digits.withLock { $0 }, "the digits follow the playhead")
  }

  /// Paused, the timecode button's VoiceOver label carries the playhead (there's no per-frame cost to avoid then).
  @Test func pausedTimecodeLabelHasThePlayhead() async throws {
    let (h, _) = try await threeClips()
    let tracked = Mutex(false)
    withObservationTracking { _ = TimecodeReadout(model: h.model).body } onChange: { tracked.withLock { $0 = true } }
    h.model.playhead = seconds(4)
    #expect(tracked.withLock { $0 }, "paused, a playhead move updates the label")
  }

  /// Play, then pause: the timecode button notices the pause and its VoiceOver label carries the playhead's time
  /// again, not "playing".
  @Test func pauseBringsTheTimeBackToTheLabel() async throws {
    let (h, _) = try await threeClips()
    h.model.play()
    h.model.previewTime(seconds(3))
    #expect(TimecodeReadout.label(h.model).hasPrefix("Playhead, playing, of "))
    let rebuilt = Mutex(false)
    withObservationTracking { _ = TimecodeReadout(model: h.model).body } onChange: { rebuilt.withLock { $0 = true } }
    h.model.pause()
    #expect(rebuilt.withLock { $0 }, "the pause didn't reach the timecode button")
    let label = TimecodeReadout.label(h.model)
    let now = TransportView.format(h.model.playhead, mode: .timecode, frame: RationalTime(1001, 30000))
    #expect(now == "0:02.29", "the tick's frame, floored at 29.97")
    #expect(label.hasPrefix("Playhead \(now) of "), "\(label)")
    #expect(!label.contains("playing"))
  }

  /// The playhead's digits never draw past their 60 / 68 pt box: measured at the real font, the widest strings of
  /// each mode either fit or are scaled to the box (`9:59.29` fits; `59:59.29` and `3599.99 s` don't, at 15 pt).
  @Test func playheadDigitsStayInTheirBox() {
    let fd = RationalTime(1001, 30000)
    let cases: [(TCMode, RationalTime, Bool)] = [  // mode, time, fits at full size
      (.timecode, RationalTime(599, 1) + RationalTime(29, 30), true),
      (.timecode, RationalTime(3599, 1) + RationalTime(29, 30), false),
      (.timecode, RationalTime(35999, 1), false),
      (.seconds, RationalTime(99999, 100), true),
      (.seconds, RationalTime(359999, 100), false),
    ]
    for (mode, t, fits) in cases {
      let s = TransportView.format(t, mode: mode, frame: fd)
      let width = NSHostingView(rootView: Text(s).font(PlayheadDigits.font).monospacedDigit().fixedSize()).fittingSize.width
      let box = TransportView.playheadBox(mode)
      let scale = PlayheadDigits.fit(width, in: box)
      #expect((scale == 1) == fits, "\(s): \(width) pt in \(box)")
      #expect(width * scale <= box + 0.001, "\(s) draws \(width * scale) pt in a \(box) pt box")
    }
  }

  /// Peek shows a source frame and parks the Reel playhead on the clip's nearest kept frame (§4.2).
  @Test func peekParksOnNearestKeptFrame() async throws {
    let (h, ids) = try await threeClips()
    #expect(h.model.perform(.setIn(ids[1], seconds(2)), coalesce: nil))
    #expect(h.model.perform(.setOut(ids[1], seconds(6)), coalesce: nil))
    h.model.select(ids[1], extend: false, toggle: false)
    let b = try #require(h.model.reel?.clips[1])
    let fd = b.facts.frameDuration
    h.model.peek(sourceTime: seconds(1))  // before In
    #expect(h.model.peek == Peek(clipID: ids[1], sourceTime: seconds(1)))
    #expect(h.model.playhead == seconds(10))
    h.model.peek(sourceTime: seconds(9))  // past Out: the last kept frame (Out is exclusive)
    #expect(h.model.playhead == seconds(10) + (b.outTime - fd - b.inTime))
    h.model.play()  // from peek: from the clip's In
    #expect(h.model.peek == nil)
    #expect(h.model.playhead == seconds(10))
  }

  @Test func newReelStopsPlayback() async throws {
    let (h, _) = try await threeClips()
    h.model.play()
    h.model.newReel()
    #expect(h.preview.rate == 0)
    await h.model.pendingPreview?.value
    #expect(h.preview.shown.last?.plan.placements.isEmpty == true)
  }

  // MARK: fresh preview state (Phase 4 review I3)

  /// The show waits on an asset load; a pause made meanwhile is what it lands with.
  @Test func pauseDuringSlowAssetLoadLandsPaused() async throws {
    let (h, _) = try await threeClips()
    h.media.holdAssets()
    h.model.play()
    let started = h.media.state.withLock { $0.assetsStarted }
    await h.importAll(["d.mov"])  // a new file: its asset isn't loaded yet
    #expect(await h.media.waitForAssets(started + 1))
    h.model.pause()
    h.media.releaseAssets()
    await h.model.pendingPreview?.value
    #expect(h.preview.shown.last?.play == false)
  }

  /// A seek made during the load is where the show lands.
  @Test func seekDuringSlowAssetLoadLandsThere() async throws {
    let (h, _) = try await threeClips()
    h.media.holdAssets()
    let started = h.media.state.withLock { $0.assetsStarted }
    await h.importAll(["d.mov"])
    #expect(await h.media.waitForAssets(started + 1))
    h.model.seek(reelTime: seconds(25))
    h.media.releaseAssets()
    await h.model.pendingPreview?.value
    #expect(h.preview.shown.last?.at == seconds(25))
  }

  // MARK: the selection rule after edits (Phase 4 review I4)

  /// Paused, after ⌥→ the moved primary is no longer under the playhead: the playhead goes to its In.
  @Test func moveKeepsPlayheadOnPrimary() async throws {
    let (h, ids) = try await threeClips()
    h.model.selectAndSeek(ids[0], extend: false, toggle: false)
    #expect(h.model.playhead == .zero)
    h.model.command(.moveSelection(1))
    h.model.endKeyGesture()
    #expect(h.model.reel?.clips.map(\.id) == [ids[1], ids[0], ids[2]])
    #expect(h.model.selection.primary == ids[0])
    #expect(h.model.playhead == seconds(10))
    await h.model.pendingPreview?.value
    #expect(h.preview.shown.last?.at == seconds(10))
  }

  /// A crossfade into the next clip pulls it over the primary's tail, under the playhead: it goes to the primary's In.
  @Test func joinToggleKeepsPlayheadOnPrimary() async throws {
    let (h, ids) = try await threeClips()
    h.model.seek(reelTime: RationalTime(199, 10))  // 19.9 s: b's last frames, so b is selected
    #expect(h.model.selection.primary == ids[1])
    h.model.clickJoin(ids[2])
    #expect(h.model.selection.primary == ids[1])
    #expect(h.model.playhead == seconds(10))
  }

  @Test func undoAndRedoKeepPlayheadOnPrimary() async throws {
    let (h, ids) = try await threeClips()
    h.model.selectAndSeek(ids[0], extend: false, toggle: false)
    h.model.command(.moveSelection(1))
    h.model.endKeyGesture()
    #expect(h.model.playhead == seconds(10))
    h.model.undo()  // a back first: the playhead at 10 s is now over b
    #expect(h.model.selection.primary == ids[0])
    #expect(h.model.playhead == .zero)
    h.model.redo()
    #expect(h.model.playhead == seconds(10))
  }

  /// Playing, the rule stands aside: playback never moves for an edit.
  @Test func ruleWaitsWhilePlaying() async throws {
    let (h, ids) = try await threeClips()
    h.model.selectAndSeek(ids[0], extend: false, toggle: false)
    h.model.play()
    h.model.command(.moveSelection(1))
    h.model.endKeyGesture()
    #expect(h.model.playhead == .zero)
  }

  /// Main-actor stall (hang-report.md): closing a Reel, or dropping the model, must not free its assets on the main
  /// actor, where a Reel's worth of `AVURLAsset` deallocations froze it for seconds under load.
  @Test func reelAssetsAreFreedOffTheMainActor() async throws {
    let deaths = AssetDeaths()
    var h: Harness? = Harness()
    h!.media.trackAssets(deaths)
    await h!.importAll((1...40).map { String(format: "a%02d.mov", $0) })
    await h!.model.pendingPreview?.value
    let made = h!.media.assetsMade
    // One load per file, however many preview refreshes the probes set off (each used to make its own).
    #expect(made == 40, "\(made) assets made for 40 files")
    // Scrub players hold assets too: peek four clips (the pool keeps three, so one is evicted).
    for clip in h!.model.reel?.clips.prefix(4) ?? [] {
      h!.model.select(clip.id, extend: false, toggle: false)
      h!.model.peek(sourceTime: RationalTime(1, 1))
      let end = ContinuousClock.now + .seconds(3)
      while h!.model.peekPlayer == nil || h!.model.scrub.clipIDs.first != clip.id, ContinuousClock.now < end {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    #expect(h!.model.scrub.clipIDs.count == 3)
    h!.model.newReel()
    await h!.model.pendingPreview?.value
    // A second Reel's assets go with the model itself.
    await h!.importAll((1...10).map { String(format: "b%02d.mov", $0) })
    await h!.model.pendingPreview?.value
    let all = h!.media.assetsMade
    h = nil
    let end = ContinuousClock.now + .seconds(5)
    while deaths.total.load(ordering: .relaxed) < all, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(deaths.total.load(ordering: .relaxed) == all, "\(deaths.total.load(ordering: .relaxed)) of \(all) freed")
    #expect(deaths.onMain.load(ordering: .relaxed) == 0, "\(deaths.onMain.load(ordering: .relaxed)) freed on main")
  }

  /// A load that lands after New Reel belongs to no Reel: it must not be cached in the new session, and its asset
  /// is let go off the main actor.
  @Test func staleLoadIsNotCachedInTheNewSession() async throws {
    let deaths = AssetDeaths()
    let h = Harness()
    h.media.trackAssets(deaths)
    await h.importAll(["x.mov"])
    await h.model.pendingPreview?.value
    h.model.newReel()
    await h.model.pendingPreview?.value
    // The next Reel's first load is held, then that Reel is closed while it is still in flight.
    h.media.holdAssets()
    await h.importAll(["y.mov"])
    #expect(await h.media.waitForAssets(2, timeout: .seconds(3)))
    h.model.newReel()
    let newSession = h.model.session.id
    h.media.releaseAssets()
    try await Task.sleep(for: .milliseconds(300))
    #expect(h.model.session.id == newSession)
    #expect(h.model.session.assetCache.isEmpty, "a stale load was cached: \(h.model.session.assetCache.keys)")
    #expect(h.model.session.assetLoads.isEmpty)
    let end = ContinuousClock.now + .seconds(3)
    while deaths.total.load(ordering: .relaxed) < 2, ContinuousClock.now < end {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(deaths.total.load(ordering: .relaxed) == 2)
    #expect(deaths.onMain.load(ordering: .relaxed) == 0)
  }
}
