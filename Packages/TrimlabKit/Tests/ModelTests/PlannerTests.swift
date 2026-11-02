import Foundation
import Testing
@testable import TrimlabModel

@Suite struct PlannerTests {
  private func t(_ v: Int64, _ ts: Int32 = 1) -> RationalTime { RationalTime(v, ts) }
  private let quarter = RationalTime(1, 4)

  /// Builders.reel with the given joins INTO each clip (index 0's join is ignored by the Planner).
  private func reel(_ seconds: [Double], joins: [Join]? = nil) -> Reel {
    var r = Builders.reel(seconds)
    if let joins { for i in r.clips.indices { r.clips[i].join = joins[i] } }
    return r
  }

  /// A whole-source clip of an exact rational duration (Builders.clip takes Double seconds).
  private func clip(duration: RationalTime, fps: RationalTime = RationalTime(1001, 30000)) -> ReelClip {
    ReelClip.make(source: Builders.clip(1).source, facts: Builders.facts(duration: duration, fps: fps),
                  framing: .fill)
  }

  // MARK: placements

  @Test func cutsPlaceBackToBack() {
    let plan = Planner.plan(reel([2, 3, 4]))
    #expect(plan.placements.map(\.reelSpan.start) == [t(0), t(2), t(5)])
    #expect(plan.placements.map(\.reelSpan.duration) == [t(2), t(3), t(4)])
    #expect(plan.placements.map(\.fadeIn) == [.zero, .zero, .zero])
    #expect(plan.total == t(9))
    #expect(plan.placements.map(\.track) == [0, 1, 0])
    #expect(plan.placements.map(\.index) == [0, 1, 2])
  }

  @Test func crossfadeOverlaps() {
    let plan = Planner.plan(reel([2, 3, 4], joins: [.cut, .crossfade(quarter), .cut]))
    #expect(plan.placements[1].reelSpan.start == t(175, 100))
    #expect(plan.placements[1].fadeIn == quarter)
    #expect(plan.placements[2].reelSpan.start == t(475, 100))
    #expect(plan.total == t(875, 100))
  }

  @Test func sourceInIsTheClipsIn() throws {
    var r = Builders.reel([4, 4])
    // 30 fps clips so the floored In is exactly 1 s (F29).
    r.clips = [Builders.clip(4, fps: t(1, 30)), Builders.clip(4, fps: t(1, 30))]
    r = try apply(.setIn(r.clips[1].id, t(1)), to: r)
    let plan = Planner.plan(r)
    #expect(plan.placements.map(\.sourceIn) == [.zero, t(1)])
    #expect(plan.placements[1].reelSpan.duration == t(3))
    #expect(plan.total == t(7))
  }

  @Test func firstClipJoinIgnored() {
    let plan = Planner.plan(reel([2, 3], joins: [.crossfade(Limits.longFade), .cut]))
    #expect(plan.placements[0].fadeIn == .zero)
    #expect(plan.placements[0].reelSpan.start == .zero)
    #expect(plan.total == t(5))
  }

  // MARK: effective fade (§4.3.4, F7: exact, not floored to a frame)

  @Test func effectiveFadeHalvesShortNeighbour() {
    let r = reel([3, 1.2], joins: [.cut, .crossfade(Limits.longFade)])
    #expect(Planner.effectiveFade(into: 1, in: r.clips) == t(6, 10))
    #expect(Planner.plan(r).placements[1].fadeIn == t(6, 10))
    // The shorter neighbour may be the outgoing clip too.
    let back = reel([1.2, 3], joins: [.cut, .crossfade(Limits.longFade)])
    #expect(Planner.effectiveFade(into: 1, in: back.clips) == t(6, 10))
  }

  @Test func crossfadeNextToTinyClipIsHalfItsLength() {
    let r = reel([3, 0.4], joins: [.cut, .crossfade(Limits.shortFade)])
    #expect(Planner.effectiveFade(into: 1, in: r.clips) == t(2, 10))
  }

