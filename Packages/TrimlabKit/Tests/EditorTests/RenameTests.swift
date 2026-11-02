import Foundation
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// The header's Reel name, renamed inline (§6.1): one undo step (§4.8) that renames the `.trimlab` file beside it
/// through the write chain, refusing a name that's taken (§8.2; final review I-2).
@MainActor @Suite struct RenameTests {
  /// Two clips in /shoot, saved once: the Reel is "shoot" at /shoot/shoot.trimlab.
  static func saved() async -> Harness {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await ProjectTests.elapse(h, .seconds(1))
    #expect(h.model.projectURL?.path == "/shoot/shoot.trimlab")
    return h
  }

  static func files(_ h: Harness) -> [String] { ProjectTests.trimlabFiles(h).sorted() }

  static func recents(_ h: Harness) -> [String] { h.platform.state.withLock { $0.recents.map(\.path) } }

  // MARK: editing

  @Test func beginAndCancel() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    let steps = h.model.history.undoCount
    h.model.beginRenameReel()
    #expect(h.model.editingReelName)
    h.model.cancelRenameReel()
    #expect(!h.model.editingReelName)
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.history.undoCount == steps)
  }

  /// A one-clip Reel shows its file name and isn't renameable (§6.1).
  @Test func oneClipIsNotRenameable() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.model.beginRenameReel()
    #expect(!h.model.editingReelName)
    await h.model.renameReel("Spa Tour").value
    #expect(h.model.reel?.name == "shoot")
    #expect(RootView<EmptyView>.reelName(h.model) == nil)
  }

  @Test func headerOffersTheNameForTwoClips() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    let name = try? #require(RootView<EmptyView>.reelName(h.model))
    #expect(name?.name == "shoot")
    #expect(name?.editing == false)
    h.model.beginRenameReel()
    #expect(RootView<EmptyView>.reelName(h.model)?.editing == true)
    #expect(EditorModel.reelNameControl == "reel.name")
  }

  // MARK: the name

  /// Before the file exists only the name changes, as one undo step; the first save is named after it.
  @Test func renameBeforeTheFileExists() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    #expect(h.model.projectURL == nil)
    let steps = h.model.history.undoCount
    h.model.beginRenameReel()
    await h.model.renameReel("  Spa Tour  ").value
    #expect(!h.model.editingReelName)
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(h.model.history.undoCount == steps + 1)
    await ProjectTests.elapse(h, .seconds(1))
    #expect(h.store.writeLog == ["/shoot/Spa Tour.trimlab"])
    #expect(try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab").name == "Spa Tour")
  }

  /// Empty, whitespace-only, or unchanged after trimming: nothing happens.
  @Test func emptyOrUnchangedDoesNothing() async {
    let h = await Self.saved()
    let steps = h.model.history.undoCount
    for typed in ["", "   ", "\t", " shoot "] {
      h.model.beginRenameReel()
      await h.model.renameReel(typed).value
      #expect(!h.model.editingReelName)
    }
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.history.undoCount == steps)
    #expect(Self.files(h) == ["/shoot/shoot.trimlab"])
    #expect(h.noteTexts.isEmpty)
  }

  /// Sanitised like the export file name (`Naming.sanitized`): no "/" or ":", a typed video extension dropped.
  @Test func nameIsSanitised() async {
    let h = await Self.saved()
    await h.model.renameReel("Day 2: the/end.mp4").value
    #expect(h.model.reel?.name == Naming.sanitized("Day 2: the/end.mp4", ext: ""))
    #expect(h.model.reel?.name == "Day 2 theend")
    #expect(Self.files(h) == ["/shoot/Day 2 theend.trimlab"])
  }

  /// The default export name follows the Reel name (`<Reel name>.mp4`).
  @Test func exportNameFollows() async throws {
    let h = await Self.saved()
    await h.model.renameReel("Spa Tour").value
    #expect(Naming.exportFileName(try #require(h.model.reel)) == "Spa Tour.mp4")
  }

  /// Nothing while an export runs or a modal is open, like other edits.
  @Test func refusedUnderAModal() async {
    let h = await Self.saved()
    h.model.requestExport()
    #expect(h.model.modals.top != nil)
    h.model.beginRenameReel()
    #expect(!h.model.editingReelName)
    await h.model.renameReel("Spa Tour").value
    #expect(h.model.reel?.name == "shoot")
    #expect(Self.files(h) == ["/shoot/shoot.trimlab"])
  }

  @Test func refusedWhileExporting() async throws {
    let h = try await ScreenStates.running()
    defer { ScreenStates.releaseHeld() }
    let before = h.model.reel?.name
    await h.model.renameReel("Spa Tour").value
    #expect(h.model.reel?.name == before)
  }

  // MARK: the file

  @Test func renameMovesTheFile() async throws {
    let h = await Self.saved()
    let steps = h.model.history.undoCount
    await h.model.renameReel("Spa Tour").value
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(h.model.history.undoCount == steps + 1)
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    #expect(h.model.projectURL?.path == "/shoot/Spa Tour.trimlab")
    #expect(Self.recents(h).last == "/shoot/Spa Tour.trimlab")
    // The moved file holds the same Reel; the next save writes the new name into it, and nothing else appears.
    await ProjectTests.elapse(h, .seconds(1))
    #expect(try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab").name == "Spa Tour")
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    // The clips are never touched.
    #expect(h.store.writeLog.allSatisfy { $0.hasSuffix(".trimlab") })
  }

  /// A name taken by any file or folder: refused with a quiet note, nothing recorded, nothing moved.
  @Test func takenNameIsRefused() async throws {
    let h = await Self.saved()
    h.store.add("/shoot/Taken.trimlab", Data("theirs".utf8))
    h.store.addFolder("/shoot/Folder.trimlab")
    let steps = h.model.history.undoCount
    await h.model.renameReel("Taken").value
    await h.model.renameReel("folder").value  // case-insensitive, like APFS
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.history.undoCount == steps)
    #expect(h.model.projectURL?.path == "/shoot/shoot.trimlab")
    #expect(h.store.data("/shoot/Taken.trimlab") == Data("theirs".utf8))
    #expect(h.store.data("/shoot/shoot.trimlab") != nil)
    #expect(h.noteTexts == ["A Reel named “Taken” is already in this folder.",
                            "A Reel named “folder” is already in this folder."])
    #expect(h.model.notes.allSatisfy { $0.kind == .quiet })
    #expect(EditorModel.takenNote("X") == "A Reel named “X” is already in this folder.")
  }

  /// Undo and redo bring the name back and move the file back and forth; each restores the selection.
  @Test func undoAndRedoMoveTheFile() async throws {
    let h = await Self.saved()
    let a = try #require(h.model.reel?.clips[0].id)
    h.model.select(a, extend: false, toggle: false)
    await h.model.renameReel("Spa Tour").value
    h.model.select(try #require(h.model.reel?.clips[1].id), extend: false, toggle: false)
    h.model.undo()
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.selection.primary == a)
    await h.model.pendingRename?.value
    #expect(Self.files(h) == ["/shoot/shoot.trimlab"])
    #expect(h.model.projectURL?.path == "/shoot/shoot.trimlab")
    h.model.redo()
    #expect(h.model.reel?.name == "Spa Tour")
    await h.model.pendingRename?.value
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    #expect(h.model.projectURL?.path == "/shoot/Spa Tour.trimlab")
    #expect(Self.recents(h).suffix(3) == ["/shoot/Spa Tour.trimlab", "/shoot/shoot.trimlab", "/shoot/Spa Tour.trimlab"])
  }

  /// Undo can't move the file back over a name taken meanwhile: the file stays, the name still changes.
  @Test func undoKeepsTheFileWhenTheOldNameIsTaken() async throws {
    let h = await Self.saved()
    await h.model.renameReel("Spa Tour").value
    h.store.add("/shoot/shoot.trimlab", Data("someone else".utf8))
    h.model.undo()
    await h.model.pendingRename?.value
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.projectURL?.path == "/shoot/Spa Tour.trimlab")
    #expect(h.store.data("/shoot/shoot.trimlab") == Data("someone else".utf8))
    await ProjectTests.elapse(h, .seconds(1))
    #expect(try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab").name == "shoot")
    #expect(h.store.data("/shoot/shoot.trimlab") == Data("someone else".utf8))
  }

  /// A save asked for while the rename waits behind a slow write goes to the new file, never the old name.
  @Test func savesDuringTheRenameGoToTheNewFile() async throws {
    let h = await Self.saved()
    h.store.holdWrites()
    h.model.perform(.setRemoveAudio(true), coalesce: nil)
    h.model.saveNow()  // held on the "disk"
    #expect(await h.store.waitForWriteStarted(2))
    let renamed = h.model.renameReel("Spa Tour")
    h.model.perform(.setRemoveAudio(false), coalesce: nil)
    await ProjectTests.elapse(h, .seconds(1), fires: false)
    h.model.saveNow()
    h.store.releaseWrites()
    await renamed.value
    await h.model.pendingSave?.value
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    let saved = try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab")
    #expect(saved.name == "Spa Tour")
    #expect(saved.export.removeAudio == false)
  }

  /// New Reel while the rename is queued: the closed Reel's last save follows its file to the new name.
  @Test func newReelDuringTheRename() async throws {
    let h = await Self.saved()
    let id = try #require(h.model.reel?.id)
    h.store.holdWrites()
    h.model.perform(.setRemoveAudio(true), coalesce: nil)
    h.model.saveNow()
    #expect(await h.store.waitForWriteStarted(2))
    _ = h.model.renameReel("Spa Tour")
    let rename = h.model.pendingRename
    h.model.newReel()
    h.store.releaseWrites()
    await rename?.value
    await h.model.pendingSave?.value
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    let saved = try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab")
    #expect(saved.id == id)
    #expect(saved.name == "Spa Tour")
    #expect(h.model.reel == nil)
  }

  // MARK: the screen

  /// The `rename` screen state draws the field (no can't-render placeholder) with the name in it, and nothing is
  /// written (`ScreensTests.renderAll` makes the PNGs).
  @Test func renameStateRenders() async throws {
    FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts")
    let state = try #require(ScreenStates.all.first { $0.id == "rename" })
    let image = try ScreensTests.still(try await state.make(1), state.size)
    ScreenStates.releaseHeld()
    #expect(try ScreensTests.topColourShare(image) < 0.95)
    let plain = try ScreensTests.still(try await #require(ScreenStates.all.first { $0.id == "reel" }).make(1), state.size)
    ScreenStates.releaseHeld()
    let (yellow, gold) = try Self.headerRight(image)
    let (_, plainGold) = try Self.headerRight(plain)
    #expect(yellow == 0, "placeholder yellow: \(yellow)")
    // The well's 1 px gold edge round a 240 × 30 field is some 500 px more than the plain header has.
    #expect(gold - plainGold > 400, "the focused well's gold edge: \(gold) vs \(plainGold)")
  }

  /// Placeholder-yellow and gold (`--brand-gold`, warm and bright) pixels in the header's right half.
  static func headerRight(_ image: CGImage) throws -> (yellow: Int, gold: Int) {
    let px = try StageViewTests.pixels(image)
    var yellow = 0, gold = 0
    for y in 0..<56 {
      for x in 700..<image.width {
        let c = StageViewTests.rgb(px, image, x: x, y: y)
        if c[0] > 240 && c[1] > 190 && c[2] < 40 { yellow += 1 }
        if c[0] > 150, Int(c[0]) > Int(c[2]) + 60 { gold += 1 }
      }
    }
    return (yellow, gold)
  }

  // MARK: round 2 (coordinator)

  /// A typed ".trimlab" (any case) is the file's extension, not part of the name.
  @Test func typedTrimlabExtensionIsDropped() async {
    let h = await Self.saved()
    await h.model.renameReel("Spa Tour.trimlab").value
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    await h.model.renameReel("Day 2.TRIMLAB  ").value
    #expect(h.model.reel?.name == "Day 2")
    let steps = h.model.history.undoCount
    await h.model.renameReel(" .trimlab ").value  // nothing left: nothing happens
    #expect(h.model.reel?.name == "Day 2")
    #expect(h.model.history.undoCount == steps)
  }

  /// Editing gives the field focus through the focus link, with the name as its draft.
  @Test func beginFocusesTheField() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.beginRenameReel()
    #expect(h.model.focusedControl == EditorModel.reelNameField)
    #expect(h.model.reelNameDraft == "shoot")
  }

  /// Return in the field commits the draft and hands keyboard focus (with its ring) back to the name.
  @Test func returnCommitsAndFocusReturns() async {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    #expect(h.model.handleKey(KeyChord(key: .returnKey), isRepeat: false, inTextField: true) == .swallow)
    #expect(!h.model.editingReelName)
    await h.model.pendingRename?.value
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(h.model.focusedControl == EditorModel.reelNameControl)
    #expect(h.model.focusRing)
    // The field's own Return arriving after (onSubmit) finds nothing to commit.
    let steps = h.model.history.undoCount
    h.model.setReelNameDraft("Other")
    await h.model.commitRenameReel(keyboard: true).value
    #expect(h.model.history.undoCount == steps)
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
  }

  /// Esc in the field drops the draft and hands focus back to the name, ring on; a late commit does nothing.
  @Test func escapeCancelsAndFocusReturns() async {
    let h = await Self.saved()
    let steps = h.model.history.undoCount
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    #expect(h.model.handleKey(KeyChord(key: .escape), isRepeat: false, inTextField: true) == .swallow)
    #expect(!h.model.editingReelName)
    #expect(h.model.focusedControl == EditorModel.reelNameControl)
    #expect(h.model.focusRing)
    await h.model.commitRenameReel(keyboard: false).value  // the field losing focus as it goes
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.history.undoCount == steps)
  }

  /// Clicking away commits; the pointer leaves no focus (and so no ring) behind, as `pointerPressed` does.
  @Test func clickAwayCommitsWithoutFocus() async {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    await h.model.commitRenameReel(keyboard: false).value
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(h.model.focusedControl == nil)  // the field held it: nothing does now
    // Focus that went on to another control (a click into it) stays there.
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Day 2")
    h.model.setFocusedControl(EditorModel.helpControl)
    await h.model.commitRenameReel(keyboard: false).value
    #expect(h.model.reel?.name == "Day 2")
    #expect(h.model.focusedControl == EditorModel.helpControl)
  }

  /// Keys outside the field (or with no field) are left alone.
  @Test func returnOutsideTheFieldPasses() async {
    let h = await Self.saved()
    #expect(h.model.handleKey(KeyChord(key: .returnKey), isRepeat: false, inTextField: false) == .pass)
    #expect(h.model.reel?.name == "shoot")
  }

  /// ⌘E while a committed rename's move is in flight opens the sheet once it lands: the sheet shows the new name,
  /// and the rename is an undo step like any other.
  @Test func exportWaitsForTheRename() async throws {
    let h = await Self.saved()
    let steps = h.model.history.undoCount
    h.store.holdWrites()
    h.model.perform(.setRemoveAudio(true), coalesce: nil)
    h.model.saveNow()  // the move waits behind this held write
    #expect(await h.store.waitForWriteStarted(2))
    let renamed = h.model.renameReel("Spa Tour")
    h.model.requestExport()
    #expect(!h.model.exportSheetOpen)
    h.store.releaseWrites()
    await renamed.value
    await h.model.pendingExportRequest?.value
    #expect(h.model.exportSheetOpen)
    #expect(h.model.exportForm?.fileName == "Spa Tour.mp4")
    #expect(h.model.history.undoCount == steps + 2)  // remove audio, then the rename
  }

  // MARK: review fixes (rename-review.md)

  /// Holds the "disk" with a save in flight, so a rename committed now waits behind it.
  static func holdBehindAWrite(_ h: Harness) async {
    h.store.holdWrites()
    h.model.perform(.setRemoveAudio(true), coalesce: nil)
    h.model.saveNow()
    #expect(await h.store.waitForWriteStarted(2))
  }

  static func forgotten(_ h: Harness) -> [String] { h.platform.state.withLock { $0.forgotten.map(\.path) } }

  /// I-1: a Reel closed while its rename waits is saved with its still-probing clips flagged `needsProbe`.
  @Test func closedReelKeepsItsPlaceholderFlags() async throws {
    let h = await Self.saved()
    h.media.hold()
    _ = h.model.importURLs([Harness.url("c.mov")], at: nil)
    #expect(await h.media.waitForProbes(3))
    #expect(await ScreenStates.eventually { h.model.reel?.clips.count == 3 })
    let probing = try #require(h.model.reel?.clips.last?.id)
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    let rename = h.model.pendingRename
    h.model.newReel()
    h.store.releaseWrites()
    await rename?.value
    await h.model.pendingSave?.value
    h.media.release()
    let saved = try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab")
    #expect(saved.clips.first { $0.id == probing }?.extra[EditorModel.needsProbeKey] == .bool(true))
  }

  /// I-3: while an input method is composing, Return and Esc are the composition's.
  @Test func composingTextKeepsReturnAndEscape() async {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("にほん")
    #expect(h.model.handleKey(KeyChord(key: .returnKey), isRepeat: false, inTextField: true, composing: true) == .pass)
    #expect(h.model.handleKey(KeyChord(key: .escape), isRepeat: false, inTextField: true, composing: true) == .pass)
    #expect(h.model.editingReelName)
    #expect(h.model.reel?.name == "shoot")
  }

  /// I-4: ⌘E commits the name being typed; the sheet opens on it.
  @Test func exportCommitsTheOpenRename() async {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    h.model.requestExport()
    #expect(!h.model.editingReelName)
    await h.model.pendingRename?.value
    await h.model.pendingExportRequest?.value
    #expect(h.model.exportSheetOpen)
    #expect(h.model.exportForm?.fileName == "Spa Tour.mp4")
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
  }

  /// I-4 and M-4: `?` commits the name; a move landing under the key map changes the name only once it closes.
  @Test func keyMapCommitsAndTheNameWaitsForItToClose() async {
    let h = await Self.saved()
    let steps = h.model.history.undoCount
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    h.model.showKeyMap()
    #expect(h.model.keyMapOpen)
    await h.model.pendingRename?.value
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])  // the file has moved
    #expect(h.model.projectURL?.path == "/shoot/Spa Tour.trimlab")
    #expect(h.model.reel?.name == "shoot")  // nothing recorded under the modal
    #expect(h.model.history.undoCount == steps)
    h.model.closeKeyMap()
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(h.model.history.undoCount == steps + 1)
  }

  /// I-4: New Reel commits the name being typed, and the closed Reel's file takes it.
  @Test func newReelCommitsTheOpenRename() async throws {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    h.model.newReel()
    #expect(!h.model.editingReelName)
    #expect(h.model.reel == nil)
    await h.model.pendingSave?.value  // the closed Reel's last save, after its rename
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    #expect(try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab").name == "Spa Tour")
  }

  /// I-4: quitting (and the window closing) commits the name being typed before the last save.
  @Test func quitCommitsTheOpenRename() async throws {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    await h.model.prepareForQuit()
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    #expect(try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab").name == "Spa Tour")
    let w = await Self.saved()
    w.model.beginRenameReel()
    w.model.setReelNameDraft("Day 2")
    w.model.commitOpenRename()  // the window closing, before its save
    await w.model.saveNow().value
    #expect(Self.files(w) == ["/shoot/Day 2.trimlab"])
    #expect(try ProjectTests.savedReel(w, "/shoot/Day 2.trimlab").name == "Day 2")
  }

  /// I-4: a modal that opens some other way (the ffmpeg card) ends the field, leaving the name as it was.
  @Test func aModalEndsAStaleField() async {
    let h = await Self.saved()
    h.model.beginRenameReel()
    h.model.setReelNameDraft("Spa Tour")
    h.model.openFFmpegCard(refusing: [])
    #expect(!h.model.editingReelName)
    #expect(h.model.reel?.name == "shoot")
  }

  /// I-5: two ⌘E presses during the wait open the sheet once.
  @Test func doubleExportPressOpensOnce() async {
    let h = await Self.saved()
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    let before = h.model.sheetOpenings
    h.model.requestExport()
    h.model.requestExport()
    h.store.releaseWrites()
    await h.model.pendingRename?.value
    await h.model.pendingExportRequest?.value
    #expect(h.model.exportSheetOpen)
    #expect(h.model.sheetOpenings == before + 1)
  }

  /// I-5: a modal opened during the wait wins: the sheet doesn't stack on it.
  @Test func exportRetryRechecksTheModal() async {
    let h = await Self.saved()
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    h.model.requestExport()
    h.model.showKeyMap()
    let retry = h.model.pendingExportRequest
    h.store.releaseWrites()
    await h.model.pendingRename?.value
    await retry?.value
    #expect(h.model.keyMapOpen)
    #expect(!h.model.exportSheetOpen)
  }

  /// I-5: opening another Reel during the wait cancels the ⌘E; the sheet never shows for the new Reel.
  @Test func openCancelsTheExportRetry() async throws {
    let h = await Self.saved()
    let id = try #require(h.model.reel?.id)
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    let rename = h.model.pendingRename
    h.model.requestExport()
    let retry = h.model.pendingExportRequest
    ProjectTests.openStored(h, [ProjectTests.stored("/other/a.mov"), ProjectTests.stored("/other/b.mov")],
                            at: "/other/other.trimlab")
    h.store.releaseWrites()
    await rename?.value
    await retry?.value
    await h.model.pendingSave?.value
    #expect(!h.model.exportSheetOpen)
    // Open during the move: the closed Reel's file still took its new name, and holds it.
    let saved = try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab")
    #expect(saved.id == id)
    #expect(saved.name == "Spa Tour")
    #expect(h.store.data("/shoot/shoot.trimlab") == nil)
    #expect(h.model.projectURL?.path == "/other/other.trimlab")
  }

  /// Quit during the move: the last save waits for it and lands in the renamed file.
  @Test func quitDuringTheMove() async throws {
    let h = await Self.saved()
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    h.model.perform(.setRemoveAudio(false), coalesce: nil)
    let quit = Task { await h.model.prepareForQuit() }
    h.store.releaseWrites()
    await quit.value
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    let saved = try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab")
    #expect(saved.name == "Spa Tour")
    #expect(saved.export.removeAudio == false)
  }

  /// M-1: the file is worked out when the move runs, and must be this Reel's: one replaced outside trimlab by
  /// another Reel's file is never renamed.
  @Test func anotherReelsFileIsNeverRenamed() async throws {
    let h = await Self.saved()
    let id = try #require(h.model.reel?.id)
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    let other = Reel.empty(name: "Other")
    h.store.add("/shoot/shoot.trimlab", ProjectCodec.encode(other))  // replaced outside trimlab
    h.store.releaseWrites()
    await h.model.pendingRename?.value
    await h.model.pendingSave?.value
    await ProjectTests.elapse(h, .seconds(1))
    await h.model.pendingSave?.value
    #expect(try ProjectTests.savedReel(h, "/shoot/shoot.trimlab").id == other.id)
    let ours = Self.files(h).filter { (try? ProjectTests.savedReel(h, $0))?.id == id }
    #expect(ours.contains("/shoot/Spa Tour.trimlab"))
    #expect(h.store.moves.withLock { $0 }.isEmpty)
  }

  /// M-2: Open Recent swaps the old path for the new one.
  @Test func openRecentSwapsThePath() async {
    let h = await Self.saved()
    await h.model.renameReel("Spa Tour").value
    #expect(Self.recents(h).last == "/shoot/Spa Tour.trimlab")
    #expect(Self.forgotten(h) == ["/shoot/shoot.trimlab"])
  }

  /// M-2: a move that lands after New Reel still puts the new path on Open Recent and takes the old one off.
  @Test func openRecentFollowsAClosedReel() async {
    let h = await Self.saved()
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    let rename = h.model.pendingRename
    h.model.newReel()
    h.store.releaseWrites()
    await rename?.value
    await h.model.pendingSave?.value
    #expect(Self.recents(h).contains("/shoot/Spa Tour.trimlab"))
    #expect(Self.forgotten(h) == ["/shoot/shoot.trimlab"])
  }

  /// `.gone`: the file was deleted outside trimlab. The name still changes; the next save writes the new name, and
  /// Open Recent has it.
  @Test func deletedFileIsWrittenUnderTheNewName() async throws {
    let h = await Self.saved()
    _ = h.store.files.withLock { $0.removeValue(forKey: "/shoot/shoot.trimlab") }
    await h.model.renameReel("Spa Tour").value
    #expect(h.model.reel?.name == "Spa Tour")
    #expect(h.model.projectURL?.path == "/shoot/Spa Tour.trimlab")
    #expect(Self.recents(h).last == "/shoot/Spa Tour.trimlab")
    await ProjectTests.elapse(h, .seconds(1))
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
    #expect(try ProjectTests.savedReel(h, "/shoot/Spa Tour.trimlab").name == "Spa Tour")
  }

  /// M-3 and M-6: a move that fails says so (the folder is there: it's read-only), and nothing changes.
  @Test func failedMoveSaysTheFolderMayBeReadOnly() async {
    let h = await Self.saved()
    h.store.failingMoves.withLock { _ = $0.insert("/shoot/shoot.trimlab") }
    let steps = h.model.history.undoCount
    await h.model.renameReel("Spa Tour").value
    #expect(h.model.reel?.name == "shoot")
    #expect(h.model.history.undoCount == steps)
    #expect(h.noteTexts == ["The Reel's file couldn't be renamed. Its folder may be read-only."])
    #expect(h.model.notes.last?.kind == .error)
    #expect(Self.files(h) == ["/shoot/shoot.trimlab"])
  }

  /// M-6: a name a save was refused at counts as taken, even with nothing there now.
  @Test func refusedSaveNameIsTaken() async {
    let h = await Self.saved()
    h.model.neverAutosave.insert(URL(filePath: "/shoot/Spa Tour.trimlab"))
    await h.model.renameReel("spa tour").value
    #expect(h.model.reel?.name == "shoot")
    #expect(h.noteTexts == [EditorModel.takenNote("spa tour")])
    #expect(Self.files(h) == ["/shoot/shoot.trimlab"])
  }

  /// M-6: two renames committed before the first lands run in order; the file ends with the second name.
  @Test func chainedRenames() async throws {
    let h = await Self.saved()
    let steps = h.model.history.undoCount
    await Self.holdBehindAWrite(h)
    _ = h.model.renameReel("Spa Tour")
    let second = h.model.renameReel("Day 2")
    h.store.releaseWrites()
    await second.value
    #expect(h.model.reel?.name == "Day 2")
    #expect(h.model.history.undoCount == steps + 3)  // remove audio, then both names
    #expect(Self.files(h) == ["/shoot/Day 2.trimlab"])
    #expect(h.model.projectURL?.path == "/shoot/Day 2.trimlab")
    h.model.undo()
    await h.model.pendingRename?.value
    #expect(Self.files(h) == ["/shoot/Spa Tour.trimlab"])
  }

  /// M-7: a name that sanitises to nothing ("...", "///") is nothing typed.
  @Test func nameThatSanitisesToNothing() async {
    let h = await Self.saved()
    for typed in ["...", "///", " : "] { await h.model.renameReel(typed).value }
    #expect(h.model.reel?.name == "shoot")
    #expect(Self.files(h) == ["/shoot/shoot.trimlab"])
  }
}
