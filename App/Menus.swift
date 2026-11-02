// menu-bar
import AppKit
import SwiftUI
import TrimlabEditor
import TrimlabModel

/// §4.7, §4.10. The ⌘ shortcuts are menu items in the system menu bar. Each runs the same `EditorModel.command` a key
/// does, and all are disabled while a modal is on top. Cut, Copy and Paste stay system items for text fields.
struct TrimlabCommands: Commands {
  let model: EditorModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Reel") { model.command(.newReel) }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!model.menuEnabled)
      Button("Open\u{2026}") { model.command(.open) }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(!model.menuEnabled)
      // File > Open Recent, from the system's recent-documents list (Task 36's `noteRecent` fills it).
      Menu("Open Recent") {
        ForEach(recents, id: \.self) { url in
          Button(url.lastPathComponent) { model.openExternally([url]) }
        }
        Divider()
        Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
          .disabled(recents.isEmpty)
      }
      .disabled(!model.menuEnabled)
    }
    CommandGroup(after: .importExport) {
      Button("Export\u{2026}") { model.command(.export) }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!model.menuEnabled || !model.hasClips)
    }
    CommandGroup(replacing: .undoRedo) {
      Button("Undo") { edit(.undo) }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!model.menuEnabled || !model.history.canUndo)
      Button("Redo") { edit(.redo) }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!model.menuEnabled || !model.history.canRedo)
    }
    CommandGroup(replacing: .pasteboard) {
      Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
        .keyboardShortcut("x", modifiers: .command)
      Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
        .keyboardShortcut("c", modifiers: .command)
      Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        .keyboardShortcut("v", modifiers: .command)
      Button("Select All") { edit(.selectAll) }
        .keyboardShortcut("a", modifiers: .command)
        .disabled(!model.menuEnabled || !model.hasClips)
    }
    CommandGroup(replacing: .toolbar) {
      Button("Zoom Deck In") { model.command(.deckZoom(1)) }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(!model.menuEnabled || !model.hasClips)
      Button("Zoom Deck Out") { model.command(.deckZoom(-1)) }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(!model.menuEnabled || !model.hasClips)
      Divider()
      Button("Zoom Strip In") { model.command(.stripZoom(1)) }
        .keyboardShortcut("=", modifiers: [.option, .command])
        .disabled(!model.menuEnabled || !model.hasClips)
      Button("Zoom Strip Out") { model.command(.stripZoom(-1)) }
        .keyboardShortcut("-", modifiers: [.option, .command])
        .disabled(!model.menuEnabled || !model.hasClips)
      Button("Fit Strip") { model.command(.stripZoomFit) }
        .keyboardShortcut("0", modifiers: [.option, .command])
        .disabled(!model.menuEnabled || !model.hasClips)
    }
    CommandGroup(replacing: .help) {
      // `?` itself is a plain key (KeyMonitor); a menu key equivalent without ⌘ would steal it from text fields.
      Button("Keys (?)") { model.command(.keyMap) }
        .disabled(!model.menuEnabled)
    }
  }

  /// The list is read when SwiftUI rebuilds the menu, which `model.projectURL` changing prompts (a Reel opened or saved).
  private var recents: [URL] {
    _ = model.projectURL
    return NSDocumentController.shared.recentDocumentURLs
  }

  /// Undo, Redo and Select All go to a text field that is being edited, as ⌘Z does from the keyboard.
  private func edit(_ command: Command) {
    if let window = NSApp.keyWindow, KeyRouting.isEditingText(in: window) {
      NSApp.sendAction(KeyRouting.fieldSelector(for: command), to: nil, from: nil)
    } else {
      model.command(command)
    }
  }
}