  @Test func effectiveFadeKeepsChosenWhenNeighboursAreLong() {
    let r = reel([3, 3], joins: [.cut, .crossfade(Limits.longFade)])
    #expect(Planner.effectiveFade(into: 1, in: r.clips) == Limits.longFade)
  }

  @Test func effectiveFadeZeroForCutAndFirstClip() {
    let r = reel([3, 3, 3], joins: [.crossfade(Limits.longFade), .cut, .crossfade(quarter)])
    #expect(Planner.effectiveFade(into: 0, in: r.clips) == .zero)
    #expect(Planner.effectiveFade(into: 1, in: r.clips) == .zero)
    #expect(Planner.effectiveFade(into: 2, in: r.clips) == quarter)
  }

  // MARK: segments

  @Test func segmentsCoverWithoutGapOrOverlap() {
    var rng = SplitMix64(seed: 0x7121_ab02)
    let rates = [t(1001, 30000), t(1, 30), t(1, 25), t(1, 60), t(1001, 24000)]
    let joins: [Join] = [.cut, .crossfade(Limits.shortFade), .crossfade(Limits.longFade)]
    for _ in 0..<200 {
      let count = Int(rng.next() % 18) + 1
      var r = Reel.empty(name: "random")
      for _ in 0..<count {
        let tenths = Double(rng.next() % 100 + 4) / 10  // 0.4 s … 10.3 s
        var c = Builders.clip(tenths, fps: rates[Int(rng.next() % UInt64(rates.count))])
        c.join = joins[Int(rng.next() % UInt64(joins.count))]
        r.clips.append(c)
      }
      let plan = Planner.plan(r)
      let segs = plan.segments
      #expect(segs.first?.span.start == .zero)
      #expect(segs.last?.span.end == plan.total)
      for (a, b) in zip(segs, segs.dropFirst()) {
        #expect(a.span.end == b.span.start)
        #expect(a.span.start < b.span.start)
      }
      for s in segs {
        #expect(s.span.duration > .zero)
        #expect((1...2).contains(s.layers.count))
        if s.layers.count == 2 { #expect(s.layers[0].placement < s.layers[1].placement) }
      }
    }
  }

  @Test func overlapSegmentHasTwoLayersOutgoingOnTop() throws {
    var r = reel([2, 3, 4], joins: [.cut, .crossfade(quarter), .cut])
    r.clips[1].framing = .fit
    let plan = Planner.plan(r)
    let overlap = try #require(plan.segments.first { $0.layers.count == 2 })
    #expect(overlap.span == TimeSpan(start: t(175, 100), duration: quarter))
    #expect(overlap.layers[0].placement == 0)
    #expect(overlap.layers[0].opacity == 0...1)  // F2: stored 0...1, ramps upper → lower (1 → 0) across the span
    #expect(overlap.layers[0].framing == .fill)
    #expect(overlap.layers[1].placement == 1)
    #expect(overlap.layers[1].opacity == nil)
    #expect(overlap.layers[1].framing == .fit)
    #expect(overlap.layers.allSatisfy { $0.effects.isEmpty })
    // Solo segments carry no ramp.
    #expect(plan.segments.filter { $0.layers.count == 1 }.allSatisfy { $0.layers[0].opacity == nil })
    #expect(plan.segments.count == 4)  // [0,1.75) [1.75,2) [2,4.75) [4.75,8.75)
  }

  @Test func touchingFadesLeaveNoZeroLengthSegment() {
    // A 1 s middle clip with Long fades both sides: 0.5 s in, 0.5 s out, no solo stretch for it.
    let r = reel([3, 1, 3], joins: [.cut, .crossfade(Limits.longFade), .crossfade(Limits.longFade)])
    let plan = Planner.plan(r)
    #expect(plan.segments.map(\.layers.count) == [1, 2, 2, 1])
    #expect(plan.segments.allSatisfy { $0.span.duration > .zero })
    #expect(plan.total == t(6))
  }

  // MARK: audio

  @Test func audioRampsForCrossfade() {
    let plan = Planner.plan(reel([2, 3, 4], joins: [.cut, .crossfade(quarter), .cut]))
    let span = TimeSpan(start: t(175, 100), duration: quarter)
    #expect(plan.audioRamps == [AudioRamp(track: 0, span: span, from: 1, to: 0),
                                AudioRamp(track: 1, span: span, from: 0, to: 1)])
    #expect(Planner.plan(reel([2, 3])).audioRamps.isEmpty)
  }

  @Test func hasAudioOut() {
    var r = reel([2, 3])
    #expect(Planner.plan(r).hasAudioOut)
    r.export.removeAudio = true
    #expect(!Planner.plan(r).hasAudioOut)
    let silent = Reel(id: UUID(), name: "s", clips: [Builders.clip(2, audio: false), Builders.clip(3, audio: false)])
    #expect(!Planner.plan(silent).hasAudioOut)
    let mixed = Reel(id: UUID(), name: "m", clips: [Builders.clip(2, audio: false), Builders.clip(3)])
    #expect(Planner.plan(mixed).hasAudioOut)
  }

  // MARK: frame rate

  private func rateReel(_ parts: [(Double, RationalTime)]) -> Reel {
    Reel(id: UUID(), name: "r", clips: parts.map { Builders.clip($0.0, fps: $0.1) })
  }

  @Test func frameRateMostReelTime() {
    let ntsc = t(1001, 30000)
    #expect(Planner.plan(rateReel([(10, ntsc), (4, t(1, 60))])).frameDuration == ntsc)
    #expect(Planner.plan(rateReel([(10, t(1, 60)), (4, ntsc)])).frameDuration == t(1, 60))
    #expect(Planner.plan(rateReel([(5, t(1, 24)), (5, t(1, 25))])).frameDuration == t(1, 24))  // tie → lower
    #expect(Planner.frameDuration(for: rateReel([(5, t(1, 25)), (5, t(1, 24))]).clips) == t(1, 24))
  }

  @Test func frameRateSnapsNominalRates() {
    // 29.97 measured slightly off (e.g. 2997/100 fps) snaps to 30000/1001; 23.976 likewise.
    #expect(Planner.frameDuration(for: rateReel([(4, t(100, 2997)), (1, t(1, 25))]).clips) == t(1001, 30000))
    #expect(Planner.frameDuration(for: rateReel([(4, t(1000, 23976)), (1, t(1, 25))]).clips) == t(1001, 24000))
  }

  @Test func frameRateCapsAt60() {
    let fd = Planner.plan(rateReel([(10, t(1, 120)), (2, t(1, 30))])).frameDuration
    #expect(fd == t(1, 60))
    #expect(fd >= t(1, 60))
  }

  @Test func oneClipKeepsOwnRate() {
    #expect(Planner.plan(rateReel([(5, t(1, 25))])).frameDuration == t(1, 25))
    #expect(Planner.plan(rateReel([(5, t(1, 120))])).frameDuration == t(1, 120))
  }

  // MARK: size, HDR, missing

  @Test func renderSizes() {
    var r = Reel(id: UUID(), name: "s", clips: [Builders.clip(2, size: (1079, 1917)), Builders.clip(2)])
    #expect(Planner.plan(r).renderSize == PixelSize(width: 1080, height: 1920))
    r.export.format = .original
    #expect(Planner.plan(r).renderSize == PixelSize(width: 1078, height: 1916))
  }

  @Test func hdrOut() {
    var r = Reel(id: UUID(), name: "h", clips: [Builders.clip(2), Builders.clip(2, hdr: .hlg)])
    r.export.convertHDR = false
    #expect(Planner.plan(r).hdrOut)
    r.export.convertHDR = true
    #expect(!Planner.plan(r).hdrOut)
    var sdr = reel([2, 2])
    sdr.export.convertHDR = false
    #expect(!Planner.plan(sdr).hdrOut)
  }

  @Test func missingClipsLeftOut() {
    let r = reel([2, 3, 4])
    let (a, b, c) = (r.clips[0].id, r.clips[1].id, r.clips[2].id)
    let plan = Planner.plan(r, missing: [b])
    #expect(plan.placements.map(\.clipID) == [a, c])
    #expect(plan.placements.map(\.track) == [0, 1])
    #expect(plan.placements[1].reelSpan.start == t(2))
    #expect(plan.total == t(6))
    #expect(plan.segments.flatMap(\.layers).allSatisfy { $0.placement < plan.placements.count })
  }

  @Test func missingFirstClipDropsTheNextJoin() {
    let r = reel([2, 3, 4], joins: [.cut, .crossfade(quarter), .cut])
    let plan = Planner.plan(r, missing: [r.clips[0].id])
    #expect(plan.placements.map(\.fadeIn) == [.zero, .zero])
    #expect(plan.total == t(7))
  }

  @Test func emptyReelPlansNothing() {
    let plan = Planner.plan(Reel.empty(name: "e"))
    #expect(plan.placements.isEmpty)
    #expect(plan.segments.isEmpty)
    #expect(plan.total == .zero)
    #expect(!plan.hasAudioOut)
  }

  @Test func deterministic() {
    let r = reel([2, 3, 1.2, 4], joins: [.cut, .crossfade(quarter), .crossfade(Limits.longFade), .cut])
    #expect(Planner.plan(r) == Planner.plan(r))
  }

  // MARK: totals (§4.3.6)

  @Test func reelTotalMatchesPlan() {
    let r = reel([2, 3, 4], joins: [.cut, .crossfade(quarter), .cut])
    #expect(r.total(missing: []) == t(875, 100))
  }

  @Test func overLimitBoundary() {
    let exactly = Reel(id: UUID(), name: "x", clips: [clip(duration: t(180))])
    #expect(exactly.total(missing: []) == t(180))
    #expect(exactly.overLimit(missing: []) == nil)
    let frame = t(1001, 30000)
    let over = Reel(id: UUID(), name: "o", clips: [clip(duration: t(180) + frame)])
    #expect(over.overLimit(missing: []) == frame)
    #expect(over.overLimit(by: t(200), missing: []) == nil)
  }

  @Test func totalAndOverLimitLeaveMissingClipsOut() {
    // Phase 2 review: the total matches plan(reel, missing:), so a missing clip doesn't count toward the limit.
    let r = Reel(id: UUID(), name: "m", clips: [clip(duration: t(100)), clip(duration: t(100))])
    let gone: Set<UUID> = [r.clips[1].id]
    #expect(r.total(missing: gone) == Planner.plan(r, missing: gone).total)
    #expect(r.total(missing: gone) == t(100))
    #expect(r.overLimit(missing: []) == t(20))
    #expect(r.overLimit(missing: gone) == nil)
  }

  // MARK: performance (§5.3 "re-plan < 1 ms"; F28: written with the rest)

  @Test func planEighteenClipsUnder1ms() {
    var r = Reel.empty(name: "eighteen")
    for i in 0..<18 {
      var c = Builders.clip(Double(3 + i % 5), fps: i % 3 == 0 ? t(1, 60) : t(1001, 30000))
      c.join = i % 2 == 0 ? .crossfade(Limits.shortFade) : .crossfade(Limits.longFade)
      r.clips.append(c)
    }
    let clock = ContinuousClock()
    var runs: [Duration] = []
    for _ in 0..<100 {
      let start = clock.now
      _ = Planner.plan(r)
      runs.append(clock.now - start)
    }
    let median = runs.sorted()[runs.count / 2]
    // §5.3's 1 ms under TRIMLAB_TIMING=1; 4× looser in a parallel run.
    #expect(median < .milliseconds(Timing.strict ? 1 : 4), "median \(median)")
  }
}

/// Seeded generator so the random-reel test is reproducible.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
