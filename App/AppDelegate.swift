import AppKit
import TrimlabEditor

/// Quit (§4.9, §8.2): a running export is cancelled (its partial deleted) and the Reel saved, both at once; the app
/// waits for them up to `EditorModel.quitSaveLimit` (3 s), then goes anyway.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var model: EditorModel?

  /// SwiftUI makes the main window before this runs when it is going to (measured in Task 42). It
  /// doesn't when the command line carries bare paths, as `-TLOpen a.mov b.mov` does (only the first path pairs
  /// with the flag): AppKit takes the rest as files to open from the command line and skips the default window, so
  /// the app would sit windowless. In that case bring the window back on the next turn (the reopen event is what a
  /// Dock click sends); waiting longer only delays the window.
  func applicationDidFinishLaunching(_ notification: Notification) {
    if LaunchOverrides.isolated { FileLog.note("isolated run (smoke test): exports to \(LaunchOverrides.exportFolder ?? "?")") }
    DispatchQueue.main.async {
      guard WindowChrome.mainWindow == nil, !NSApp.windows.contains(where: { $0.isVisible }) else { return }
      FileLog.note("launch: no window at launch, sending reopen")
      Self.bringBackMainWindow()
    }
  }

  /// Orders the main window front if it exists, otherwise sends ourselves the reopen event and comes forward. Safe
  /// only because the scene is a single-instance `Window`; revisit if it becomes a `WindowGroup`.
  static func bringBackMainWindow() {
    if let window = WindowChrome.mainWindow {
      window.makeKeyAndOrderFront(nil)
      return
    }
    let me = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
    let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                        targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                        transactionID: AETransactionID(kAnyTransactionID))
    _ = try? reopen.sendEvent(options: [.noReply], timeout: 1)
    NSApp.activate()
  }

  func applicationWillFinishLaunching(_ notification: Notification) { OpenQueue.enqueueLaunchArguments() }

  /// Finder Open With, a Dock drop and Open Recent; also at launch, before the model exists (queued, never dropped).
  func application(_ application: NSApplication, open urls: [URL]) {
    OpenQueue.enqueue(urls)
    // Closing the window doesn't quit the app (no terminate-after-last-window), so an open event brings it back.
    Self.bringBackMainWindow()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    Task {
      await model.prepareForQuit()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
