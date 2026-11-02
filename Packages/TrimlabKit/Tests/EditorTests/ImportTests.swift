import Foundation
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 26: the import pipeline (§4.1).
@MainActor @Suite struct ImportTests {
  @Test func importOrderIsCaptureThenName() async {
    let h = Harness()
    h.media.date("late.mov", Date(timeIntervalSince1970: 300))
    h.media.date("early.mov", Date(timeIntervalSince1970: 100))
    await h.importAll(["IMG_10.mov", "late.mov", "IMG_2.mov", "early.mov"])
    #expect(h.names == ["early.mov", "late.mov", "IMG_2.mov", "IMG_10.mov"])
    #expect(h.model.reel?.name == "shoot")
  }

  @Test func folderTopLevelOnly() async {
    let h = Harness()
    for p in ["/shoot/b.mov", "/shoot/a.mov", "/shoot/.DS_Store", "/shoot/sub/deep.mov"] { h.store.add(p) }
    await h.model.importURLs([URL(filePath: "/shoot", directoryHint: .isDirectory)], at: nil).value
    #expect(h.names == ["a.mov", "b.mov"])
    #expect(h.model.notes.isEmpty)
  }

  @Test func skippedFilesNote() async {
    let h = Harness()
    await h.importAll(["a.mov", "notes.txt", "still.jpg"])
    #expect(h.names == ["a.mov"])
    #expect(h.noteTexts == ["Skipped 2 files trimlab can't open."])
    #expect(h.model.notes.first?.kind == .quiet)
  }

