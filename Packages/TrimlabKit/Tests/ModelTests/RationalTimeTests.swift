import Foundation
import Testing
@testable import TrimlabModel

@Suite struct RationalTimeTests {
  @Test func normalises() { #expect(RationalTime(2002, 60000) == RationalTime(1001, 30000)) }

  @Test func normalisedFieldsAreStored() {
    let t = RationalTime(2002, 60000)
    #expect(t.value == 1001 && t.timescale == 30000)
    let z = RationalTime(0, 600)
    #expect(z.value == 0 && z.timescale == 1)
    #expect(z == .zero)
  }

  @Test func negativeTimescaleFlipsSign() {
    let t = RationalTime(1, -4)
    #expect(t.value == -1 && t.timescale == 4)
  }

  @Test func addsAcrossScales() { #expect(RationalTime(1001, 30000) + RationalTime(1, 2) == RationalTime(16001, 30000)) }

  @Test func subtracts() {
    #expect(RationalTime(1, 2) - RationalTime(1001, 30000) == RationalTime(13999, 30000))
    #expect(RationalTime(1, 4) - RationalTime(1, 2) == RationalTime(-1, 4))
  }

  @Test func multipliesByInteger() { #expect(RationalTime(1001, 30000) * 30 == RationalTime(1001, 1000)) }

  @Test func floorsToFrame() {
    // 0.1 s is inside frame 2 of 29.97
    #expect(RationalTime(1, 10).floored(toFrame: RationalTime(1001, 30000)) == RationalTime(2002, 30000))
  }

  @Test func floorsExactFrameToItself() {
    let fd = RationalTime(1001, 30000)
    #expect((fd * 36).floored(toFrame: fd) == fd * 36)
  }

  @Test func floorsNegativeDownward() {
    #expect(RationalTime(-1, 10).floored(toFrame: RationalTime(1, 30)) == RationalTime(-3, 30))
  }

  @Test func roundsToNearestFrame() {
    let fd = RationalTime(1, 30)
    #expect(RationalTime(1, 10).rounded(toFrame: fd) == RationalTime(3, 30))   // exactly frame 3
    #expect(RationalTime(4, 100).rounded(toFrame: fd) == RationalTime(1, 30))  // 1.2 frames → 1
    #expect(RationalTime(5, 100).rounded(toFrame: fd) == RationalTime(2, 30))  // 1.5 frames → 2 (ties up)
  }

  @Test func halves() {
    #expect(RationalTime(1, 1).halved() == RationalTime(1, 2))
    #expect(RationalTime(1001, 30000).halved() == RationalTime(1001, 60000))
    #expect(RationalTime(6, 5).halved() == RationalTime(3, 5))
  }

  @Test func comparesExactly() {
    // 30 frames of 29.97 = 1.001 s
    #expect(RationalTime(1001, 30000) * 30 > RationalTime(1, 1))
    #expect(RationalTime(1, 3) < RationalTime(1, 2))
    #expect(min(RationalTime(1, 3), RationalTime(1, 2)) == RationalTime(1, 3))
    #expect(max(RationalTime(1, 3), RationalTime(1, 2)) == RationalTime(1, 2))
  }

  @Test func comparesHugeValuesWithoutOverflow() {
    let a = RationalTime(Int64.max / 2, 30001)
    let b = RationalTime(Int64.max / 2 - 1, 30001)
    #expect(b < a)
  }

  @Test func secondsForDisplay() { #expect(RationalTime(1, 4).seconds == 0.25) }

  @Test func initFromSecondsRounds() {
    #expect(RationalTime(seconds: 1.5) == RationalTime(3, 2))
    #expect(RationalTime(seconds: 0.0012) == RationalTime(1, 600))
    #expect(RationalTime(seconds: 1.21, timescale: 100) == RationalTime(121, 100))
  }

  @Test func hashMatchesEquality() {
    #expect(Set([RationalTime(1, 2), RationalTime(2, 4), RationalTime(500, 1000)]).count == 1)
  }

  @Test func jsonIsPair() throws {
    #expect(String(data: try JSONEncoder().encode(RationalTime(1001, 30000)), encoding: .utf8) == "[1001,30000]")
  }

  @Test func jsonDecodesAndNormalises() throws {
    let t = try JSONDecoder().decode(RationalTime.self, from: Data("[2002,60000]".utf8))
    #expect(t.value == 1001 && t.timescale == 30000)
  }

  @Test func jsonRejectsZeroTimescale() {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(RationalTime.self, from: Data("[1,0]".utf8)) }
  }

  @Test func limits() {
    #expect(Limits.minSpan == RationalTime(1, 2))
    #expect(Limits.reelMax == RationalTime(180, 1))
    #expect(Limits.shortFade == RationalTime(1, 4))
    #expect(Limits.longFade == RationalTime(1, 1))
    #expect(Limits.splitEdge == RationalTime(1, 2))
  }
}
