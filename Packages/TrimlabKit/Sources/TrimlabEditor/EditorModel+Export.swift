import Foundation
import TrimlabMedia
import TrimlabModel

/// What Done's secondary buttons do with the saved file (§4.9).
public enum ExportDoneAction: Sendable { case reveal, quickTime, airDrop }

/// §4.9's export in place: Export freezes the Reel and runs it in the sheet (progress, then Done or Error); Cancel
/// stops it and deletes the partial; Quit cancels it first; an export that reports after its sheet was force-closed
/// is cancelled at once (v1 rulings, §4.12).
extension EditorModel {
  static let cancelledNote = "Export cancelled. Nothing was saved."

  // MARK: start

  /// Export: checks the destination again (the sheet's checks are cached and a file may have appeared since), saves
  /// the sheet's format, cut and quality as the prefs (v1), then runs the Reel as it is now through `ExportRunner`
  /// or, for Quick, `QuickCut` from the keyframe at or before In.
  public func startExport() {
    guard exportSheetOpen, case .editing = exportState else { return }
    recheckSheet()  // preflight again, against the disk as it is now; a refusal shows in the sheet
    guard canExport, let checks = sheetChecks(), let first = checks.form.reel.clips.first else { return }
    let form = checks.form
    let frozen = form.reel
    let dest = form.destination
    let replacing = checks.issue == .exists
    var sources: [UUID: URL] = [:]
    for clip in frozen.clips {
      guard let url = url(for: clip.id) else { return }
      sources[clip.id] = url
    }
    prefs.format = frozen.export.format
    prefs.cut = frozen.export.cut
    prefs.quality = frozen.export.quality
    // The folder trimlab last exported to: the next launch sweeps it for temporaries a crash left (`ExportSweep`).
    prefs.lastFolder = dest.deletingLastPathComponent().standardizedFileURL.path

    let token = UUID()
    exportToken = token
    liveExport = token
    exportFileName = dest.lastPathComponent
    exportSheet.note = nil
    exportSheet.detailsOpen = false
    exportState = .running(progress: 0, eta: nil)
    focusedControl = nil
    registerSheetControls()
    MediaLog.note("editor: export \(frozen.clips.count) clip(s) → \(dest.lastPathComponent)"
      + (replacing ? " (replacing)" : ""))

    let media = self.media
    let quick = frozen.export.cut == .quick
    let knownStart = form.quickStart
    let knownKeyframes = deckKeyframes[first.source]
    let firstURL = sources[first.id]
    pendingExport = Task { [weak self] in
      defer { if self?.liveExport == token { self?.liveExport = nil } }
      var start: RationalTime?
      if quick, let firstURL {
        if let knownStart {
          start = knownStart
        } else {
          let index: KeyframeIndex? = if let knownKeyframes { knownKeyframes } else {
            try? await media.keyframes(first, at: firstURL)
          }
          start = index?.snappedIn(first.inTime) ?? first.inTime
        }
      }
      let stream = media.export(reel: frozen, dest: dest, sources: sources, quick: start, replacing: replacing)
      var finished = false
      do {
        for try await event in stream {
          guard let self, self.exportToken == token else {
            // The sheet that showed this export was force-closed: whatever it reports now stops it. Only this
            // export can be running: no other starts while it's live.
            MediaLog.note("editor: export reported after its sheet closed; cancelling")
            await media.cancelExport()
            return
          }
          if self.exportEvent(event) { finished = true }
        }
        guard !finished else { return }
        self?.exportEnded(CancellationError(), token: token)
      } catch {
        self?.exportEnded(error, token: token)
      }
    }
  }

  /// Applies one event; true once it was the result.
  private func exportEvent(_ event: ExportEvent) -> Bool {
    switch event {
    case .progress(let p, let eta):
      // The bar never goes back (a late event after a software retry began counts from where it was).
      if case .running(let shown, _) = exportState, p < shown { return false }
      exportState = .running(progress: min(max(p, 0), 1), eta: eta)
      return false
    case .done(let result):
      exportAirDropOK = platform.canAirDrop(with: result.url)
      exportState = .done(result)
      focusedControl = nil
      registerSheetControls()
      return true
    }
  }

  /// The stream ended without a result: cancelled (back to the settings, with v1's line) or failed (the Error view).
  private func exportEnded(_ error: any Error, token: UUID) {
    guard exportToken == token, exportRunning else { return }
    focusedControl = nil
    switch error {
    case is CancellationError:
      exportState = .editing
      exportSheet.note = Self.cancelledNote
      recheckSheet()
    case let failed as ExportFailed:
      fail(failed.error, cause: failed.cause)
    case let plain as ExportError:
      fail(plain, cause: nil)
    default:
      fail(.other((error as NSError).localizedDescription), cause: ExportCause(error))
    }
    registerSheetControls()
  }

