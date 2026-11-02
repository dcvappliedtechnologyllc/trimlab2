import AppKit
import SwiftUI
import TrimlabEditor

/// The frameless window (SPEC §6.0, §4.11): hidden title bar with the traffic lights kept, content under the
/// title bar, `--bg-0` behind everything before the first frame, 1240×860 on first run, 900×720 minimum,
/// frame remembered under one autosave name, no title text.
@MainActor
enum WindowChrome {
  static let autosaveName = "trimlab2.main"
  static let firstContentSize = NSSize(width: 1240, height: 860)

  /// The main window, set by `configure` (each new window replaces it). Held by reference rather than by the
  /// autosave name (not set when isolated) or an identifier (SwiftUI owns those).
  private static weak var main: NSWindow?

  static func isMain(_ window: NSWindow?) -> Bool { window != nil && window === main }

  /// The main window, if it is still around.
  static var mainWindow: NSWindow? { main }

  static func configure(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = NSColor(Tokens.bg0)
    window.isOpaque = true
    window.minSize = NSSize(width: Tokens.Layout.minWindow.width, height: Tokens.Layout.minWindow.height)
    window.contentMinSize = window.minSize
    // The header is the drag region (WindowDragGesture); the rest of the window must not move it.
    window.isMovableByWindowBackground = false
    window.tabbingMode = .disallowed
    main = window

    // Read the saved frame before anything can overwrite it. SwiftUI sizes the new window once more after its
    // content joins (scene default/ideal size), so the frame is placed now and again on the next run-loop turn,
    // and only then does the autosave name start recording, so SwiftUI's interim size is never saved.
    let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)")
    place(window, saved: saved)
    DispatchQueue.main.async {
      place(window, saved: saved)
      // The smoke test never saves a frame.
      if !LaunchOverrides.isolated { window.setFrameAutosaveName(autosaveName) }
      if window.isVisible, window.occlusionState.contains(.visible) { FileLog.windowShown() }
    }
    // `window shown` in the log (§10 cold launch to window): the first time the window is actually on screen.
    // A window configured again (reopened) replaces the old observer rather than adding a second one.
    if let old = shownObserver { NotificationCenter.default.removeObserver(old) }
    shownObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak window] _ in
      MainActor.assumeIsolated {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        // Every change, not only the first: whether a covered run was ever brought forward (Task 42 acc. 2, miss 1).
        FileLog.note(visible ? "window: on screen" : "window: covered")
        if visible { FileLog.windowShown() }
      }
    }
  }

  private static var shownObserver: (any NSObjectProtocol)?

  /// The saved frame when there is one (clamped onto a visible screen, at least the minimum size);
  /// otherwise 1240×860 content, centred: the very first run.
  private static func place(_ window: NSWindow, saved: String?) {
    if let saved {
      window.setFrame(from: saved)
    } else {
      window.setContentSize(firstContentSize)
      window.center()
    }
    guard let screen = window.screen ?? NSScreen.main else { return }
    let clamped = clamp(window.frame, to: screen.visibleFrame, min: window.minSize)
    if clamped != window.frame { window.setFrame(clamped, display: false) }
  }

  /// `frame` resized to fit `visible` (never below `min`) and moved fully onto it.
  static func clamp(_ frame: NSRect, to visible: NSRect, min: NSSize) -> NSRect {
    var f = frame
    f.size.width = max(min.width, Swift.min(f.width, visible.width))
    f.size.height = max(min.height, Swift.min(f.height, visible.height))
    f.origin.x = max(visible.minX, Swift.min(f.minX, visible.maxX - f.width))
    f.origin.y = max(visible.minY, Swift.min(f.minY, visible.maxY - f.height))
    return f
  }
}

/// Hands the hosting `NSWindow` to `WindowChrome.configure` once, as soon as the content joins it
/// (before the window is first drawn).
struct WindowChromeInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Probe() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Probe: NSView {
    private weak var configured: NSWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, window !== configured else { return }
      configured = window
      WindowChrome.configure(window)
    }
  }
}
