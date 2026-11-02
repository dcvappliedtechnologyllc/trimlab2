import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// Task 27: the preview engine (§4.2, §5.3, §10) and the scrub players. Real fixtures, real `AVPlayer`s.
@MainActor @Suite(.serialized, .exclusiveMedia) struct PreviewEngineTests {
  /// §10: edit → exact seek landed, warm: median < 50 ms, max < 100 ms. 12 re-trims of clip 7 of the 18-clip Reel.
  @Test func rebuildSeekLandsFast() async throws {
    let (reel, assets) = try await FixtureReel.eighteen()
    let engine = PreviewEngine()
    engine.muted = true
    // Cold: the first item pays for decoder and compositor start-up (§10 "first item", < 500 ms, once).
    let coldStart = ContinuousClock.now
    await engine.show(Planner.plan(reel), assets: assets, at: .zero, play: false)
    let cold = ContinuousClock.now - coldStart

    var times: [Duration] = []
    var edited = reel
    let k = 7
    let fd = edited.clips[k].facts.frameDuration
    for i in 0..<12 {
      let inS = RationalTime(seconds: 0.2 + Double(i % 5) * 0.1, timescale: fd.timescale).floored(toFrame: fd)
      let outS = min(inS + RationalTime(seconds: 1.4 + Double(i % 3) * 0.2, timescale: fd.timescale).floored(toFrame: fd),
                     edited.clips[k].facts.duration.floored(toFrame: fd))
      edited.clips[k].inTime = inS
      edited.clips[k].outTime = outS
      let plan = Planner.plan(edited)
      let at = plan.placements[k].reelSpan.start
      let start = ContinuousClock.now
      await engine.show(plan, assets: assets, at: at, play: false)
      times.append(ContinuousClock.now - start)
      #expect(engine.shownPlan == plan)
      #expect(RationalTime(engine.player.currentTime()) == at, "the seek must land exactly on the clip's In")
    }
    let ms = times.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }.sorted()
    let median = ms[ms.count / 2]
    print(String(format: "preview: cold %.1f ms; rebuild → seek landed median %.1f ms, max %.1f ms (n=%d) %@",
                 Double(cold.components.attoseconds) / 1e15 + Double(cold.components.seconds) * 1000,
                 median, ms.last ?? 0, ms.count, ms.map { String(format: "%.1f", $0) }.joined(separator: " ")))
    // §10's 50 ms median is held under TRIMLAB_TIMING=1 (see `Timing`); a parallel run loads the machine enough
    // to push it to ~80 ms, so there it only has to stay clearly interactive.
    let medianLimit = Timing.strict ? 50.0 : 200.0
    #expect(median < medianLimit, "median \(median) ms (limit \(medianLimit))")
    // The single slowest sample only under TRIMLAB_TIMING=1 (see `Timing`); acceptance runs
    // `TRIMLAB_TIMING=1 swift test --no-parallel --filter 'PreviewEngineTests|CompositorGateTests|StripLayoutTests'`.
    if Timing.strict { #expect((ms.last ?? 0) < 100, "max \(ms.last ?? 0) ms") }
  }

  /// Five `show`s in one run-loop turn: one or two builds, and what's on screen is the last plan.
  @Test func rebuildsCoalesce() async throws {
    let (reel, assets) = try await FixtureReel.make([
      ("portrait_hevc.mov", 0, 2, .cut, .fill), ("landscape.mp4", 0, 2, .cut, .fill),
    ])
    let engine = PreviewEngine()
    engine.muted = true
    var plans: [CompositionPlan] = []
    for i in 0..<5 {
      var r = reel
      let fd = r.clips[1].facts.frameDuration
      r.clips[1].outTime = RationalTime(seconds: 1.0 + Double(i) * 0.2, timescale: fd.timescale).floored(toFrame: fd)
      plans.append(Planner.plan(r))
    }
    let tasks = plans.map { plan in Task { await engine.show(plan, assets: assets, at: .zero, play: false) } }
    for task in tasks { await task.value }
    #expect((1...2).contains(engine.buildCount), "builds: \(engine.buildCount)")
    let last = try #require(plans.last)
    #expect(engine.shownPlan == last)
    let item = try #require(engine.player.currentItem)
    #expect(RationalTime(item.asset.duration) == last.total)
  }

