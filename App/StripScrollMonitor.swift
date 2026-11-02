import AppKit
import SwiftUI
import TrimlabEditor

/// §4.3.5, §4.4. Scroll-wheel events over the Reel strip and the trim deck, which SwiftUI can't see: ⌘-scroll zooms
/// around the pointer and, zoomed, a two-finger swipe scrolls (the strip) or pans (the deck). One monitor per model
/// and window. An event counts only when it is this window's, the window is key, and it lands inside the strip's or
/// the deck's reported frame with no modal on top (`EditorModel.stripScrollWheel` / `deckScrollWheel`); everything
/// else passes through untouched.
@MainActor
final class StripScrollMonitor {
  private weak var model: EditorModel?
  private weak var window: NSWindow?
  private var token: Any?

  init(model: EditorModel, window: NSWindow) {
    self.model = model
    self.window = window
    token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
      return used ? nil : event
    }
  }

  func uninstall() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }

  private func handle(_ event: NSEvent) -> Bool {
    guard let model, let window, event.window === window, window.isKeyWindow,
          let content = window.contentView
    else { return false }
    // Into the content view's top-left space, which is SwiftUI's global space for this window.
    let p = content.convert(event.locationInWindow, from: nil)
    let point = CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
    let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
    let command = event.modifierFlags.contains(.command), precise = event.hasPreciseScrollingDeltas
    return model.stripScrollWheel(dx: dx, dy: dy, command: command, precise: precise, at: point)
      || model.deckScrollWheel(dx: dx, dy: dy, command: command, precise: precise, at: point)
  }
}

/// Installs a `StripScrollMonitor` for `model` once the content joins its window, and removes it when the content
/// leaves the window or is torn down.
struct StripScrollMonitorInstaller: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> NSView { Probe(model: model) }
  func updateNSView(_ nsView: NSView, context: Context) {}
  static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? Probe)?.stop() }

  final class Probe: NSView {
    private weak var model: EditorModel?
    private var monitor: StripScrollMonitor?

    init(model: EditorModel) {
      self.model = model
      super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard let window, let model else { return }
      monitor = StripScrollMonitor(model: model, window: window)
    }

    func stop() {
      monitor?.uninstall()
      monitor = nil
    }
  }
}
