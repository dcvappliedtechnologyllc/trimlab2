import Foundation
import Testing
@testable import TrimlabEditor
@testable import TrimlabModel

/// `PrefsDefaults`: the prefs through `UserDefaults`, read only through `Prefs.validated`. Every test uses its own
/// throwaway suite, never the app's `com.dcv.trimlab2` domain.
@Suite struct PrefsStoreTests {
  private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "trimlab2-tests.prefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  @Test func emptyStoreGivesDefaults() {
    withSuite { #expect(PrefsDefaults(defaults: $0).load() == Prefs()) }
  }

  @Test func everyFieldRoundTrips() {
    withSuite { defaults in
      let prefs = Prefs(format: .original, quality: .standard, cut: .quick, defaultFraming: .fit,
                        removeAudioDefault: true, loop: false, tcMode: .seconds, lastFolder: "/Users/x/Movies/Out")
      PrefsDefaults(defaults: defaults).save(prefs)
      #expect(PrefsDefaults(defaults: defaults).load() == prefs)
      // Stored as plain values under the field names, so they read back in `defaults read`.
      #expect(defaults.string(forKey: "format") == "original")
      #expect(defaults.object(forKey: "loop") as? Bool == false)
      #expect(defaults.string(forKey: "lastFolder") == "/Users/x/Movies/Out")
    }
  }

  @Test func clearingLastFolderRemovesIt() {
    withSuite { defaults in
      let store = PrefsDefaults(defaults: defaults)
      store.save(Prefs(lastFolder: "/a"))
      store.save(Prefs())
      #expect(defaults.object(forKey: "lastFolder") == nil)
      #expect(store.load().lastFolder == nil)
    }
  }

  @Test func badStoredValuesFallBackPerKey() {
    withSuite { defaults in
      defaults.set("square", forKey: "format")
      defaults.set(7, forKey: "quality")
      defaults.set(1, forKey: "loop")  // a number, not a Bool: falls back
      defaults.set("yes", forKey: "removeAudioDefault")
      defaults.set(false, forKey: "loop2")
      defaults.set(42, forKey: "lastFolder")
      defaults.set("seconds", forKey: "tcMode")
      defaults.set("fit", forKey: "defaultFraming")
      let p = PrefsDefaults(defaults: defaults).load()
      #expect(p.format == .reel && p.quality == .high && p.loop == true && p.removeAudioDefault == false)
      #expect(p.lastFolder == nil)
      #expect(p.tcMode == .seconds && p.defaultFraming == .fit)
    }
  }

  @Test func storedBoolFalseIsKept() {
    withSuite { defaults in
      defaults.set(false, forKey: "loop")
      #expect(PrefsDefaults(defaults: defaults).load().loop == false)
    }
  }
}