  /// Loop on: the end wraps to 0:00 and keeps playing. Loop off: playback stops and `onEnd` fires.
  @Test func loopWrapsToZero() async throws {
    let (reel, assets) = try await FixtureReel.make([("portrait_hevc.mov", 0, 1, .cut, .fill)])
    let plan = Planner.plan(Self.silent(reel))
    let engine = PreviewEngine()
    engine.muted = true
    engine.loop = true
    var times: [RationalTime] = []
    var ended = 0
    engine.onTime = { times.append($0) }
    engine.onEnd = { ended += 1 }
    await engine.show(plan, assets: assets, at: plan.total - RationalTime(1, 4), play: true)
    let wrapped = await Self.until(seconds: 5) {
      times.contains { $0 > plan.total - RationalTime(1, 2) } && times.last.map { $0 < RationalTime(1, 2) } == true
    }
    #expect(wrapped, "times seen: \(times.suffix(8).map(\.seconds))")
    #expect(engine.player.rate > 0, "still playing after the wrap")
    #expect(ended == 0)

    engine.loop = false
    engine.setRate(0)
    _ = await engine.seek(plan.total - RationalTime(1, 4))
    engine.setRate(1)
    let stopped = await Self.until(seconds: 5) { ended == 1 }
    #expect(stopped)
    #expect(engine.player.rate == 0)
  }

