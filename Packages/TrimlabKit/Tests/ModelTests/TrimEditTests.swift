import Foundation
import Testing
@testable import TrimlabModel

@Suite struct TrimEditTests {
  let fd = RationalTime(1001, 30000)

  /// Applies edits in order, failing the test on any throw.
  private func run(_ reel: Reel, _ edits: ReelEdit...) throws -> Reel {
    try edits.reduce(reel) { try apply($1, to: $0) }
  }

  @Test func setInFloorsToFrame() throws {
    let reel = Builders.reel([23.6])
    let id = reel.clips[0].id
    let out = try apply(.setIn(id, RationalTime(seconds: 1.21)), to: reel)
    #expect(out.clips[0].inTime == RationalTime(36036, 30000))
  }

  @Test func setOutClampsToDuration() throws {
    let reel = Builders.reel([23.6])
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setOut(id, RationalTime(10, 1)))
    let out = try apply(.setOut(id, RationalTime(99, 1)), to: trimmed)
    #expect(out.clips[0].outTime == out.clips[0].facts.duration)
  }

  @Test func setInNegativeClampsToZero() throws {
    let reel = Builders.reel([23.6])
    let id = reel.clips[0].id
    let moved = try run(reel, .setIn(id, RationalTime(2, 1)))
    let out = try apply(.setIn(id, RationalTime(-5, 1)), to: moved)
    #expect(out.clips[0].inTime == .zero)
  }

  @Test func minSpanEnforced() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let r = try run(reel, .setIn(id, RationalTime(1, 1)))  // floors to 29 frames, 0.9676 s
    #expect(r.clips[0].inTime == fd * 29)
    #expect(throws: EditError.spanTooShort) { try apply(.setOut(id, RationalTime(seconds: 1.4)), to: r) }
    let ok = try apply(.setOut(id, RationalTime(seconds: 1.5)), to: r)
    #expect(ok.clips[0].outTime == fd * 44)
    #expect(ok.clips[0].trimmed >= Limits.minSpan)
  }

  @Test func handlesCannotCross() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let r = try run(reel, .setOut(id, RationalTime(5, 1)))
    #expect(throws: EditError.crossesHandle) { try apply(.setIn(id, RationalTime(6, 1)), to: r) }
    let outAtIn = try run(reel, .setIn(id, RationalTime(3, 1)))
    #expect(throws: EditError.crossesHandle) { try apply(.setOut(id, RationalTime(2, 1)), to: outAtIn) }
    // In landing on Out is also a crossing, not a short span.
    #expect(throws: EditError.crossesHandle) { try apply(.setIn(id, r.clips[0].outTime), to: r) }
  }

  @Test func resetInAndOut() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let trimmed = try run(reel, .setIn(id, RationalTime(2, 1)), .setOut(id, RationalTime(6, 1)))
    let back = try run(trimmed, .resetIn(id), .resetOut(id))
    #expect(back.clips[0].inTime == .zero)
    #expect(back.clips[0].outTime == back.clips[0].facts.duration)
  }

  @Test func unknownClipThrows() {
    let reel = Builders.reel([10])
    let ghost = UUID()
    for e in [ReelEdit.setIn(ghost, .zero), .setOut(ghost, RationalTime(5, 1)), .resetIn(ghost), .resetOut(ghost)] {
      #expect(throws: EditError.unknownClip) { try apply(e, to: reel) }
    }
  }

  @Test func tinyClipHandlesCannotMove() throws {
    let reel = Builders.reel([0.4])
    let id = reel.clips[0].id
    #expect(throws: EditError.spanTooShort) { try apply(.setIn(id, RationalTime(seconds: 0.1)), to: reel) }
    #expect(throws: EditError.spanTooShort) { try apply(.setOut(id, RationalTime(seconds: 0.3)), to: reel) }
    #expect(reel.clips[0].trimmed == reel.clips[0].facts.duration)
  }

  @Test func applyIsPure() throws {
    let reel = Builders.reel([10, 12])
    let before = reel
    _ = try apply(.setIn(reel.clips[0].id, RationalTime(2, 1)), to: reel)
    #expect(reel == before)
  }

  // MARK: Task 10 carries

  @Test func exactlyHalfSecondClip() throws {
    let reel = Builders.reel([0.5])
    let id = reel.clips[0].id
    #expect(reel.clips[0].trimmed == Limits.minSpan)
    // Required span is min(0.5 s, duration) = the whole clip: nothing may move.
    #expect(throws: EditError.spanTooShort) { try apply(.setIn(id, fd * 3), to: reel) }
    #expect(throws: EditError.spanTooShort) { try apply(.setOut(id, RationalTime(seconds: 0.4)), to: reel) }
    #expect(try apply(.setIn(id, .zero), to: reel) == reel)
    #expect(try apply(.setOut(id, RationalTime(1, 1)), to: reel) == reel)
  }

  @Test func crossingWinsOverTooShort() throws {
    let reel = Builders.reel([10])
    let id = reel.clips[0].id
    let r = try run(reel, .setIn(id, RationalTime(3, 1)), .setOut(id, RationalTime(3, 1) + RationalTime(seconds: 0.6)))
    // Past Out is both a crossing and (as a span) too short: crossing is reported.
    #expect(throws: EditError.crossesHandle) { try apply(.setIn(id, RationalTime(7, 1)), to: r) }
    #expect(throws: EditError.crossesHandle) { try apply(.setOut(id, RationalTime(1, 1)), to: r) }
    // Short of Out but under 0.5 s: too short.
    #expect(throws: EditError.spanTooShort) { try apply(.setIn(id, r.clips[0].outTime - fd * 3), to: r) }
  }

  @Test func offGridOutAtDurationThenSetIn() throws {
    let reel = Builders.reel([10])  // 299.7 frames: the duration is off-grid
    let id = reel.clips[0].id
    let r = try run(reel, .setOut(id, RationalTime(99, 1)), .setIn(id, RationalTime(5, 1)))
    #expect(r.clips[0].outTime == RationalTime(10, 1))
    #expect(r.clips[0].inTime == fd * 149)
  }

  @Test func zeroFrameDurationClampsWithoutTrapping() throws {
    var reel = Builders.reel([10])
    reel.clips[0] = Builders.clip(10, fps: .zero)
    let id = reel.clips[0].id
    let r = try run(reel, .setIn(id, RationalTime(seconds: 1.21)), .setOut(id, RationalTime(99, 1)))
    #expect(r.clips[0].inTime == RationalTime(seconds: 1.21))
    #expect(r.clips[0].outTime == RationalTime(10, 1))
    let neg = Builders.clip(10, fps: RationalTime(-1, 30))
    let r2 = try apply(.setIn(neg.id, RationalTime(2, 1)), to: Reel(id: UUID(), name: "n", clips: [neg]))
    #expect(r2.clips[0].inTime == RationalTime(2, 1))
  }
}
