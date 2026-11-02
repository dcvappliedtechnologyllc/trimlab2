import Foundation
import TrimlabEditor

/// Launch arguments that point the app somewhere else for the UI smoke test (Task 41). `-TLExportFolder <dir>` sends
/// exports to `dir` and also keeps the run out of the user's own settings: no prefs written, no window frame saved,
/// nothing added to Open Recent. (Argument-domain values are never persisted, but the app's own writes are, so each
/// of those writes checks `isolated`.) It is not a clean room: the run still writes the shared log file and the media
/// cache, and a `.trimlab` it saves records the override folder.
enum LaunchOverrides {
  static let exportFolder = OpenRouting.exportFolderOverride(arguments: CommandLine.arguments)

  /// True for a run that must not touch the user's prefs, window frame or recents.
  static let isolated = exportFolder != nil

  /// `-TLPlayAfter <seconds>`, isolated runs only: starts playback that long after launch, so a stall count can be
  /// read from a run with no UI-test harness driving it (Task 42 acceptance 2, miss 6).
  static let playAfter: Double? = {
    let args = CommandLine.arguments
    guard isolated, let flag = args.firstIndex(of: "-TLPlayAfter"), flag + 1 < args.count,
          let seconds = Double(args[flag + 1]), seconds >= 0 else { return nil }
    return seconds
  }()
}
