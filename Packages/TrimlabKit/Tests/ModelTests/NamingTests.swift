import Foundation
import Testing
@testable import TrimlabModel

@Suite struct NamingTests {
  static func clip(_ path: String, in inS: Double, out outS: Double, duration: Double = 60) -> ReelClip {
    var c = Builders.clip(duration)
    c.source.absolutePath = path
    c.inTime = RationalTime(seconds: inS)
    c.outTime = RationalTime(seconds: outS)
    return c
  }

  @Test func exportNames() {
    var one = Reel.empty(name: "Spa Tour")
    one.clips = [Self.clip("/Users/me/Movies/Spa Tour/IMG_4821.MOV", in: 3.2, out: 18.9)]
    #expect(Naming.exportFileName(one) == "IMG_4821_0m03s-0m18s.mp4")

    var two = one
    two.clips.append(Self.clip("/Users/me/Movies/Spa Tour/IMG_4830.MOV", in: 0, out: 5))
    #expect(Naming.exportFileName(two) == "Spa Tour.mp4")
  }

  @Test func exportStampsUseMinutesAndFlooredSeconds() {
    // v1 fmt_stamp: whole seconds floored, <m>m<ss>s.
    var reel = Reel.empty(name: "x")
    reel.clips = [Self.clip("/a/b/pool.take.mkv", in: 59.99, out: 125.5, duration: 200)]
    #expect(Naming.exportFileName(reel) == "pool.take_0m59s-2m05s.mp4")
  }

  @Test func emptyReelUsesItsName() {
    #expect(Naming.exportFileName(Reel.empty(name: "Spa Tour")) == "Spa Tour.mp4")
  }

  @Test func projectNames() {
    let folder = URL(fileURLWithPath: "/Users/me/Movies/Spa Tour", isDirectory: true)
    #expect(Naming.projectFileName(folder: folder, existing: []) == "Spa Tour.trimlab")
    #expect(Naming.projectFileName(folder: folder, existing: ["Spa Tour.trimlab"]) == "Spa Tour 2.trimlab")
    #expect(Naming.projectFileName(folder: folder, existing: ["Spa Tour.trimlab", "Spa Tour 2.trimlab"])
            == "Spa Tour 3.trimlab")
  }

  @Test func keepBoth() {
    #expect(Naming.keepBoth("Spa Tour.mp4", existing: []) == "Spa Tour.mp4")
    #expect(Naming.keepBoth("Spa Tour.mp4", existing: ["Spa Tour.mp4"]) == "Spa Tour 2.mp4")
    #expect(Naming.keepBoth("Spa Tour.mp4", existing: ["Spa Tour.mp4", "Spa Tour 2.mp4", "Spa Tour 3.mp4"])
            == "Spa Tour 4.mp4")
    #expect(Naming.keepBoth("notes", existing: ["notes"]) == "notes 2")
  }

  @Test func keepBothIgnoresCase() {
    // APFS is case-insensitive by default: "spa tour.mp4" is the same file.
    #expect(Naming.keepBoth("Spa Tour.mp4", existing: ["spa tour.MP4"]) == "Spa Tour 2.mp4")
  }
}
