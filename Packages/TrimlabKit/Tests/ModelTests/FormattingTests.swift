import Foundation
import Testing
@testable import TrimlabModel

@Suite struct FormattingTests {
  private let nbsp = "\u{00A0}"

  @Test func fade() {
    #expect(Formatting.fade(RationalTime(3, 5)) == "0.6\(nbsp)s")
    #expect(Formatting.fade(RationalTime(1, 4)) == "0.25\(nbsp)s")
    #expect(Formatting.fade(RationalTime(1, 1)) == "1\(nbsp)s")
    #expect(Formatting.fade(RationalTime(1, 20)) == "0.05\(nbsp)s")
    #expect(Formatting.fade(RationalTime(199, 200)) == "1\(nbsp)s")  // 0.995 rounds up
  }

  @Test func timecode() {
    #expect(Formatting.timecode(RationalTime(7 * 30 + 12, 30), frame: RationalTime(1, 30)) == "0:07.12")
  }

  @Test func timecodeMinutesAndNTSC() {
    let fd = RationalTime(1001, 30000)
    #expect(Formatting.timecode(.zero, frame: fd) == "0:00.00")
    // 134 s + 29 frames at 29.97 is still inside second 134 (29 × 1001/30000 = 0.968 s).
    #expect(Formatting.timecode(RationalTime(134, 1) + fd * 29, frame: fd) == "2:14.29")
    #expect(Formatting.timecode(RationalTime(1, 1) - RationalTime(1, 1000), frame: fd) == "0:00.29")
    #expect(Formatting.timecode(RationalTime(61, 1) + RationalTime(5, 60), frame: RationalTime(1, 60)) == "1:01.05")
  }

  @Test func seconds() {
    #expect(Formatting.seconds(RationalTime(124, 10)) == "12.40\(nbsp)s")
    #expect(Formatting.seconds(RationalTime(1001, 30000)) == "0.03\(nbsp)s")
    #expect(Formatting.seconds(RationalTime(134, 1)) == "134.00\(nbsp)s")
  }

  @Test func totals() {
    #expect(Formatting.total(RationalTime(482, 10)) == "48.2\u{00A0}s")
    #expect(Formatting.total(RationalTime(1346, 10)) == "2:14.6")
  }

  @Test func totalsMinuteBoundary() {
    #expect(Formatting.total(RationalTime(599, 10)) == "59.9\(nbsp)s")
    #expect(Formatting.total(RationalTime(60, 1)) == "1:00.0")
    // 59.96 s rounds to 60.0, so it reads in minutes, never "60.0 s".
    #expect(Formatting.total(RationalTime(5996, 100)) == "1:00.0")
    #expect(Formatting.total(RationalTime(180, 1)) == "3:00.0")
    #expect(Formatting.total(.zero) == "0.0\(nbsp)s")
  }

  @Test func trimMoreRoundsUp() {
    #expect(Formatting.trimMore(RationalTime(1001, 30000)) == "0:00.1")
    #expect(Formatting.trimMore(RationalTime(124, 10)) == "0:12.4")
  }

  @Test func trimMoreMinutes() {
    #expect(Formatting.trimMore(RationalTime(1241, 100)) == "0:12.5")
    #expect(Formatting.trimMore(RationalTime(75, 1)) == "1:15.0")
    #expect(Formatting.trimMore(RationalTime(5999, 100)) == "1:00.0")
  }

  @Test func clipLength() {
    #expect(Formatting.clipLength(RationalTime(85, 10)) == "8.5\(nbsp)s")
    #expect(Formatting.clipLength(RationalTime(4, 10)) == "0.4\(nbsp)s")
    #expect(Formatting.clipLength(RationalTime(1001 * 255, 30000)) == "8.5\(nbsp)s")  // 8.5085 s
  }
}
