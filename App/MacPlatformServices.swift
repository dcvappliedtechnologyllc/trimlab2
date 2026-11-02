import AppKit
import Foundation
import TrimlabEditor
import TrimlabModel
import UniformTypeIdentifiers

/// §7.3. The editor's Mac services: the open and folder panels, Finder, QuickTime, AirDrop, Open Recent, the clipboard
/// and the modifier keys. The panels run on the main actor; the other calls hop there.
struct MacPlatformServices: PlatformServices {
  /// Whether this Mac can send with AirDrop, asked once at launch (the Done view hides the button otherwise).
  let canAirDrop: Bool

  @MainActor init() {
    canAirDrop = NSSharingService(named: .sendViaAirDrop) != nil
  }

  @MainActor
  func canAirDrop(with url: URL) -> Bool {
    NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: [url]) ?? false
  }

  /// A trimlab Reel file (Info.plist's exported type).
  static let reelType = UTType("com.dcv.trimlab.reel")

  /// Movies (QuickTime, MPEG-4, .mkv, .avi) and, with `projects`, Reel files. Several at once.
  @MainActor
  func openPanel(movies: Bool, projects: Bool) async -> [URL] {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    var types: [UTType] = []
    if movies { types += [.movie, .mpeg4Movie, .quickTimeMovie, .avi] + [UTType("org.matroska.mkv")].compactMap { $0 } }
    if projects, let reel = Self.reelType { types.append(reel) }
    panel.allowedContentTypes = types
    guard await panel.begin() == .OK else { return [] }
    return panel.urls
  }

  /// Save to's Choose…: one folder, starting at the folder shown.
  @MainActor
  func chooseFolder(start: URL?) async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = start
    guard await panel.begin() == .OK else { return nil }
    return panel.url
  }

  func reveal(_ url: URL) {
    Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }

  func openInQuickTime(_ url: URL) {
    Task { @MainActor in
      let workspace = NSWorkspace.shared
      guard let player = workspace.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") else {
        workspace.open(url)  // no QuickTime Player: the file's own default app
        return
      }
      _ = try? await workspace.open([url], withApplicationAt: player, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  func airDrop(_ url: URL) {
    Task { @MainActor in
      guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else { return }
      service.perform(withItems: [url])
    }
  }

  /// File › Open Recent.
  func noteRecent(_ url: URL) {
    guard !LaunchOverrides.isolated else { return }  // the smoke test never touches Open Recent
    Task { @MainActor in NSDocumentController.shared.noteNewRecentDocumentURL(url) }
  }

  /// Takes a path off File › Open Recent (a Reel file renamed away from it). `NSDocumentController` can only clear
  /// the whole list, so the rest are noted again, oldest first, to keep their order.
  func forgetRecent(_ url: URL) {
    guard !LaunchOverrides.isolated else { return }
    Task { @MainActor in
      let controller = NSDocumentController.shared
      let gone = url.standardizedFileURL.path
      let all = controller.recentDocumentURLs
      let kept = all.filter { $0.standardizedFileURL.path != gone }
      guard kept.count != all.count else { return }
      controller.clearRecentDocuments(nil)
      for recent in kept.reversed() { controller.noteNewRecentDocumentURL(recent) }
    }
  }

  func copy(_ text: String) {
    Task { @MainActor in
      let board = NSPasteboard.general
      board.clearContents()
      board.setString(text, forType: .string)
    }
  }

  /// Read at press time (Task 29 ruling).
  @MainActor
  func modifierKeys() -> Mods {
    let flags = NSEvent.modifierFlags
    var mods: Mods = []
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.option) { mods.insert(.option) }
    if flags.contains(.command) { mods.insert(.command) }
    if flags.contains(.control) { mods.insert(.control) }
    return mods
  }
}
