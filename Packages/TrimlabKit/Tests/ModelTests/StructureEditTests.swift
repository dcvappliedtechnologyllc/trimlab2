import Foundation
import Testing
@testable import TrimlabModel

@Suite struct StructureEditTests {
  let fd = RationalTime(1001, 30000)
  let exact = RationalTime(1, 30)  // exact-second assertions use a 30 fps clip (F29)

  private func run(_ reel: Reel, _ edits: ReelEdit...) throws -> Reel {
    try edits.reduce(reel) { try apply($1, to: $0) }
  }
  private func ids(_ r: Reel) -> [UUID] { r.clips.map(\.id) }

  // MARK: insert

  @Test func insertAtCaret() throws {
    let reel = Builders.reel([1, 2, 3])
    let x = Builders.clip(4), y = Builders.clip(5)
    let out = try apply(.insert([x, y], at: 1), to: reel)
    let a = reel.clips
    #expect(ids(out) == [a[0].id, x.id, y.id, a[1].id, a[2].id])
  }

  @Test func insertIndexClamped() throws {
    let reel = Builders.reel([1, 2])
    let x = Builders.clip(4)
    #expect(try apply(.insert([x], at: 99), to: reel).clips.last?.id == x.id)
    #expect(try apply(.insert([x], at: -3), to: reel).clips.first?.id == x.id)
  }

  @Test func insertEmptyThrows() {
    #expect(throws: EditError.emptyInsert) { try apply(.insert([], at: 0), to: Builders.reel([1])) }
  }

  // MARK: move

  @Test func moveKeepsRelativeOrder() throws {
    let reel = Builders.reel([1, 2, 3, 4, 5])
    let c = reel.clips
    let out = try apply(.move([c[1].id, c[3].id], toGap: 5), to: reel)
    #expect(ids(out) == [c[0].id, c[2].id, c[4].id, c[1].id, c[3].id])
  }

  @Test func moveToGapBeforeAndMiddle() throws {
    let reel = Builders.reel([1, 2, 3, 4, 5])
    let c = reel.clips
    // Gap indexes are in the current order: gap 2 is before c[2].
    let out = try apply(.move([c[0].id, c[4].id], toGap: 2), to: reel)
    #expect(ids(out) == [c[1].id, c[0].id, c[4].id, c[2].id, c[3].id])
    let front = try apply(.move([c[3].id], toGap: 0), to: reel)
    #expect(ids(front) == [c[3].id, c[0].id, c[1].id, c[2].id, c[4].id])
    let clamped = try apply(.move([c[0].id], toGap: 99), to: reel)
    #expect(ids(clamped) == [c[1].id, c[2].id, c[3].id, c[4].id, c[0].id])
  }

  @Test func moveToOwnGapIsNoChange() throws {
    let reel = Builders.reel([1, 2, 3])
    let b = reel.clips[1].id
    #expect(try apply(.move([b], toGap: 1), to: reel) == reel)
    #expect(try apply(.move([b], toGap: 2), to: reel) == reel)
  }

  @Test func moveUnknownIds() throws {
    let reel = Builders.reel([1, 2, 3])
    #expect(throws: EditError.unknownClip) { try apply(.move([UUID()], toGap: 0), to: reel) }
    let c = reel.clips
    let out = try apply(.move([c[2].id, UUID()], toGap: 0), to: reel)
    #expect(ids(out) == [c[2].id, c[0].id, c[1].id])
  }

  @Test func movedClipKeepsJoin() throws {
    var reel = Builders.reel([1, 2, 3])
    reel.clips[2].join = .crossfade(RationalTime(1, 4))
    let c3 = reel.clips[2].id
    let front = try apply(.move([c3], toGap: 0), to: reel)
    #expect(front.clips[0].id == c3)
    #expect(front.clips[0].join == .crossfade(RationalTime(1, 4)))
  }

  @Test func firstClipJoinIgnoredButKept() throws {
    var reel = Builders.reel([1, 2, 3])
    reel.clips[2].join = .crossfade(RationalTime(1, 4))
    let c3 = reel.clips[2].id
    let front = try apply(.move([c3], toGap: 0), to: reel)
    let back = try apply(.move([c3], toGap: 3), to: front)
    #expect(back.clips[2].id == c3)
    #expect(back.clips[2].join == .crossfade(RationalTime(1, 4)))
  }

  // MARK: delete

  @Test func deleteSelection() throws {
    let reel = Builders.reel([1, 2, 3, 4])
    let c = reel.clips
    let out = try apply(.delete([c[1].id, c[2].id]), to: reel)
    #expect(ids(out) == [c[0].id, c[3].id])
  }