  @Test func insertAtCaret() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov", "c.mov"])
    await h.importAll(["x.mov"], at: 1)
    #expect(h.names == ["a.mov", "x.mov", "b.mov", "c.mov"])
  }

  @Test func appendWithoutCaret() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await h.importAll(["x.mov"])
    #expect(h.names == ["a.mov", "b.mov", "x.mov"])
  }

  @Test func batchIsOneUndoStep() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    await h.importAll(["b.mov", "c.mov", "d.mov"])
    h.model.undo()
    #expect(h.names == ["a.mov"])
    h.model.redo()
    #expect(h.names == ["a.mov", "b.mov", "c.mov", "d.mov"])
    #expect(h.model.reel?.clips.allSatisfy { $0.facts.duration == RationalTime(10, 1) } == true)
  }

  /// Review Focus 1.
  @Test func importBatchWithOneCorruptFile() async {
    let h = Harness()
    let names = (1...40).map { String(format: "clip%02d.mov", $0) }
    h.media.script("clip07.mov", .error(ProbeError.unplayable))
    await h.importAll(names + ["still.jpg"])
    #expect(h.names == names.filter { $0 != "clip07.mov" })
    #expect(h.noteTexts.contains("Can't open clip07.mov. trimlab can't play this kind of file."))
    #expect(h.noteTexts.contains("Skipped 1 file trimlab can't open."))
    let ids = h.model.reel?.clips.map(\.id) ?? []
    #expect(ids.allSatisfy { h.model.loading[$0] == .ready })
    #expect(!h.model.loading.values.contains(.probing))
    h.model.undo()
    #expect(h.model.reel?.clips.isEmpty == true)
  }

  /// Review Focus 3.
  @Test func tinyClipImports() async throws {
    let h = Harness()
    h.media.script("tiny.mp4", .facts(StubMedia.facts(RationalTime(12, 30), fps: RationalTime(1, 30))))
    await h.importAll(["tiny.mp4"])
    let clip = try #require(h.model.reel?.clips.first)
    #expect(clip.inTime == .zero)
    #expect(clip.outTime == RationalTime(2, 5))
    #expect(h.model.plan?.total == RationalTime(2, 5))
  }

  @Test func refusedDuringExport() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    let before = h.model.reel
    h.store.add("/shoot/other.trimlab", ProjectCodec.encode(Reel.empty(name: "Other")))
    h.model.exportState = .running(progress: 0.4, eta: 20)
    await h.importAll(["b.mov"])
    h.model.newReel()
    h.model.open(project: URL(filePath: "/shoot/other.trimlab"))
    #expect(h.model.reel == before)
    #expect(h.noteTexts == Array(repeating: "Finish or cancel the export first.", count: 3))
  }

  @Test func probeConcurrencyFour() async {
    let h = Harness()
    h.media.state.withLock { $0.rendezvous = 4 }
    await h.importAll((1...12).map { "c\($0).mov" })
    #expect(h.media.maxInFlight == 4)
    #expect(h.media.probesStarted == 12)
  }

  @Test func needsFFmpegOpensCard() async {
    let h = Harness()
    h.media.state.withLock { $0.ffmpeg = false }
    await h.importAll(["show.mkv"])
    #expect(h.model.modals.top == .ffmpegCard)
    #expect(h.names.isEmpty)
    #expect(h.media.probesStarted == 0)
  }

  /// The importer can still report `needsFFmpeg` (ffmpeg removed mid-session): the tile goes, the card opens.
  @Test func probeNeedsFFmpegOpensCard() async {
    let h = Harness()
    h.media.script("show.avi", .error(ImportError.needsFFmpeg))
    await h.importAll(["a.mov", "show.avi"])
    #expect(h.model.modals.top == .ffmpegCard)
    #expect(h.names == ["a.mov"])
    #expect(h.model.notes.isEmpty)
  }

  @Test func importErrorSentences() async {
    let h = Harness()
    h.media.script("a.mkv", .error(ImportError.formatWontPlay))
    h.media.script("b.avi", .error(ImportError.remuxFailed("tail")))
    await h.importAll(["a.mkv", "b.avi"])
    #expect(h.names.isEmpty)
    #expect(Set(h.noteTexts) == [ImportError.formatWontPlay.sentence(ext: "mkv"),
                                 ImportError.remuxFailed("").sentence(ext: "avi")])
    #expect(h.model.notes.allSatisfy { $0.kind == .error })
  }

  @Test func remuxTileSaysPreparing() async throws {
    let h = Harness()
    h.media.hold()
    let task = h.model.importURLs([Harness.url("show.mkv")], at: nil)
    #expect(await h.media.waitForProbes(1))
    let id = try #require(h.model.reel?.clips.first?.id)
    #expect(h.model.loading[id] == .preparing)
    h.media.release()
    await task.value
    #expect(h.model.loading[id] == .ready)
  }

  @Test func sameFileTwiceIsTwoClips() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    await h.importAll(["a.mov"])
    let ids = h.model.reel?.clips.map(\.id) ?? []
    #expect(ids.count == 2)
    #expect(Set(ids).count == 2)
  }

  /// Phase 2 review carry: a probe that lands after its tile was undone away is dropped, and never throws.
  @Test func probeAfterUndoIsDropped() async throws {
    let h = Harness()
    h.media.hold()
    let task = h.model.importURLs([Harness.url("a.mov")], at: nil)
    #expect(await h.media.waitForProbes(1))
    h.model.undo()
    #expect(h.model.reel?.clips.isEmpty == true)
    h.media.release()
    await task.value
    #expect(h.model.reel?.clips.isEmpty == true)
    #expect(h.model.notes.isEmpty)
    // Redo brings the tile back with the facts that landed while it was gone.
    h.model.redo()
    let clip = try #require(h.model.reel?.clips.first)
    #expect(clip.facts == StubMedia.facts())
    #expect(clip.outTime == RationalTime(10, 1))
    #expect(h.model.loading[clip.id] == .ready)
  }

  /// Phase 2 review ruling: a probe whose times the plan can't hold exactly is refused like an unplayable file.
  @Test func unsupportedTimingIsUnplayable() async {
    let h = Harness()
    h.media.script("a.mov", .facts(StubMedia.facts(RationalTime(30721, 15360), fps: RationalTime(1, 24))))
    h.media.script("b.mov", .facts(StubMedia.facts(RationalTime(2_000_001, 1_000_000), fps: RationalTime(1, 25))))
    h.media.script("c.mov", .facts(StubMedia.facts(RationalTime(5995, 2997), fps: RationalTime(1, 25))))
    // Model's Builders.timescaleMix: b with c can't be held; a goes with either. Whatever order the probes land
    // in, exactly one is refused.
    await h.importAll(["a.mov", "b.mov", "c.mov"])
    #expect(h.names.count == 2)
    #expect(h.noteTexts.count == 1)
    #expect(h.noteTexts.first?.hasSuffix("trimlab can't play this kind of file.") == true)
  }

  /// Review I1: without a project file there is no folder to be relative to.
  @Test func relativePathNilWithoutProject() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    await h.importAll(["b.mov"], in: "/shoot/day2")
    #expect(h.model.reel?.clips.map(\.source.relativePath) == [nil, nil])
  }

  @Test func relativePathAgainstOpenProject() async {
    let h = Harness()
    h.store.add("/shoot/P.trimlab", ProjectCodec.encode(Reel.empty(name: "P")))
    h.model.open(project: URL(filePath: "/shoot/P.trimlab"))
    await h.importAll(["b.mov"], in: "/shoot/day2")
    await h.importAll(["c.mov"], in: "/elsewhere")
    #expect(h.model.reel?.clips.map(\.source.relativePath) == ["day2/b.mov", nil])
  }

  /// For Task 31: relative paths rebuilt against the folder the project file is written to.
  @Test func rebasingRelativePaths() async throws {
    let h = Harness()
    await h.importAll(["a.mov"], in: "/shoot")
    await h.importAll(["b.mov"], in: "/shoot/day2")
    await h.importAll(["c.mov"], in: "/elsewhere")
    await h.importAll(["d.mov"], in: "/shootings")
    let reel = try #require(h.model.reel).rebasingRelativePaths(to: URL(filePath: "/shoot", directoryHint: .isDirectory))
    #expect(reel.clips.map(\.source.relativePath) == ["a.mov", "day2/b.mov", nil, nil])
  }

  /// Review M6: an empty folder isn't a file trimlab can't open.
  @Test func emptyFolderIsNotSkipped() async {
    let h = Harness()
    h.store.addFolder("/empty")
    h.store.addFolder("/shoot/emptysub")
    h.store.add("/shoot/a.mov")
    await h.model.importURLs([URL(filePath: "/empty"), URL(filePath: "/shoot")], at: nil).value
    #expect(h.names == ["a.mov"])
    #expect(h.model.notes.isEmpty)
  }

  /// Review M4: a refused drop shows the refusal and nothing else (no skipped note, no ffmpeg card).
  @Test func refusalComesFirst() async {
    let h = Harness()
    h.media.state.withLock { $0.ffmpeg = false }
    h.model.exportState = .running(progress: 0.1, eta: nil)
    await h.importAll(["show.mkv", "notes.txt"])
    #expect(h.noteTexts == ["Finish or cancel the export first."])
    #expect(h.model.modals.top == nil)
    #expect(h.model.reel == nil)
  }

  /// Review M3: New Reel cancels a running import; its late failures post nothing.
  @Test func newReelCancelsImport() async {
    let h = Harness()
    h.media.script("a.mov", .error(ProbeError.unplayable))
    h.media.hold()
    let task = h.model.importURLs([Harness.url("a.mov")], at: nil)
    #expect(await h.media.waitForProbes(1))
    h.model.newReel()
    h.media.release()
    await task.value
    #expect(h.model.reel == nil)
    #expect(h.model.notes.isEmpty)
    #expect(h.model.loading.isEmpty)
  }

  /// Round 2 M3: a cancelled batch starts no more probes.
  @Test func cancelledBatchStopsProbing() async {
    let h = Harness()
    h.media.state.withLock { $0.holdAfter = 2 }  // two answer, the next four wait
    let task = h.model.importURLs((1...40).map { Harness.url(String(format: "c%02d.mov", $0)) }, at: nil)
    #expect(await h.media.waitForFinished(2))
    #expect(await h.media.waitForProbes(6))
    h.model.newReel()
    h.media.release()
    await task.value
    #expect(h.media.probesStarted == 6)  // 4 in flight + the 2 that answered; nothing new after the cancel
    #expect(h.model.reel == nil)
    #expect(h.model.notes.isEmpty)
  }

  /// Round 2 B1: a drop of a project plus movies opens the project and appends the movies to it.
  @Test func projectAndMoviesDrop() async throws {
    let h = Harness()
    var saved = Reel.empty(name: "Saved")
    saved.clips = [ReelClip.make(source: SourceRef(relativePath: "a.mov", absolutePath: "/shoot/a.mov", size: 1_000,
                                                   modified: Date(timeIntervalSince1970: 1_000)),
                                 facts: StubMedia.facts(), framing: .fill)]
    h.store.add("/shoot/Saved.trimlab", ProjectCodec.encode(saved))
    await h.importAll(["Saved.trimlab", "x.mov"])
    #expect(h.model.reel?.id == saved.id)
    #expect(h.names == ["a.mov", "x.mov"])
    #expect(h.model.loadingClipIDs.isEmpty)
    #expect(h.model.reel?.clips.last?.source.relativePath == "x.mov")
  }

  /// Round 2 B2: rebasing normalises paths as `Prober.sourceRef` does, so /var and /private/var agree.
  @Test func rebasingResolvesSymlinks() throws {
    let tmp = URL(filePath: "/var/tmp/trimlab-rebase-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let file = URL(filePath: "/private" + tmp.path).appending(path: "a.mov")
    try Data().write(to: file)
    var reel = Reel.empty(name: "R")
    reel.clips = [ReelClip.make(source: SourceRef(relativePath: nil, absolutePath: file.path, size: 0,
                                                  modified: Date(timeIntervalSince1970: 0)),
                                facts: StubMedia.facts(), framing: .fill)]
    #expect(reel.rebasingRelativePaths(to: tmp).clips[0].source.relativePath == "a.mov")
    reel.clips[0].source.absolutePath = tmp.appending(path: "a.mov").path
    let privateFolder = URL(filePath: "/private" + tmp.path, directoryHint: .isDirectory)
    #expect(reel.rebasingRelativePaths(to: privateFolder).clips[0].source.relativePath == "a.mov")
  }

  /// Review M7: a second drop while the first batch is still probing.
  @Test func secondImportWhileProbing() async {
    let h = Harness()
    h.media.hold()
    let first = h.model.importURLs([Harness.url("a.mov"), Harness.url("b.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    let second = h.model.importURLs([Harness.url("c.mov")], at: nil)
    #expect(await h.media.waitForProbes(3))
    #expect(h.model.loadingClipIDs.count == 3)
    h.media.release()
    await first.value
    await second.value
    #expect(h.names == ["a.mov", "b.mov", "c.mov"])
    #expect(h.model.loadingClipIDs.isEmpty)
    h.model.undo()
    #expect(h.names == ["a.mov", "b.mov"])
    h.model.undo()
    #expect(h.names.isEmpty)
  }

  /// Review M7: a probe fails while its tile is undone away; redo doesn't bring the broken tile back.
  @Test func failureWhileUndoneThenRedo() async {
    let h = Harness()
    h.media.script("bad.mov", .error(ProbeError.unplayable))
    h.media.hold()
    let task = h.model.importURLs([Harness.url("a.mov"), Harness.url("bad.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    h.model.undo()
    h.media.release()
    await task.value
    h.model.redo()
    #expect(h.names == ["a.mov"])
    #expect(h.noteTexts == ["Can't open bad.mov. trimlab can't play this kind of file."])
    #expect(h.model.loadingClipIDs.isEmpty)
    #expect(Set(h.model.loading.keys) == Set(h.model.reel?.clips.map(\.id) ?? []))
  }

  /// Review M1: facts that landed while undone away but can't join the Reel on redo are refused, not `.ready`.
  @Test func reconcileRefusesUnsaneFacts() async throws {
    let h = Harness()
    h.media.script("b.mov", .facts(StubMedia.facts(RationalTime(2_000_001, 1_000_000), fps: RationalTime(1, 25))))
    h.media.script("c.mov", .facts(StubMedia.facts(RationalTime(5995, 2997), fps: RationalTime(1, 25))))
    h.media.hold()
    let task = h.model.importURLs([Harness.url("b.mov"), Harness.url("c.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    h.model.undo()
    h.media.release()
    await task.value
    #expect(h.model.notes.isEmpty)
    h.model.redo()
    #expect(h.names.count == 1)
    #expect(h.noteTexts.count == 1)
    #expect(h.noteTexts.first?.hasSuffix("trimlab can't play this kind of file.") == true)
    let kept = try #require(h.model.reel?.clips.first?.id)
    #expect(h.model.loading.keys.sorted() == [kept])
  }

  /// Review M2: every clip's file is known by id; a split's second half shares it.
  @Test func resolvedURLs() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    let id = try #require(h.model.reel?.clips.first?.id)
    #expect(h.model.url(for: id) == Harness.url("a.mov"))
    #expect(h.model.perform(.split(id, atSource: RationalTime(5, 1)), coalesce: nil))
    let b = try #require(h.model.reel?.clips.last?.id)
    #expect(h.model.url(for: b) == Harness.url("a.mov"))
  }

  @Test func newReelFollowsPrefs() async throws {
    let h = Harness(prefs: Prefs(format: .original, quality: .standard, defaultFraming: .fit,
                                 removeAudioDefault: true))
    await h.importAll(["a.mov"])
    let reel = try #require(h.model.reel)
    #expect(reel.export.format == .original)
    #expect(reel.export.quality == .standard)
    #expect(reel.export.removeAudio)
    #expect(reel.clips.first?.framing == .fit)
  }

  @Test func projectInDropOpensIt() async {
    let h = Harness()
    var saved = Reel.empty(name: "Saved")
    saved.clips = [ReelClip.make(source: SourceRef(relativePath: "a.mov", absolutePath: "/shoot/a.mov", size: 1_000,
                                                   modified: Date(timeIntervalSince1970: 1_000)),
                                 facts: StubMedia.facts(), framing: .fill)]
    h.store.add("/shoot/Saved.trimlab", ProjectCodec.encode(saved))
    await h.importAll(["Saved.trimlab"])
    #expect(h.model.reel?.id == saved.id)
    #expect(h.model.projectURL?.path == "/shoot/Saved.trimlab")
    #expect(!h.model.history.canUndo)
    await h.model.pendingPrune?.value
    #expect(h.media.state.withLock { $0.prunedKeeping } == [saved.clips.map(\.source)])
  }

  /// I-1: every import batch prunes the media cache once it has settled, keeping the Reel's clips.
  @Test func importBatchPrunesTheCache() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    let first = try #require(h.model.reel).clips.map(\.source)
    #expect(h.media.state.withLock { $0.prunedKeeping } == [first])
    await h.importAll(["c.mov"])
    let all = try #require(h.model.reel).clips.map(\.source)
    #expect(all.count == 3)
    #expect(h.media.state.withLock { $0.prunedKeeping } == [first, all])
  }

  /// I-1: a refused or empty drop prunes nothing (no clips were added).
  @Test func importWithNothingToAddDoesNotPrune() async {
    let h = Harness()
    await h.importAll(["notes.txt"])
    #expect(h.media.state.withLock { $0.prunedKeeping }.isEmpty)
  }

  /// M-6: a modal opened while the batch's dates are being read holds the batch; the tiles land once it closes.
  @Test func importWaitsForAModalOpenedMidImport() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.media.holdItems()
    let task = h.model.importURLs([Harness.url("b.mov", in: "/shoot")], at: nil)
    #expect(await h.media.waitForItems(2))  // a's, then b's
    h.model.showKeyMap()
    #expect(h.model.keyMapOpen)
    h.media.releaseItems()
    try await Task.sleep(for: .milliseconds(300))
    #expect(h.names == ["a.mov"], "the tiles landed under the key map: \(h.names)")
    h.model.closeKeyMap()
    await task.value
    #expect(h.names == ["a.mov", "b.mov"])
    #expect(h.model.selection.primary == h.model.reel?.clips.last?.id)
  }

  /// M-6: the same for the export sheet.
  @Test func importWaitsForTheExportSheetOpenedMidImport() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.media.holdItems()
    let task = h.model.importURLs([Harness.url("b.mov", in: "/shoot")], at: nil)
    #expect(await h.media.waitForItems(2))
    h.model.requestExport()
    #expect(h.model.modals.contains(.exportSheet))
    h.media.releaseItems()
    try await Task.sleep(for: .milliseconds(300))
    #expect(h.names == ["a.mov"], "the tiles landed under the export sheet: \(h.names)")
    h.model.closeExportSheet()
    await task.value
    #expect(h.names == ["a.mov", "b.mov"])
  }

  /// M-6: a held batch ends quietly when its Reel goes (New Reel): nothing lands in the next one.
  @Test func heldImportDoesNotLandInANewReel() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.media.holdItems()
    let task = h.model.importURLs([Harness.url("b.mov", in: "/shoot")], at: nil)
    #expect(await h.media.waitForItems(2))
    h.model.showKeyMap()
    h.media.releaseItems()
    try await Task.sleep(for: .milliseconds(100))
    h.model.closeKeyMap()
    h.model.newReel()
    await task.value
    #expect(h.names.isEmpty, "\(h.names)")
  }
}
