import Foundation
import Testing
@testable import TrimlabModel

@Suite struct PrefsTests {
  @Test func prefsDefaults() {
    #expect(Prefs.validated([:]) == Prefs())
    let p = Prefs()
    #expect(p.format == .reel && p.quality == .high && p.cut == .exact)
    #expect(p.defaultFraming == .fill && !p.removeAudioDefault && p.loop)
    #expect(p.tcMode == .timecode && p.lastFolder == nil)
  }

  @Test func prefsBadValuesFallBackPerKey() {
    let p = Prefs.validated(["format": .string("square"), "loop": .bool(false), "quality": .number(7)])
    #expect(p.format == .reel)
    #expect(p.loop == false)
    #expect(p.quality == .high)
  }

  @Test func lastFolderMustBeAbsolute() {
    for bad in ["", "relative/dir", "~/Movies", "file:///tmp"] {
      #expect(Prefs.validated(["lastFolder": .string(bad), "loop": .bool(false)]).lastFolder == nil)
    }
    #expect(Prefs.validated(["lastFolder": .string("/Users/x/Movies")]).lastFolder == "/Users/x/Movies")
  }

  @Test func goodValuesSurviveBadNeighbours() {
    let p = Prefs.validated([
      "format": .string("original"), "cut": .string("nope"), "tcMode": .string("seconds"),
      "defaultFraming": .string("fit"), "removeAudioDefault": .string("yes"),
      "lastFolder": .string("/tmp/x"), "mystery": .bool(true),
    ])
    #expect(p.format == .original && p.cut == .exact && p.tcMode == .seconds)
    #expect(p.defaultFraming == .fit && p.removeAudioDefault == false)
    #expect(p.lastFolder == "/tmp/x")
    #expect(Prefs.validated(["lastFolder": .number(3)]).lastFolder == nil)
  }

  @Test func codableRoundTrip() throws {
    var p = Prefs()
    p.tcMode = .seconds; p.lastFolder = "/a"
    let back = try JSONDecoder().decode(Prefs.self, from: JSONEncoder().encode(p))
    #expect(back == p)
  }
}