  @Test func deleteIgnoresUnknownIfOneIsKnown() throws {
    let reel = Builders.reel([1, 2])
    let out = try apply(.delete([reel.clips[0].id, UUID()]), to: reel)
    #expect(ids(out) == [reel.clips[1].id])
    #expect(throws: EditError.unknownClip) { try apply(.delete([UUID()]), to: reel) }
    #expect(throws: EditError.unknownClip) { try apply(.delete([]), to: reel) }
  }

  @Test func deleteEveryClipLeavesEmptyReel() throws {
    let reel = Builders.reel([1, 2])
    let out = try apply(.delete(Set(ids(reel))), to: reel)
    #expect(out.clips.isEmpty)
    #expect(out.name == reel.name && out.id == reel.id)
  }

  // MARK: split

  @Test func splitMakesTwoHalves() throws {
    var reel = Builders.reel([10])
    reel.clips[0] = Builders.clip(10, fps: exact)
    reel.clips[0].join = .crossfade(RationalTime(1, 4))
    reel.clips[0].framing = .fit
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setIn(id, RationalTime(1, 1)), .setOut(id, RationalTime(9, 1)))
    let out = try apply(.split(id, atSource: RationalTime(4, 1)), to: trimmed)
    #expect(out.clips.count == 2)
    let (a, b) = (out.clips[0], out.clips[1])
    #expect(a.id == id)
    #expect(a.inTime == RationalTime(1, 1) && a.outTime == RationalTime(4, 1))
    #expect(b.id != id)
    #expect(b.inTime == RationalTime(4, 1) && b.outTime == RationalTime(9, 1))
    #expect(a.join == .crossfade(RationalTime(1, 4)))
    #expect(b.join == .cut)
    #expect(b.source == a.source && b.facts == a.facts && b.framing == .fit)
  }

  @Test func splitFloorsToFrameAt2997() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let out = try apply(.split(id, atSource: RationalTime(4, 1)), to: reel)
    // 4.0 s / (1001/30000) = 119.88 frames, so the cut lands on frame 119.
    #expect(out.clips[0].outTime == fd * 119)
    #expect(out.clips[1].inTime == fd * 119)
    #expect(out.clips[1].outTime == reel.clips[0].facts.duration)
  }

  @Test func splitNextToOtherClipsKeepsThemInPlace() throws {
    let reel = Builders.reel([10, 10, 10])
    let c = reel.clips
    let out = try apply(.split(c[1].id, atSource: RationalTime(5, 1)), to: reel)
    #expect(out.clips.count == 4)
    #expect(out.clips[0].id == c[0].id && out.clips[1].id == c[1].id && out.clips[3].id == c[2].id)
  }

  @Test func splitTooCloseToEdge() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    #expect(throws: EditError.splitTooCloseToEdge) {
      try apply(.split(id, atSource: RationalTime(seconds: 0.4)), to: reel)
    }
    #expect(throws: EditError.splitTooCloseToEdge) {
      try apply(.split(id, atSource: RationalTime(seconds: 9.7)), to: reel)
    }
    #expect(throws: EditError.splitTooCloseToEdge) {
      try apply(.split(id, atSource: RationalTime(-3, 1)), to: reel)
    }
    #expect(throws: EditError.splitTooCloseToEdge) {
      try apply(.split(id, atSource: RationalTime(99, 1)), to: reel)
    }
  }

  @Test func splitAtExactlyHalfSecondBothSidesIsAllowed() throws {
    var reel = Builders.reel([1])
    reel.clips[0] = Builders.clip(1, fps: exact)
    let out = try apply(.split(reel.clips[0].id, atSource: RationalTime(1, 2)), to: reel)
    #expect(out.clips[0].trimmed == RationalTime(1, 2) && out.clips[1].trimmed == RationalTime(1, 2))
  }

  @Test func splitAtOffGridOutKeepsOutExact() throws {
    // 10 s at 29.97 is 299.7 frames: Out sits off-grid at the duration (Task 10 ruling).
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let out = try apply(.split(id, atSource: RationalTime(7, 1)), to: reel)
    #expect(out.clips[1].outTime == RationalTime(10, 1))
    #expect(out.clips[0].outTime == out.clips[1].inTime)
    #expect(out.clips[1].inTime == fd * 209)  // 7 / fd = 209.79
    // The last half is 2.9 s here; near the end, 9.9 s floors to frame 296 (9.877 s), leaving 0.123 s.
    #expect(throws: EditError.splitTooCloseToEdge) {
      try apply(.split(id, atSource: RationalTime(seconds: 9.9)), to: reel)
    }
  }

  @Test func splitTinyClipRefused() {
    let reel = Builders.reel([0.4])
    let id = reel.clips[0].id
    for t in [0.0, 0.1, 0.2, 0.3, 0.4] {
      #expect(throws: EditError.splitTooCloseToEdge) { try apply(.split(id, atSource: RationalTime(seconds: t)), to: reel) }
    }
  }

  @Test func splitUnknownClip() {
    #expect(throws: EditError.unknownClip) {
      try apply(.split(UUID(), atSource: RationalTime(1, 1)), to: Builders.reel([10]))
    }
  }

  @Test func splitWithBadFrameDurationDoesNotTrap() throws {
    var reel = Builders.reel([10])
    reel.clips[0] = Builders.clip(10, fps: .zero)
    let out = try apply(.split(reel.clips[0].id, atSource: RationalTime(4, 1)), to: reel)
    #expect(out.clips[0].outTime == RationalTime(4, 1))
  }

  // MARK: join, framing, audio, export, relink, rename

  @Test func setJoin() throws {
    let reel = Builders.reel([5, 5])
    let id = reel.clips[1].id
    let out = try apply(.setJoin(id, .crossfade(Limits.longFade)), to: reel)
    #expect(out.clips[1].join == .crossfade(Limits.longFade))
    #expect(out.clips[0].join == .cut)
    #expect(throws: EditError.unknownClip) { try apply(.setJoin(UUID(), .cut), to: reel) }
  }

  @Test func setFramingOnSelection() throws {
    let reel = Builders.reel([5, 5, 5])
    let c = reel.clips
    let out = try apply(.setFraming([c[0].id, c[2].id], .fit), to: reel)
    #expect(out.clips.map(\.framing) == [.fit, .fill, .fit])
    let ignoring = try apply(.setFraming([c[1].id, UUID()], .fit), to: reel)
    #expect(ignoring.clips.map(\.framing) == [.fill, .fit, .fill])
    #expect(throws: EditError.unknownClip) { try apply(.setFraming([UUID()], .fit), to: reel) }
  }

  @Test func renameAndRemoveAudioAndExport() throws {
    let reel = Builders.reel([5])
    #expect(try apply(.rename("Spa day"), to: reel).name == "Spa day")
    #expect(try apply(.setRemoveAudio(true), to: reel).export.removeAudio)
    var spec = ExportSpec()
    spec.quality = .standard
    spec.fileName = "x"
    #expect(try apply(.setExport(spec), to: reel).export == spec)
  }

  @Test func relinkClampsOut() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setIn(id, RationalTime(2, 1)), .setOut(id, RationalTime(8, 1)))
    let source = SourceRef(relativePath: "n.mov", absolutePath: "/n.mov", size: 9, modified: Date(timeIntervalSince1970: 5))
    let facts = Builders.facts(duration: RationalTime(5, 1))
    let out = try apply(.relink(id, source, facts), to: trimmed)
    #expect(out.clips[0].source == source && out.clips[0].facts == facts)
    #expect(out.clips[0].outTime == RationalTime(5, 1))
    #expect(out.clips[0].inTime == trimmed.clips[0].inTime)
  }

  @Test func relinkPullsInBackWhenSpanWouldBeTooShort() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setIn(id, RationalTime(4, 1)))
    let out = try apply(.relink(id, trimmed.clips[0].source, Builders.facts(duration: RationalTime(4, 1) + RationalTime(1, 10))), to: trimmed)
    let c = out.clips[0]
    #expect(c.outTime == RationalTime(41, 10))
    #expect(c.trimmed >= Limits.minSpan)
    #expect(c.inTime >= .zero && c.inTime <= c.outTime - Limits.minSpan)
  }

  @Test func relinkLongerSourceKeepsTrim() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setIn(id, RationalTime(2, 1)), .setOut(id, RationalTime(8, 1)))
    let out = try apply(.relink(id, trimmed.clips[0].source, Builders.facts(duration: RationalTime(20, 1))), to: trimmed)
    #expect(out.clips[0].inTime == trimmed.clips[0].inTime && out.clips[0].outTime == trimmed.clips[0].outTime)
  }

  @Test func relinkUnknownClip() {
    let reel = Builders.reel([5])
    #expect(throws: EditError.unknownClip) { try apply(.relink(UUID(), reel.clips[0].source, reel.clips[0].facts), to: reel) }
  }

  @Test func indexOf() {
    let reel = Builders.reel([1, 2, 3])
    #expect(reel.index(of: reel.clips[2].id) == 2)
    #expect(reel.index(of: UUID()) == nil)
  }

  @Test func applyIsPure() throws {
    let reel = Builders.reel([10, 12])
    let before = reel
    _ = try apply(.split(reel.clips[0].id, atSource: RationalTime(5, 1)), to: reel)
    _ = try apply(.delete([reel.clips[0].id]), to: reel)
    #expect(reel == before)
  }

  // MARK: Reel-wide time bounds (Phase 2 review)

  @Test func insertRefusesATimescaleMixThePlanCantHold() throws {
    let mix = Builders.timescaleMix
    let reel = Reel(id: UUID(), name: "mix", clips: Array(mix[0..<2]))
    #expect(throws: EditError.unsupportedTiming) { Planner.plan(try apply(.insert([mix[2]], at: 2), to: reel)) }
  }

  @Test func relinkRefusesATimescaleMixThePlanCantHold() throws {
    let mix = Builders.timescaleMix
    let reel = Reel(id: UUID(), name: "mix", clips: Array(mix[0..<2]) + [Builders.clip(5)])
    let id = reel.clips[2].id
    #expect(throws: EditError.unsupportedTiming) {
      Planner.plan(try apply(.relink(id, mix[2].source, mix[2].facts), to: reel))
    }
  }

  @Test func insertRefusesMoreThanAThousandClips() throws {
    let reel = Reel(id: UUID(), name: "full", clips: (0..<999).map { _ in Builders.clip(1) })
    #expect(try apply(.insert([Builders.clip(1)], at: 0), to: reel).clips.count == 1000)
    #expect(throws: EditError.unsupportedTiming) {
      try apply(.insert([Builders.clip(1), Builders.clip(1)], at: 0), to: reel)
    }
  }

  // MARK: probed (Phase 2 review ruling)

  @Test func probedFillsAPlaceholderClipToTheWholeSource() throws {
    // A tile added before its probe: placeholder facts, In 0, Out = placeholder duration.
    let placeholder = ReelClip.make(source: Builders.clip(1).source, facts: Builders.facts(duration: RationalTime(1, 1)),
                                    framing: .fill)
    let reel = Reel(id: UUID(), name: "p", clips: [placeholder])
    let facts = Builders.facts(duration: RationalTime(12, 1), hdr: .hlg)
    let out = try apply(.probed(placeholder.id, facts), to: reel)
    #expect(out.clips[0].facts == facts)
    #expect(out.clips[0].inTime == .zero && out.clips[0].outTime == RationalTime(12, 1))
    #expect(out.clips[0].source == placeholder.source)
  }

  @Test func probedClampsATrimmedClipAsRelinkDoes() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setIn(id, RationalTime(2, 1)), .setOut(id, RationalTime(8, 1)))
    let shorter = try apply(.probed(id, Builders.facts(duration: RationalTime(5, 1))), to: trimmed)
    #expect(shorter.clips[0].inTime == trimmed.clips[0].inTime && shorter.clips[0].outTime == RationalTime(5, 1))
    let longer = try apply(.probed(id, Builders.facts(duration: RationalTime(20, 1))), to: trimmed)
    #expect(longer.clips[0].inTime == trimmed.clips[0].inTime && longer.clips[0].outTime == trimmed.clips[0].outTime)
    #expect(longer.clips[0].facts.duration == RationalTime(20, 1))
  }

  @Test func probedUnknownClipLeavesTheReelUnchanged() throws {
    let reel = Builders.reel([5, 5])
    #expect(try apply(.probed(UUID(), Builders.facts(duration: RationalTime(9, 1))), to: reel) == reel)
  }

  @Test func probedRefusesATimescaleMixThePlanCantHold() throws {
    let mix = Builders.timescaleMix
    let reel = Reel(id: UUID(), name: "mix", clips: Array(mix[0..<2]) + [Builders.clip(5)])
    #expect(throws: EditError.unsupportedTiming) {
      Planner.plan(try apply(.probed(reel.clips[2].id, mix[2].facts), to: reel))
    }
  }

  @Test func reelEditIsEquatable() {
    let id = UUID()
    #expect(ReelEdit.setIn(id, RationalTime(1, 1)) == .setIn(id, RationalTime(2, 2)))
    #expect(ReelEdit.setIn(id, RationalTime(1, 1)) != .setOut(id, RationalTime(1, 1)))
    #expect(ReelEdit.rename("a") != .rename("b"))
  }

  @Test func setJoinSnapsACraftedCrossfade() throws {
    // [1, 2^31 − 1] was stored as is, and the next plan trapped narrowing an lcm timescale to Int32.
    let reel = Reel(id: UUID(), name: "j", clips: [Builders.clip(duration: RationalTime(60061, 30000)),
                                                   Builders.clip(duration: RationalTime(3, 1))])
    let id = reel.clips[1].id
    let out = try apply(.setJoin(id, .crossfade(RationalTime(1, 2_147_483_647))), to: reel)
    _ = Planner.plan(out)
    #expect(out.clips[1].join == .crossfade(Limits.shortFade))
    #expect(try apply(.setJoin(id, .crossfade(RationalTime(-1, 4))), to: reel).clips[1].join == .cut)
    #expect(try apply(.setJoin(id, .crossfade(RationalTime(5, 8))), to: reel).clips[1].join
      == .crossfade(Limits.shortFade))
    #expect(try apply(.setJoin(id, .crossfade(RationalTime(3, 4))), to: reel).clips[1].join
      == .crossfade(Limits.longFade))
  }
}
