import AVFoundation
import Foundation
import ImageIO
import Observation
import SwiftUI
import Synchronization
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 36: the export runs in the sheet (§4.9): progress, cancel, quit, Done and Error, and the late-result rule.
@MainActor @Suite struct ExportFlowTests {
  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  /// Two clips in /shoot, the sheet open.
  private func opened() async throws -> Harness {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.requestExport()
    #expect(h.model.exportSheetOpen)
    #expect(h.model.canExport)
    return h
  }

  /// Opens the sheet, presses Export and waits for the stream to be asked for.
  private func running() async throws -> Harness {
    let h = try await opened()
    h.model.startExport()
    #expect(await h.media.waitForExports(1))
    #expect(h.model.exportRunning)
    return h
  }

  /// Waits (yielding, then 1 ms naps) until `condition` holds; false after 5 s, so a bug fails rather than hangs.
  private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      if ContinuousClock.now > deadline { return false }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(1))
    }
    return true
  }

  private func result(_ url: URL, bytes: Int64 = 84_100_000, software: Bool = false) -> ExportResult {
    ExportResult(url: url, bytes: bytes, firstFrame: nil, usedSoftwareEncoder: software)
  }

  private func isEditing(_ m: EditorModel) -> Bool { if case .editing = m.exportState { true } else { false } }
  private func isIdle(_ m: EditorModel) -> Bool { if case .idle = m.exportState { true } else { false } }
  private func isDone(_ m: EditorModel) -> Bool { if case .done = m.exportState { true } else { false } }

  // MARK: the brief's nine

  @Test func progressFlowsToDone() async throws {
    let h = try await opened()
    let dest = try #require(h.model.exportForm?.destination)
    let frozen = try #require(h.model.reel)
    h.model.startExport()
    #expect(await h.media.waitForExports(1))
    let request = try #require(h.media.exports.first)
    #expect(request.dest == dest)
    #expect(request.reel == frozen)
    #expect(request.quick == nil && !request.replacing)
    #expect(Set(request.sources.keys) == Set(frozen.clips.map(\.id)))
    #expect(h.model.exportFileName == dest.lastPathComponent)

    h.media.send(.progress(0.5, eta: 30))
    #expect(await eventually {
      if case .running(let p, let eta) = h.model.exportState { p == 0.5 && eta == 30 } else { false }
    })
    #expect(h.model.exportProgressLine == "about 30\u{00A0}s left")
    #expect(h.model.exportPercentLine == "50%")

    h.media.send(.done(result(dest)))
    h.media.finishExport()
    #expect(await eventually { isDone(h.model) })
    #expect(h.model.exportSheetOpen)
    #expect(h.model.exportDoneInfo?.fileName == dest.lastPathComponent)
  }

  @Test func cancelReturnsToSheet() async throws {
    let h = try await running()
    h.media.send(.progress(0.2, eta: nil))
    await h.model.cancelExport().value
    #expect(h.media.cancelCalls == 1)
    #expect(await eventually { isEditing(h.model) })
    #expect(h.model.exportSheetOpen)
    #expect(h.model.exportSheet.note == "Export cancelled. Nothing was saved.")
    #expect(h.model.canExport)
  }

  @Test func editsIgnoredWhileRunning() async throws {
    let h = try await running()
    let before = h.model.reel
    let steps = h.model.history.undoCount
    let id = try #require(before?.clips.first?.id)
    #expect(!h.model.perform(.delete([id]), coalesce: nil))
    #expect(!h.model.perform(.setFraming([id], .fit), coalesce: nil))
    h.model.undo()
    #expect(h.model.reel == before)
    #expect(h.model.history.undoCount == steps)
  }

  @Test func lateResultAfterCloseIsCancelled() async throws {
    let h = try await running()
    let dest = try #require(h.media.exports.first?.dest)
    h.media.neverFinishOnCancel()  // a teardown that hasn't ended yet
    h.model.forceCloseExportSheet()
    #expect(!h.model.exportSheetOpen)
    #expect(isIdle(h.model))
    #expect(await eventually { h.media.cancelCalls == 1 })  // the close cancels it (review I1)
    h.media.send(.progress(0.3, eta: 10))
    #expect(await eventually { h.media.cancelCalls == 2 })  // and what it reports late cancels it again
    h.media.send(.done(result(dest)))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(isIdle(h.model))
    #expect(!h.model.exportSheetOpen)
  }

  @Test func newReelFromDoneClearsAndSaves() async throws {
    let h = try await running()
    let dest = try #require(h.media.exports.first?.dest)
    h.media.send(.done(result(dest)))
    h.media.finishExport()
    #expect(await eventually { isDone(h.model) })
    let writes = h.store.writes.withLock { $0.count }
    h.model.newReelFromDone()
    await h.model.pendingSave?.value
    #expect(h.store.writes.withLock { $0.count } == writes + 1)
    #expect(h.model.reel == nil)
    #expect(!h.model.exportSheetOpen)
    #expect(isIdle(h.model))
  }

  @Test func folderPlainName() {
    let docs = URL.homeDirectory.appending(path: "Documents/Spa Tour.mp4")
    #expect(ExportDone(result(docs)).whereLine == "84.1\u{00A0}MB, in Documents")
    let tour = URL(filePath: "/Volumes/Card/Spa Tour/Spa Tour.mp4")
    #expect(ExportDone(result(tour, bytes: 2_340_000_000)).whereLine == "2.3\u{00A0}GB, in Spa Tour")
    let tiny = URL(filePath: "/shoot/a.mp4")
    #expect(ExportDone(result(tiny, bytes: 4_200)).whereLine == "4\u{00A0}KB, in shoot")
    #expect(!ExportDone(result(docs)).whereLine.contains("~"))
  }

  @Test func softwareFallbackLine() {
    let url = URL(filePath: "/shoot/a.mp4")
    #expect(ExportDone(result(url, software: true)).fallbackLine == "Saved with the slower software encoder.")
    #expect(ExportDone(result(url)).fallbackLine == nil)
  }

  @Test func errorDetailsHasLast30Lines() async throws {
    let h = try await running()
    h.media.scriptLog((1...40).map { "log \($0)" })
    let cause = ExportCause(domain: AVFoundationErrorDomain, code: -11800,
                            description: "The operation could not be completed")
    h.media.finishExport(throwing: ExportFailed(error: .diskFull, cause: cause))
    #expect(await eventually { if case .failed = h.model.exportState { true } else { false } })
    guard case .failed(let error, let details) = h.model.exportState else { return }
    #expect(error == .diskFull)
    #expect(h.model.exportErrorSentence == "The disk is full.")
    let lines = details.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.contains("Domain: AVFoundationErrorDomain"))
    #expect(lines.contains("Code: -11800"))
    #expect(lines.contains("Description: The operation could not be completed"))
    #expect(Array(lines.suffix(30)) == (11...40).map { "log \($0)" })
    #expect(!lines.contains("log 10"))

    h.model.copyExportDetails()
    #expect(h.platform.state.withLock { $0.copied } == [details])
    h.model.exportBackToSettings()
    #expect(isEditing(h.model))
    #expect(h.model.exportSheetOpen)
  }

  @Test func quitCancelsWithin3s() async throws {
    let h = try await running()
    h.media.neverFinishOnCancel()
    let start = ContinuousClock.now
    await h.model.prepareForQuit()
    // §4.9's 3 s under TRIMLAB_TIMING=1 (see `Timing`); a parallel run loads the main actor, so looser otherwise.
    let limit: Duration = Timing.strict ? .seconds(3) : .seconds(8)
    #expect(ContinuousClock.now - start < limit)
    #expect(h.media.cancelCalls == 1)
  }

  // MARK: carries

  /// Carry 1: Export checks the disk again; a file that appeared since the sheet's last check asks Replace first.
  @Test func startExportRechecksDisk() async throws {
    let h = try await opened()
    let dest = try #require(h.model.exportForm?.destination)
    #expect(h.model.exportIssue == nil)
    h.store.add(dest.path)  // behind the sheet's back: its cached check still says nothing's there
    h.model.startExport()
    #expect(h.media.exports.isEmpty)
    #expect(h.model.exportAsksReplace)
    #expect(isEditing(h.model))

    h.model.exportReplace()
    h.model.startExport()
    #expect(await h.media.waitForExports(1))
    #expect(h.media.exports.first?.replacing == true)
  }

  /// Carry 5: the sheet's format, cut and quality become the prefs once an export starts (v1).
  @Test func exportSavesPrefs() async throws {
    let h = try await opened()
    h.model.setExportFormat(.original)
    h.model.setExportQuality(.standard)
    #expect(h.model.prefs.format == .reel)
    h.model.startExport()
    #expect(h.model.prefs.format == .original)
    #expect(h.model.prefs.quality == .standard)
    #expect(h.model.prefs.cut == .exact)
    #expect(h.model.prefs.removeAudioDefault == false)
  }

  /// The folder an export goes to becomes `lastFolder`, which the next launch sweeps (`ExportSweep`).
  @Test func exportRemembersItsFolder() async throws {
    let h = try await opened()
    #expect(h.model.prefs.lastFolder == nil)
    h.model.startExport()
    let dest = try #require(await h.media.waitForExports(1) ? h.media.exports.first?.dest : nil)
    #expect(h.model.prefs.lastFolder == dest.deletingLastPathComponent().standardizedFileURL.path)
  }

  /// Done's buttons act on the saved file; AirDrop only where the Mac has it.
  @Test func doneActionsUseSavedFile() async throws {
    let h = try await running()
    let dest = try #require(h.media.exports.first?.dest)
    h.media.send(.done(result(dest)))
    h.media.finishExport()
    #expect(await eventually { isDone(h.model) })
    h.model.exportDone(.reveal)
    h.model.exportDone(.quickTime)
    h.model.exportDone(.airDrop)
    let s = h.platform.state.withLock { $0 }
    #expect(s.revealed == [dest] && s.openedInQuickTime == [dest] && s.airDropped == [dest])
    #expect(h.model.exportCanAirDrop)
    h.model.closeExportSheet()  // Esc or the scrim: back to the Reel
    #expect(!h.model.exportSheetOpen)
    #expect(h.model.reel != nil)
  }

  /// Quick passes the keyframe the cut starts at.
  @Test func quickPassesSnappedIn() async throws {
    let h = Harness(prefs: Prefs(format: .original))
    await h.importAll(["a.mov"])
    h.media.answerKeyframes([.zero, RationalTime(2, 1)])
    let id = try #require(h.model.reel?.clips.first?.id)
    #expect(h.model.perform(.setIn(id, RationalTime(3, 1)), coalesce: nil))
    h.model.requestExport()
    h.model.setExportCut(.quick)
    #expect(h.model.reel?.export.cut == .quick)
    h.model.startExport()
    #expect(await h.media.waitForExports(1))
    #expect(h.media.exports.first?.quick == RationalTime(2, 1))
  }

  // MARK: Phase 6 review fixes

  /// I1: closing the window cancels a running export, and Quit afterwards still cancels it while it's live.
  @Test func closeThenQuitCancels() async throws {
    let h = try await running()
    h.media.neverFinishOnCancel()
    h.model.forceCloseExportSheet()
    #expect(await eventually { h.media.cancelCalls == 1 })
    #expect(h.model.liveExport != nil)
    await h.model.prepareForQuit()
    #expect(h.media.cancelCalls == 2)
  }

  /// I1: nothing new starts while a force-closed export is still live, so its late report can't hit the next one.
  @Test func lateReportDoesNotHitNextExport() async throws {
    let h = try await running()
    h.media.neverFinishOnCancel()
    h.model.forceCloseExportSheet()
    #expect(await eventually { h.media.cancelCalls == 1 })
    h.model.requestExport()
    #expect(h.model.exportSheetOpen && !h.model.canExport)
    h.model.startExport()
    #expect(h.media.exports.count == 1)

    h.media.finishExport(throwing: CancellationError())  // the old export ends at last
    #expect(await eventually { h.model.liveExport == nil && h.model.canExport })
    h.model.startExport()
    #expect(await h.media.waitForExports(2))
    h.media.send(.progress(0.3, eta: 5))
    #expect(await eventually { h.model.exportPercentLine == "30%" })
    #expect(h.media.cancelCalls == 1)
    #expect(h.model.exportRunning)
  }

  /// I2: Export's recheck shows what it found: the sheet's observed state changes and Replace / Keep both join Tab.
  @Test func recheckShowsInSheet() async throws {
    let h = try await opened()
    let dest = try #require(h.model.exportForm?.destination)
    #expect(!h.model.exportAsksReplace)
    let changed = Mutex(false)
    withObservationTracking { _ = h.model.exportAsksReplace } onChange: { changed.withLock { $0 = true } }
    h.store.add(dest.path)
    h.model.startExport()
    #expect(changed.withLock { $0 }, "the view isn't told to redraw")
    #expect(h.model.exportAsksReplace)
    #expect(h.model.sheetControlIDs.contains("export-replace"))
    #expect(h.model.modals.contains(.exportSheet))
  }

  /// M3: a cancel that came too late (the file was already being saved) leaves the export to finish and show Done.
  @Test func lateCancelStillShowsDone() async throws {
    let h = try await running()
    let dest = try #require(h.media.exports.first?.dest)
    h.media.neverFinishOnCancel()
    h.media.answerCancel(false)
    await h.model.cancelExport().value
    #expect(h.model.exportRunning)
    h.media.send(.done(result(dest)))
    h.media.finishExport()
    #expect(await eventually { isDone(h.model) })
  }

  /// M4: Replace onto a file that went meanwhile just moves the new one there; a failed swap keeps the new file under a
  /// Keep-both name and says the old one is still there.
  @Test func swapInKeepsTheNewFile() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "swap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dest = dir.appending(path: "IMG_4821.mp4")
    let standIn = dir.appending(path: "IMG_4821.abcd1234.replacing.mp4")
    try Data("new".utf8).write(to: standIn)
    let moved = try LiveMediaServices.swapIn(result(standIn, bytes: 3), over: dest)
    #expect(moved.url == dest)
    #expect(try String(contentsOf: dest, encoding: .utf8) == "new")

    try Data("newer".utf8).write(to: standIn)
    struct Refused: Error {}
    do {
      _ = try LiveMediaServices.swapIn(result(standIn), over: dest, replace: { _, _ in throw Refused() })
      Issue.record("the swap didn't fail")
    } catch let failed as ExportFailed {
      #expect(failed.error == .notReplaced(name: "IMG_4821.mp4", oldKept: true, keptAs: "IMG_4821 2.mp4"))
      #expect(failed.error.sentence == "IMG_4821.mp4 couldn't be replaced. The old file is still there.")
    }
    #expect(try String(contentsOf: dest, encoding: .utf8) == "new")
    #expect(try String(contentsOf: dir.appending(path: "IMG_4821 2.mp4"), encoding: .utf8) == "newer")
    #expect(!FileManager.default.fileExists(atPath: standIn.path))
  }

  /// M6: trimlab's own errors read as their sentence in Details, never as Swift's `other("…")`.
  @Test func ownErrorDetailsReadPlainly() {
    let stalled = ExportFailure(.stalled(seconds: 20), log: [])
    #expect(stalled.details.contains("Description: The export made no progress for 20 seconds, so it was stopped."))
    let other = ExportFailure(.other("The Reel is empty."), log: [])
    #expect(!other.details.contains("other("))
    #expect(other.details.hasPrefix("The Reel is empty.\n"))
  }

  /// M5: AirDrop is asked about the saved file itself, once Done shows.
  @Test func airDropAskedForSavedFile() async throws {
    let h = try await running()
    #expect(!h.model.exportCanAirDrop)
    let dest = try #require(h.media.exports.first?.dest)
    h.media.send(.done(result(dest)))
    #expect(await eventually { isDone(h.model) })
    #expect(h.model.exportCanAirDrop)
    #expect(h.model.sheetControlIDs.contains("export-airdrop"))
  }

  /// Carry 6: the system error under a failure keeps its domain and code, and its underlying errors' too.
  @Test func causeKeepsDomainAndCode() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSLocalizedDescriptionKey: "No space left"])
    let av = NSError(domain: AVFoundationErrorDomain, code: -11800,
                     userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed",
                                NSUnderlyingErrorKey: posix])
    let cause = ExportCause(av)
    #expect(cause?.domain == AVFoundationErrorDomain && cause?.code == -11800)
    #expect(cause?.description == "The operation could not be completed (NSPOSIXErrorDomain 28: No space left)")
    #expect(ExportCause(ExportError.diskFull) == nil)
    #expect(ExportCause(CancellationError()) == nil)
  }

  /// The progress, Done and Error panes draw at the sheet's width (`TRIMLAB_PANE_PNG_DIR` keeps them as PNGs).
  @Test func panesRender() async throws {
    let h = try await running()
    let dest = try #require(h.media.exports.first?.dest)
    func render(_ name: String) throws {
      let renderer = ImageRenderer(content: ExportSheetView(model: h.model).fixedSize(horizontal: false, vertical: true)
        .background(Tokens.bg0))
      renderer.scale = 2
      let image = try #require(renderer.cgImage, "\(name) didn't render")
      #expect(image.width == 2 * 560, "\(name)")
      if let dir = ProcessInfo.processInfo.environment["TRIMLAB_PANE_PNG_DIR"],
         let out = CGImageDestinationCreateWithURL(URL(filePath: "\(dir)/\(name).png") as CFURL, "public.png" as CFString,
                                                  1, nil) {
        CGImageDestinationAddImage(out, image, nil)
        CGImageDestinationFinalize(out)
      }
    }
    h.media.send(.progress(0.42, eta: 75))
    #expect(await eventually { h.model.exportPercentLine == "42%" })
    try render("progress")
    h.media.send(.done(result(dest, software: true)))
    h.media.finishExport()
    #expect(await eventually { isDone(h.model) })
    try render("done")

    let f = try await running()
    f.media.scriptLog((1...40).map { "export: line \($0)" })
    f.media.finishExport(throwing: ExportFailed(error: .diskFull, cause: nil))
    #expect(await eventually { if case .failed = f.model.exportState { true } else { false } })
    f.model.toggleExportDetails()
    let renderer = ImageRenderer(content: ExportSheetView(model: f.model).fixedSize(horizontal: false, vertical: true)
      .background(Tokens.bg0))
    #expect(renderer.cgImage != nil)
    if let dir = ProcessInfo.processInfo.environment["TRIMLAB_PANE_PNG_DIR"], let image = renderer.cgImage,
       let out = CGImageDestinationCreateWithURL(URL(filePath: "\(dir)/error.png") as CFURL, "public.png" as CFString,
                                                1, nil) {
      CGImageDestinationAddImage(out, image, nil)
      CGImageDestinationFinalize(out)
    }
  }
}
