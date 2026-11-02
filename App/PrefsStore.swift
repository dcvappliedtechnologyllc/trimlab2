import Foundation
import Observation
import TrimlabEditor
import TrimlabModel

/// §4.11 prefs in the app's own defaults domain, `com.dcv.trimlab2`: read once at launch (only through
/// `Prefs.validated`, by `PrefsDefaults`), then written each time the model's prefs change (Loop, the timecode mode,
/// an export's format, cut, quality and folder).
@MainActor
final class PrefsStore {
  static let domain = "com.dcv.trimlab2"
  private let store: PrefsDefaults
  private var saved: Prefs?

  init() {
    // `UserDefaults(suiteName:)` refuses the app's own bundle id ("does not make sense and will not work"): the
    // standard defaults already are the com.dcv.trimlab2 domain when running as the app.
    let defaults = Bundle.main.bundleIdentifier == Self.domain ? UserDefaults.standard
      : (UserDefaults(suiteName: Self.domain) ?? .standard)
    store = PrefsDefaults(defaults: defaults)
  }

  func load() -> Prefs {
    let prefs = store.load()
    saved = prefs
    FileLog.note("prefs: \(Self.describe(prefs))")
    return prefs
  }

  /// Saves `model.prefs` whenever it changes, for as long as the app runs.
  func watch(_ model: EditorModel) {
    withObservationTracking {
      _ = model.prefs
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.save(model.prefs)
        self.watch(model)
      }
    }
  }

  private func save(_ prefs: Prefs) {
    guard !LaunchOverrides.isolated else { return }  // the UI smoke test never writes the user's prefs
    guard prefs != saved else { return }
    store.save(prefs)
    saved = prefs
    FileLog.note("prefs saved: \(Self.describe(prefs))")
  }

  private static func describe(_ p: Prefs) -> String {
    "format \(p.format.rawValue), quality \(p.quality.rawValue), cut \(p.cut.rawValue), framing "
      + "\(p.defaultFraming.rawValue), removeAudio \(p.removeAudioDefault), loop \(p.loop), tc \(p.tcMode.rawValue), "
      + "lastFolder \(p.lastFolder ?? "none")"
  }
}