  private func fail(_ error: ExportError, cause: ExportCause?) {
    let failure = ExportFailure(error, cause: cause, log: media.recentLog(ExportFailure.logLines))
    exportState = .failed(error, details: failure.details)
  }

  // MARK: cancel, close, quit

  /// The progress view's Cancel: stops the writer and deletes the partial; the sheet goes back to its settings once
  /// the stream says so. Only when the media layer really stopped it (not when the file was already being saved, which
  /// then shows Done) and the stream still hasn't ended does the sheet stop reading it.
  @discardableResult
  public func cancelExport() -> Task<Void, Never> {
    guard exportRunning, let token = exportToken else { return Task {} }
    let media = self.media
    return Task { [weak self] in
      let stopped = await media.cancelExport()
      guard stopped, let self, self.exportToken == token, self.exportRunning else { return }
      self.pendingExport?.cancel()
    }
  }

  /// Closes the sheet whatever it shows (the main window closing). A running export is cancelled too (its partial
  /// deleted); anything it still reports is dropped, and cancels it again (v1 ruling).
  public func forceCloseExportSheet() {
    guard exportSheetOpen else { return }
    let wasRunning = exportRunning
    exportToken = nil
    shutExportSheet()
    if wasRunning {
      MediaLog.note("editor: export sheet closed during an export; cancelling")
      let media = self.media
      Task { await media.cancelExport() }
    }
  }

  /// Redoes the sheet's disk checks, visibly: an observed bump, and the Tab order for what they now show.
  func recheckSheet() {
    sheetCache = nil
    sheetRevision += 1
    registerSheetControls()
  }

  /// Quit (§4.9, §8.2): cancels a running export (deleting its partial), cancels the running imports (a remux's
  /// ffmpeg is terminated by its task's cancel handler, and its partial deleted) and saves the Reel, all at once,
  /// waiting at most `quitSaveLimit` (3 s) in all.
  public func prepareForQuit() async {
    commitOpenRename()
    let save = saveNow()
    let imports = Array(importTasks.values)
    for task in imports { task.cancel() }
    var stop: Task<Void, Never>?
    // Any export still being read, the sheet's or one whose sheet was force-closed.
    if liveExport != nil {
      MediaLog.note("editor: quit during an export; cancelling it")
      let media = self.media
      stop = Task { _ = await media.cancelExport() }
    }
    let both = Task {
      await save.value
      await stop?.value
      for task in imports { await task.value }
    }
    await waitAtMost(Self.quitSaveLimit, for: both)
  }

  // MARK: Done

  /// The Done view's facts while it shows.
  public var exportDoneInfo: ExportDone? {
    if case .done(let result) = exportState { ExportDone(result) } else { nil }
  }

  /// The AirDrop button shows only when AirDrop can send the saved file (asked as Done showed).
  public var exportCanAirDrop: Bool { exportAirDropOK }

  public func exportDone(_ action: ExportDoneAction) {
    guard case .done(let result) = exportState else { return }
    switch action {
    case .reveal: platform.reveal(result.url)
    case .quickTime: platform.openInQuickTime(result.url)
    case .airDrop: if exportAirDropOK { platform.airDrop(result.url) }
    }
  }

  /// New Reel from Done: saves and closes this Reel, and shows the empty state.
  public func newReelFromDone() {
    guard case .done = exportState else { return }
    newReel()
  }

  // MARK: Error

  public var exportErrorSentence: String? {
    if case .failed(let error, _) = exportState { error.sentence } else { nil }
  }

  public var exportErrorDetails: String? {
    if case .failed(_, let details) = exportState { details } else { nil }
  }

  public func toggleExportDetails() {
    guard case .failed = exportState else { return }
    exportSheet.detailsOpen.toggle()
    registerSheetControls()
  }

  public func copyExportDetails() {
    guard let details = exportErrorDetails else { return }
    platform.copy(details)
  }

  /// Back to settings: the sheet's rows again, checked afresh.
  public func exportBackToSettings() {
    guard case .failed = exportState else { return }
    exportState = .editing
    exportSheet.detailsOpen = false
    focusedControl = nil
    recheckSheet()
  }

  // MARK: progress lines

  /// "about 1 min left" (v1's wording): seconds under a minute, "almost done" under half a second, and "Working out
  /// the time left" until a rate is known.
  public var exportProgressLine: String? {
    guard case .running(_, let eta) = exportState else { return nil }
    return Self.etaLine(eta)
  }

  /// "50%", rounded down.
  public var exportPercentLine: String? {
    guard case .running(let p, _) = exportState else { return nil }
    return "\(Int((p * 100).rounded(.down)))%"
  }

  static func etaLine(_ eta: Double?) -> String {
    let nbsp = ExportForm.nbsp
    guard let eta, eta.isFinite else { return "Working out the time left" }
    if eta < 0.5 { return "almost done" }
    if eta < 60 { return "about \(Int(eta.rounded(.up)))\(nbsp)s left" }
    return "about \(Int((eta / 60).rounded()))\(nbsp)min left"
  }
}
