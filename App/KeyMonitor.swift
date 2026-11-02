import AppKit
import SwiftUI
import TrimlabEditor
import TrimlabModel

/// §4.7. Plain keys, which SwiftUI can't take without a focused view: turns key events into `KeyChord`s and hands them
/// to `EditorModel.handleKey`, which decides who owns the key. One monitor per window. An event counts only when it is
/// this window's and the window is key; ⌘ chords go back to the menus (`Menus.swift`) except the edit commands of a
/// focused text field.
@MainActor
final class KeyMonitor {
  private weak var model: EditorModel?
  private weak var window: NSWindow?
  nonisolated(unsafe) private var token: Any?
  nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

  init(model: EditorModel, window: NSWindow) {
    self.model = model
    self.window = window
    // A key-up can be lost when the window or app stops being key mid-hold: end a held ⌥ move then.
    let center = NotificationCenter.default
    for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?),
                           (NSApplication.didResignActiveNotification, nil)] {
      observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.model?.endKeyGesture() }
      })
    }
    token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
      return used ? nil : event
    }
  }

  deinit { remove() }

  func uninstall() { remove() }

  private nonisolated func remove() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
  }

  /// Whether the event is swallowed.
  private func handle(_ event: NSEvent) -> Bool {
    guard let model, let window, event.window === window, window.isKeyWindow,
          let chord = KeyEvents.chord(keyCode: event.keyCode, characters: event.characters,
                                      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                      flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    else { return false }
    if event.type == .keyUp {
      model.handleKeyUp(chord)
      return false  // key-ups always go on
    }
    switch model.handleKey(chord, isRepeat: event.isARepeat, inTextField: KeyRouting.isEditingText(in: window),
                           composing: KeyRouting.isComposingText(in: window)) {
    case .pass: return false
    case .swallow: return true
    case .sendToField(let command):
      NSApp.sendAction(KeyRouting.fieldSelector(for: command), to: nil, from: nil)
      return true
    }
  }
}

/// The text-field checks the key monitor and the menus share. No state.
@MainActor
enum KeyRouting {
  /// A text field (or its field editor) has focus.
  static func isEditingText(in window: NSWindow) -> Bool {
    guard let responder = window.firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }

  /// An input method is composing in the focused field (marked text: an IME, a dead key, the accent picker): its
  /// Return and Esc confirm or cancel the composition, so the rename leaves them alone.
  static func isComposingText(in window: NSWindow) -> Bool {
    (window.firstResponder as? NSTextView)?.hasMarkedText() == true
  }

  /// The responder-chain action for an edit command a field takes for itself.
  static func fieldSelector(for command: Command) -> Selector {
    switch command {
    case .undo: Selector(("undo:"))
    case .redo: Selector(("redo:"))
    default: #selector(NSText.selectAll(_:))
    }
  }
}

/// Installs a `KeyMonitor` for `model` once the content joins its window, and removes it when the content leaves the
/// window or is torn down.
struct KeyMonitorInstaller: NSViewRepresentable {
  let model: EditorModel

  func makeNSView(context: Context) -> NSView { Probe(model: model) }
  func updateNSView(_ nsView: NSView, context: Context) {}
  static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? Probe)?.stop() }

  final class Probe: NSView {
    private weak var model: EditorModel?
    private var monitor: KeyMonitor?

    init(model: EditorModel) {
      self.model = model
      super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard let window, let model else { return }
      monitor = KeyMonitor(model: model, window: window)
    }

    func stop() {
      monitor?.uninstall()
      monitor = nil
    }
  }
}