  /// An edit that swaps the item between the loop's end and its wrap is not rewound or restarted by the wrap.
  @Test func loopWrapLeavesSwappedItemAlone() async throws {
    let (reel, assets) = try await FixtureReel.make([("portrait_hevc.mov", 0, 1, .cut, .fill)])
    let plan = Planner.plan(Self.silent(reel))
    let engine = PreviewEngine()
    engine.muted = true
    engine.loop = true
    await engine.show(plan, assets: assets, at: RationalTime(1, 2), play: true)
    let swapped = AVPlayerItem(asset: try #require(assets.values.first))
    engine.ended()  // the end notification: the wrap is queued
    engine.player.rate = 0  // an edit swaps the item before the wrap runs (as `install` does)
    engine.player.replaceCurrentItem(with: swapped)
    try await Task.sleep(for: .milliseconds(300))
    #expect(engine.player.currentItem === swapped)
    #expect(engine.player.rate == 0, "the wrap must not restart playback on the new item")
  }

  /// Reverse shuttle stops at 0:00 (v1 ruling) and reports the end.
  @Test func reverseStopsAtZero() async throws {
    let (reel, assets) = try await FixtureReel.make([("portrait_hevc.mov", 0, 2, .cut, .fill)])
    let engine = PreviewEngine()
    engine.muted = true
    var ended = 0
    engine.onEnd = { ended += 1 }
    await engine.show(Planner.plan(Self.silent(reel)), assets: assets, at: RationalTime(1, 4), play: false)
    engine.setRate(-1)
    let stopped = await Self.until(seconds: 15) { ended == 1 }
    #expect(stopped, "rate \(engine.player.rate), at \(engine.player.currentTime().seconds) s, status \(engine.player.timeControlStatus.rawValue), waiting \(String(describing: engine.player.reasonForWaitingToPlay))")
    #expect(engine.player.rate == 0)
    #expect(engine.player.currentTime().seconds < 0.1)
  }

  /// T23 carry: preview runs through `ReelCompositor`, so the flash fix holds on screen too. An HLG clip in an SDR
  /// Reel: its first displayed frame matches frame 1 within 3 (AVFoundation's own conversion left frame 0 bright).
  @Test func hlgFirstDisplayedFrameMatchesFrame1() async throws {
    let (reel, assets) = try await FixtureReel.make([("hlgbright.mov", 0, 1, .cut, .fill)])
    let plan = Planner.plan(reel)
    #expect(!plan.hdrOut)
    let engine = PreviewEngine()
    engine.muted = true
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    engine.itemPrepared = { $0.add(output) }
    await engine.show(plan, assets: assets, at: .zero, play: false)
    let first = try #require(await Self.frame(output, at: .zero), "no frame at 0")
    #expect(await engine.seek(plan.frameDuration))
    let second = try #require(await Self.frame(output, at: plan.frameDuration), "no frame at 1")
    let l0 = try #require(FrameStats.limitedLuma(first)), l1 = try #require(FrameStats.limitedLuma(second))
    print("preview: HLG in SDR first displayed frame \(l0), frame 1 \(l1)")
    #expect(abs(l0 - l1) <= 3, "frame 0 \(l0) vs frame 1 \(l1)")
  }

  /// An item that never becomes ready doesn't hold the drain: it's dropped after the timeout, and the next show
  /// lands normally.
  @Test func readyWaitTimesOut() async throws {
    let (reel, assets) = try await FixtureReel.make([("portrait_hevc.mov", 0, 1, .cut, .fill)])
    let plan = Planner.plan(Self.silent(reel))
    let engine = PreviewEngine()
    engine.muted = true
    engine.readyTimeout = .milliseconds(300)
    let stall = StallingLoader()
    let stalled = AVURLAsset(url: URL(string: "stall://never/clip.mov")!)
    stalled.resourceLoader.setDelegate(stall, queue: stall.queue)
    engine.makeItem = { _ in AVPlayerItem(asset: stalled) }
    let start = ContinuousClock.now
    await engine.show(plan, assets: assets, at: .zero, play: false)
    #expect(ContinuousClock.now - start < .seconds(3), "the drain waited past the timeout")
    #expect(engine.shownPlan == nil)
    #expect(engine.player.currentItem == nil, "the stalled item is dropped")

    engine.makeItem = PreviewEngine.defaultItem
    engine.readyTimeout = .seconds(5)  // a real first item may take longer than the stall test's 300 ms
    await engine.show(plan, assets: assets, at: RationalTime(1, 2), play: false)
    #expect(engine.shownPlan == plan)
    #expect(engine.player.currentItem?.status == .readyToPlay)
    #expect(RationalTime(engine.player.currentTime()) == RationalTime(1, 2))
  }

  /// Four clips through a pool of three: the least recently used player goes.
  @Test func scrubPoolIsLRU3() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let pool = ScrubPool()
    let ids = (0..<4).map { _ in UUID() }
    var players: [AVPlayer] = []
    for id in ids.prefix(3) {
      players.append(pool.player(for: id, asset: AVURLAsset(url: url)))
    }
    #expect(pool.clipIDs == [ids[2], ids[1], ids[0]])
    #expect(pool.player(for: ids[0], asset: AVURLAsset(url: url)) === players[0], "a hit reuses the player")
    #expect(pool.clipIDs == [ids[0], ids[2], ids[1]])
    _ = pool.player(for: ids[3], asset: AVURLAsset(url: url))
    #expect(pool.clipIDs == [ids[3], ids[0], ids[2]], "ids[1] was least recently used")
    #expect(!pool.clipIDs.contains(ids[1]))

    await pool.seek(ids[3], to: RationalTime(1, 2))
    let landed = pool.player(for: ids[3], asset: AVURLAsset(url: url)).currentTime()
    #expect(RationalTime(landed) == RationalTime(1, 2))
  }

  // MARK: helpers

  /// Takes every load request for its scheme and never answers it, so an item on it stays `.unknown`.
  final class StallingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "stall")
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
      true
    }
  }

  /// Real-time playback tests play without audio: on this Mac an `AVPlayer` whose item has an audio track sits at
  /// 0:00 with `timeControlStatus == .playing` (reproduced in a plain command-line tool, sandboxed or not), while
  /// a silent item plays. With Remove audio the composition has no audio track.
  static func silent(_ reel: Reel) -> Reel {
    var r = reel
    r.export.removeAudio = true
    return r
  }

  /// Polls `condition` every 10 ms until it holds or `seconds` pass.
  static func until(seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  /// The output's frame for item time `t`, waiting up to 3 s for it to be decoded.
  static func frame(_ output: AVPlayerItemVideoOutput, at t: RationalTime) async -> CVPixelBuffer? {
    let time = CMTime(t)
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if output.hasNewPixelBuffer(forItemTime: time),
         let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
        return buffer
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
  }
}
