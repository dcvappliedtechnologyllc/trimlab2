import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import TrimlabEditor
import TrimlabMedia
import TrimlabModel

@main
struct TrimlabApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: EditorModel
  private let media: LiveMediaServices
  private let prefsStore: PrefsStore
  private let watchdog: StallWatchdog

  init() {
    FileLog.start()
    // The brand is dark-only: traffic lights, menus and the Open panels follow it (controller ruling, T7).
    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    // The export Error view's Details read the file log's last lines.
    let media = LiveMediaServices(logTail: { FileLog.tail($0) })
    self.media = media
    let prefsStore = PrefsStore()
    self.prefsStore = prefsStore
    // The smoke test starts from the default prefs and sweeps no real folder: its run must not depend on, or act on,
    // the user's own history.
    let prefs = LaunchOverrides.isolated ? Prefs() : prefsStore.load()
    let model = EditorModel(platform: MacPlatformServices(), media: media, store: LiveProjectStore(), prefs: prefs,
                            clock: ContinuousClock(), preview: PreviewEngine())
    model.exportFolderOverride = LaunchOverrides.exportFolder
    _model = State(initialValue: model)
    prefsStore.watch(model)
    watchdog = StallWatchdog(model: model)
    watchdog.install()
    if let delay = LaunchOverrides.playAfter { Self.play(model, after: delay) }
    // Off the main actor, at once: the GPU state the first preview and HDR frame need (37–266 ms on first use, T23),
    // then the sweep of what a crash left behind in the cache and the last export's folder.
    let folders = ExportSweep.folders(lastFolder: LaunchOverrides.isolated ? nil : prefs.lastFolder, reelFolder: nil)
    Task { await media.warmUp(sweeping: folders) }
  }

  /// `-TLPlayAfter`: plays `delay` seconds after launch, once the `-TLOpen` clips are probed and have a plan to play
  /// (`play()` does nothing without one), and logs whether playback really started. Gives up, saying so, after 30 s
  /// more.
  private static func play(_ model: EditorModel, after delay: Double) {
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      let deadline = ContinuousClock.now + .seconds(30)
      while model.plan?.placements.isEmpty ?? true || !model.loadingClipIDs.isEmpty {
        guard ContinuousClock.now < deadline else {
          FileLog.note("isolated run: -TLPlayAfter \(delay) failed: no probed Reel to play 30 s after the delay")
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      model.play()
      FileLog.note(model.isPlaying ? "isolated run: playing (-TLPlayAfter \(delay))"
                     : "isolated run: -TLPlayAfter \(delay) failed: play() didn't start playback")
    }
  }

  var body: some Scene {
    Window("trimlab 2", id: "main") {
      MainWindowContent(model: model, media: media)
        .onAppear {
          appDelegate.model = model
          OpenQueue.attach(model)
        }
        .frame(minWidth: Tokens.Layout.minWindow.width, minHeight: Tokens.Layout.minWindow.height)
        .containerBackground(Tokens.bg0, for: .window)
        .background(WindowChromeInstaller())
    }
    .windowStyle(.hiddenTitleBar)
    // No .defaultSize: WindowChrome owns the frame (the saved one, or 1240×860 on first run) through its
    // autosave name; SwiftUI's default size and its own restoration would both override it.
    .restorationBehavior(.disabled)
    .commands { TrimlabCommands(model: model) }
  }
}

/// The root view with the DCV logo rasterised at this window's backing scale.
private struct MainWindowContent: View {
  let model: EditorModel
  let media: LiveMediaServices
  @Environment(\.displayScale) private var displayScale
  @State private var sweptReels: Set<UUID> = []

  /// Where this Reel's exports go: the folder chosen for it, else its first clip's (`ExportForm.folder`).
  private func reelExportFolder() -> URL? {
    guard let reel = model.reel else { return nil }
    if let chosen = reel.export.folder { return URL(filePath: chosen, directoryHint: .isDirectory) }
    guard let first = reel.clips.first else { return nil }
    return model.url(for: first.id)?.deletingLastPathComponent()
  }

  var body: some View {
    RootView(model: model, logo: AppLogo.image(scale: displayScale),
             onHelp: { model.command(.keyMap) }, onExport: { model.command(.export) }) { player in
      PlayerSurface(player: player)
    }
    // A Reel opened (or started) sweeps its own export folder too, once, off the main actor (`ExportSweep`).
    // Keyed on the folder too: a Reel whose first clip isn't resolved yet is swept once it is.
    .onChange(of: ReelSweepKey(id: model.reel?.id, folder: reelExportFolder()), initial: true) { _, key in
      guard let id = key.id, !sweptReels.contains(id) else { return }
      let folders = ExportSweep.folders(lastFolder: nil, reelFolder: key.folder)
      guard !folders.isEmpty else { return }
      sweptReels.insert(id)
      Task.detached(priority: .utility) { ExportSweep.sweep(folders: folders) }
    }
    .background(StripScrollMonitorInstaller(model: model))
    .background(KeyMonitorInstaller(model: model))
    // §8.2: the Reel is saved on window close as well as after each edit (quit: `AppDelegate`). The main window
    // closing also takes the export sheet with it; an export still running is cancelled by its next report (§4.9).
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
      model.commitOpenRename()  // a Reel name still being typed is kept
      model.saveNow()
      if WindowChrome.isMain(note.object as? NSWindow) { model.forceCloseExportSheet() }
    }
    // §4.1: the ffmpeg card rechecks when the window comes back (after a Terminal trip to install it).
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
      if WindowChrome.isMain(note.object as? NSWindow) { model.recheckFFmpeg() }
    }
  }
}

/// The bundled vector logo (`dcv-logo-white.pdf`), rendered once per backing scale.
@MainActor
private enum AppLogo {
  private static var cache: [CGFloat: CGImage] = [:]

  static func image(scale: CGFloat) -> CGImage? {
    if let hit = cache[scale] { return hit }
    guard let url = Bundle.main.url(forResource: "dcv-logo-white", withExtension: "pdf"),
          let image = Logo.render(pdf: url, height: HeaderView.logoHeight, scale: scale)
    else { return nil }
    cache[scale] = image
    return image
  }
}

/// What the Reel-folder sweep waits on: the open Reel and where its exports go.
private struct ReelSweepKey: Equatable {
  let id: UUID?
  let folder: URL?
}
