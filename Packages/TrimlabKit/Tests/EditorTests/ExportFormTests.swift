import Foundation
import ImageIO
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 35: the export sheet's rules (§4.9, §5.7): defaults, Quick and its reasons, the caption and summary, the file
/// name and folder, the over-3:00 line and the destination checks. Fields apply without an undo step (§4.8).
@MainActor @Suite struct ExportFormTests {
  private let nbsp = "\u{00A0}"

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  /// Facts on a 1/30 s grid, so lengths like 48.2 s and 3:12.4 land on whole frames.
  private func facts(_ seconds: Int64, tenths: Int64 = 0, hdr: HDRKind = .sdr, codec: String = "hevc",
                     audio: Bool = true, wide: Bool = false) -> ClipFacts {
    var f = StubMedia.facts(RationalTime(seconds * 10 + tenths, 10), fps: RationalTime(1, 30))
    f.hdr = hdr
    f.videoCodec = codec
    f.hasAudio = audio
    if wide {
      f.displayWidth = 1920
      f.displayHeight = 1080
    }
    return f
  }

  /// A Reel of one clip per entry, as the importer makes it.
  private func reel(_ clips: [ClipFacts], name: String = "Spa Tour", export: ExportSpec = ExportSpec()) -> Reel {
    var r = Reel.empty(name: name)
    r.export = export
    for (i, f) in clips.enumerated() {
      let ref = SourceRef(relativePath: nil, absolutePath: "/shoot/IMG_\(4821 + i).MOV", size: 1, modified: Date(timeIntervalSince1970: 0))
      r.clips.append(ReelClip.make(source: ref, facts: f, framing: .fill))
    }
    return r
  }

  private func open(_ h: Harness) throws -> ExportForm {
    h.model.requestExport()
    #expect(h.model.modals.top == .exportSheet)
    return try #require(h.model.exportForm)
  }

  // MARK: the brief's ten

  @Test func defaultsFromPrefs() async throws {
    let h = Harness(prefs: Prefs(format: .original, quality: .standard, cut: .quick))
    await h.importAll(["a.mov", "b.mov"])
    let form = try open(h)
    #expect(form.spec.format == .original)  // the pref
    #expect(form.spec.cut == .exact)  // Quick isn't allowed for two clips: the sheet shows Exact
    #expect(form.spec.convertHDR)
    #expect(h.model.reel?.export.cut == .exact)

    let d = Harness()
    await d.importAll(["a.mov", "b.mov"])
    let plain = try open(d)
    #expect(plain.spec.format == .reel && plain.spec.cut == .exact && plain.spec.quality == .high)
    #expect(plain.spec.convertHDR && !plain.spec.removeAudio)
    #expect(d.model.modals.close(.exportSheet) == "export-button")
  }

  @Test func quickDisabledReasons() {
    let two = ExportForm(reel: reel([facts(5), facts(5)], export: ExportSpec(format: .original)),
                         firstClipFolderWritable: true)
    #expect(two.quickRule == .needsSingleOriginal)
    #expect(two.quickTip == "Quick works on a single clip saved as Original.")

    let oneReel = ExportForm(reel: reel([facts(5)]), firstClipFolderWritable: true)
    #expect(oneReel.quickTip == "Quick works on a single clip saved as Original.")

    let hlg = ExportForm(reel: reel([facts(5, hdr: .hlg)], export: ExportSpec(format: .original, convertHDR: true)),
                         firstClipFolderWritable: true)
    #expect(hlg.quickRule == .cantConvertHDR)
    #expect(hlg.quickTip == "Quick can't convert HDR.")
    #expect(hlg.showsHDRRow)

    let kept = ExportForm(reel: reel([facts(5, hdr: .hlg)], export: ExportSpec(format: .original, convertHDR: false)),
                          firstClipFolderWritable: true)
    #expect(kept.quickRule == .allowed)
    #expect(kept.quickTip == nil)
    #expect(!ExportForm(reel: reel([facts(5)]), firstClipFolderWritable: true).showsHDRRow)
  }

  @Test func reelOrHDRSwitchesQuickToExact() async throws {
    var form = ExportForm(reel: reel([facts(5, hdr: .hlg)],
                                     export: ExportSpec(format: .original, cut: .quick, convertHDR: false)),
                          firstClipFolderWritable: true)
    #expect(form.spec.cut == .quick)
    form.set(format: .reel)
    #expect(form.spec.cut == .exact)
    form.set(format: .original)
    form.set(cut: .quick)
    #expect(form.spec.cut == .quick)
    form.set(convertHDR: true)
    #expect(form.spec.cut == .exact)
    form.set(cut: .quick)  // refused while it isn't allowed
    #expect(form.spec.cut == .exact)

    // Through the model: the Reel's own settings follow, with no undo step.
    let h = Harness()
    h.media.script("h.mov", .facts(facts(5, hdr: .hlg)))
    await h.importAll(["h.mov"])
    _ = try open(h)
    h.model.setExportFormat(.original)
    h.model.setExportConvertHDR(false)
    h.model.setExportCut(.quick)
    #expect(h.model.reel?.export.cut == .quick)
    let undoSteps = h.model.history.undoCount
    h.model.setExportFormat(.reel)
    #expect(h.model.reel?.export.cut == .exact)
    #expect(h.model.reel?.export.format == .reel)
    #expect(h.model.history.undoCount == undoSteps)
  }

  @Test func summaryStrings() {
    let r = reel([facts(48, tenths: 2)])
    let exact = ExportForm(reel: r, firstClipFolderWritable: true)
    #expect(exact.summary(bytes: 84_200_000) == "48.2\(nbsp)s  ·  about 84\(nbsp)MB  ·  H.264  ·  with sound")
    #expect(exact.summary(bytes: 400_000) == "48.2\(nbsp)s  ·  under 1\(nbsp)MB  ·  H.264  ·  with sound")

    let muted = ExportForm(reel: reel([facts(48, tenths: 2)], export: ExportSpec(removeAudio: true)),
                           firstClipFolderWritable: true)
    #expect(muted.summary(bytes: 84_000_000) == "48.2\(nbsp)s  ·  about 84\(nbsp)MB  ·  H.264  ·  no sound")
    let silent = ExportForm(reel: reel([facts(48, tenths: 2, audio: false)]), firstClipFolderWritable: true)
    #expect(silent.summary(bytes: 84_000_000).hasSuffix("  ·  no sound"))

    let hdrKept = ExportForm(reel: reel([facts(48, tenths: 2, hdr: .hlg)], export: ExportSpec(convertHDR: false)),
                             firstClipFolderWritable: true)
    #expect(hdrKept.summary(bytes: 84_000_000) == "48.2\(nbsp)s  ·  about 84\(nbsp)MB  ·  HEVC  ·  with sound")

    var quick = ExportForm(reel: reel([facts(48, tenths: 2)], export: ExportSpec(format: .original, cut: .quick)),
                           firstClipFolderWritable: true)
    #expect(quick.summary(bytes: 84_000_000)
      == "48.2\(nbsp)s  ·  about 84\(nbsp)MB  ·  video kept as recorded  ·  sound kept as recorded")
    quick.quickStart = RationalTime(-1, 2)  // the cut starts at the keyframe before In: half a second more
    #expect(quick.summary(bytes: 84_000_000).hasPrefix("48.7\(nbsp)s  ·  "))
    quick.set(removeAudio: true)
    #expect(quick.summary(bytes: 84_000_000).hasSuffix("  ·  no sound"))

    // The captions.
    #expect(exact.caption == "1080×1920, ready for Instagram.")
    let original = ExportForm(reel: reel([facts(5, wide: true)], export: ExportSpec(format: .original)),
                              firstClipFolderWritable: true)
    #expect(original.caption == "1920×1080 at 30 fps, from the first clip.")
    var ntsc = StubMedia.facts()
    ntsc.displayWidth = 1920
    ntsc.displayHeight = 1080
    let ntscForm = ExportForm(reel: reel([ntsc], export: ExportSpec(format: .original)), firstClipFolderWritable: true)
    #expect(ntscForm.caption == "1920×1080 at 29.97 fps, from the first clip.")
  }

  @Test func summaryThroughTheModel() async throws {
    let h = Harness()
    h.media.answerQuickBytes(3_500_000)
    h.media.answerKeyframes([.zero, RationalTime(4, 1)])
    h.media.script("a.mov", .facts(facts(10)))
    await h.importAll(["a.mov"])
    let id = try #require(h.model.reel?.clips.first?.id)
    h.model.perform(.setIn(id, RationalTime(5, 1)), coalesce: nil)
    _ = try open(h)
    let exactBytes = ExportEstimator.bytes(reel: try #require(h.model.reel))
    #expect(h.model.exportSummary == ExportForm(reel: try #require(h.model.reel), firstClipFolderWritable: true)
      .summary(bytes: exactBytes))
    h.model.setExportFormat(.original)
    h.model.setExportCut(.quick)
    #expect(h.model.exportSummary == nil)  // the line waits for the sample sizes
    await h.model.pendingQuickEstimate?.value
    // From the keyframe at 4 s to Out at 10 s.
    #expect(h.model.exportSummary == "6.0\(nbsp)s  ·  about 3\(nbsp)MB  ·  video kept as recorded  ·  sound kept as recorded")
  }

  @Test func fileNameOneVsMany() async throws {
    let one = ExportForm(reel: reel([facts(18)]), firstClipFolderWritable: true)
    #expect(one.fileName == "IMG_4821_0m00s-0m18s.mp4")
    let many = ExportForm(reel: reel([facts(5), facts(5)]), firstClipFolderWritable: true)
    #expect(many.fileName == "Spa Tour.mp4")
    // A Quick ProRes cut is written as .mov, and the name says so.
    let prores = ExportForm(reel: reel([facts(18, codec: "prores")], export: ExportSpec(format: .original, cut: .quick)),
                            firstClipFolderWritable: true)
    #expect(prores.fileName == "IMG_4821_0m00s-0m18s.mov")

    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    #expect(h.model.exportForm?.fileName == "shoot.mp4")
    h.model.setExportFileName("Day one.mp4")
    #expect(h.model.reel?.export.fileName == "Day one.mp4")
    #expect(h.model.exportForm?.destination.path == "/shoot/Day one.mp4")
  }

  @Test func folderFallsBackWhenUnwritable() async throws {
    let h = Harness()
    h.store.readOnlyFolders.withLock { _ = $0.insert("/card") }
    await h.importAll(["a.mov", "b.mov"], in: "/card")
    let form = try open(h)
    #expect(form.folder == Naming.fallbackFolder)
    #expect(form.folder.path.hasSuffix("/Movies/trimlab 2"))
    #expect(form.folderNote == "Saving to Movies › trimlab 2: the clips' folder is read-only.")
    #expect(ExportForm.plainName(form.folder) == "trimlab 2")
    #expect(h.store.madeFolders.withLock { $0 }.contains(Naming.fallbackFolder.path))

    let w = Harness()
    await w.importAll(["a.mov", "b.mov"])
    let writable = try open(w)
    #expect(writable.folder.path == "/shoot")
    #expect(writable.folderNote == nil)
  }

  @Test func chosenFolderRememberedPerReel() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    h.platform.state.withLock { $0.folderAnswer = URL(filePath: "/out", directoryHint: .isDirectory) }
    let steps = h.model.history.undoCount
    await h.model.chooseExportFolder().value
    #expect(h.model.reel?.export.folder == "/out")
    #expect(h.model.exportForm?.folder.path == "/out")
    #expect(h.model.history.undoCount == steps)
    h.model.closeExportSheet()
    #expect(h.model.modals.top == nil)
    _ = try open(h)
    #expect(h.model.exportForm?.folder.path == "/out")

    // Choose… cancelled leaves the folder alone.
    h.platform.state.withLock { $0.folderAnswer = nil }
    await h.model.chooseExportFolder().value
    #expect(h.model.reel?.export.folder == "/out")

    h.model.closeExportSheet()
    h.model.newReel()
    await h.importAll(["c.mov", "d.mov"], in: "/day2")
    #expect(try open(h).folder.path == "/day2")
  }

  @Test func overLimitLineInSheet() {
    let long = ExportForm(reel: reel([facts(192, tenths: 4)]), firstClipFolderWritable: true)
    #expect(long.overLimitLine == "Instagram Reels can be up to 3 minutes. Trim 0:12.4 more.")
    let original = ExportForm(reel: reel([facts(192, tenths: 4)], export: ExportSpec(format: .original)),
                              firstClipFolderWritable: true)
    #expect(original.overLimitLine == nil)
    #expect(ExportForm(reel: reel([facts(170)]), firstClipFolderWritable: true).overLimitLine == nil)
  }

  /// M-4: a folder named like the export blocks Export; it is not offered as a file to replace.
  @Test func folderOfTheSameNameBlocksExport() async throws {
    let h = Harness()
    await h.importAll(["a.mp4", "b.mov"])
    _ = try open(h)
    h.store.addFolder(try #require(h.model.exportForm).destination.path)
    h.model.recheckSheet()
    #expect(h.model.exportIssue == .isFolder)
    #expect(h.model.exportBlockLine == "A folder with that name is already there. Choose another name.")
    #expect(!h.model.canExport)
    #expect(!h.model.exportAsksReplace)
  }

  @Test func reelFileBlocksExport() async throws {
    let h = Harness()
    await h.importAll(["a.mp4", "b.mov"])
    _ = try open(h)
    #expect(h.model.canExport)
    h.model.setExportFileName("A.MP4")  // a clip's own file, case aside
    #expect(h.model.exportIssue == .isReelFile)
    #expect(h.model.exportBlockLine == "That's one of the Reel's files. Choose another name.")
    #expect(!h.model.canExport)
    // A typed .mov becomes .mp4 (Exact H.264), so b.mov's own name can't reach the clip.
    h.model.setExportFileName("b.mov")
    #expect(h.model.exportIssue == nil)
    // The project file can't be named either: "shoot.trimlab" is written as "shoot.trimlab.mp4".
    await h.model.saveNow().value
    let project = try #require(h.model.projectURL)
    h.model.setExportFileName(project.lastPathComponent)
    #expect(h.model.exportForm?.fileName == project.lastPathComponent + ".mp4")
    #expect(h.model.exportIssue == nil)
    h.model.setExportFileName("fine.mp4")
    #expect(h.model.exportIssue == nil)
    #expect(h.model.exportBlockLine == nil)
    #expect(h.model.canExport)
  }

  @Test func keepBothAddsTwo() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.store.add("/shoot/shoot.mp4")
    _ = try open(h)
    #expect(h.model.exportIssue == .exists)
    #expect(h.model.exportBlockLine == nil)  // the sheet asks instead: Replace / Keep both
    #expect(!h.model.canExport)
    h.model.exportKeepBoth()
    #expect(h.model.exportForm?.fileName == "shoot 2.mp4")
    #expect(h.model.exportIssue == nil)
    #expect(h.model.canExport)

    h.store.add("/shoot/shoot 2.mp4")
    h.model.setExportFileName("shoot.mp4")
    h.model.exportKeepBoth()
    #expect(h.model.exportForm?.fileName == "shoot 3.mp4")

    // Replace keeps the name and lets Export go; a new name asks again.
    h.model.setExportFileName("shoot.mp4")
    #expect(!h.model.canExport)
    h.model.exportReplace()
    #expect(h.model.exportForm?.fileName == "shoot.mp4")
    #expect(h.model.canExport)
    h.model.setExportFileName("shoot 2.mp4")
    #expect(!h.model.canExport)
  }

  // MARK: carries

  /// Carry 1: the sheet doesn't open over a missing clip or one still loading.
  @Test func missingAndLoadingStillRefuse() async throws {
    let h = Harness()
    h.media.unresolvable(["b.mov"])
    await h.importAll(["a.mov", "b.mov"])
    let b = try #require(h.model.reel?.clips.last?.id)
    h.model.missing.insert(b)
    h.model.requestExport()
    #expect(h.model.modals.top == nil)
    #expect(h.noteTexts.last == "b.mov is missing. Locate it or remove it from the Reel.")

    let l = Harness()
    l.media.hold()
    let importing = l.model.importURLs([Harness.url("a.mov")], at: nil)
    _ = await l.media.waitForProbes(1)
    l.model.requestExport()
    #expect(l.model.modals.top == nil)
    #expect(l.noteTexts.last == "Wait for the clips to finish loading.")
    l.media.release()
    await importing.value
  }

  /// The sheet's own missing line (§4.9), for a clip that goes missing while it's open.
  @Test func missingClipLineInSheet() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    let b = try #require(h.model.reel?.clips.last?.id)
    h.model.session.resolved[b] = nil
    #expect(h.model.exportIssue == .missing("b.mov"))
    #expect(h.model.exportBlockLine == "b.mov is missing. Locate it or remove it from the Reel.")
    #expect(!h.model.canExport)
  }

  /// Carry 2: a Quick ProRes cut is checked at the `.mov` it really writes.
  @Test func quickPreflightUsesQuickDestination() async throws {
    let h = Harness()
    h.media.script("a.mov", .facts(facts(10, codec: "prores")))
    await h.importAll(["a.mov"])
    _ = try open(h)
    h.model.setExportFormat(.original)
    h.model.setExportCut(.quick)
    h.model.setExportFileName("a.mp4")  // Quick writes a.mov: the clip itself
    #expect(h.model.exportForm?.destination.path == "/shoot/a.mov")
    #expect(h.model.exportIssue == .isReelFile)
    h.model.setExportCut(.exact)  // Exact writes a.mp4
    #expect(h.model.exportIssue == nil)

    h.store.add("/shoot/b.mov")
    h.model.setExportCut(.quick)
    h.model.setExportFileName("b.mp4")
    #expect(h.model.exportIssue == .exists)
    h.model.exportKeepBoth()
    #expect(h.model.exportForm?.fileName == "b 2.mov")
  }

  /// Carry 3: Return in the sheet's text field goes to the field (its onSubmit), not to the sheet's buttons.
  @Test func returnInModalFieldReachesField() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    let ret = KeyChord(key: .returnKey)
    #expect(h.model.handleKey(ret, isRepeat: false, inTextField: true) == .pass)
    #expect(h.model.modals.top == .exportSheet)
    // Outside the field Return presses the focused control: Cancel closes the sheet.
    h.model.focusedControl = "export-cancel"
    #expect(h.model.handleKey(ret, isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.modals.top == nil)
    // Esc in the field still closes the sheet.
    _ = try open(h)
    #expect(h.model.handleKey(KeyChord(key: .escape), isRepeat: false, inTextField: true) == .swallow)
    #expect(h.model.modals.top == nil)
  }

  /// The sheet's segmented controls take ← / → while focused; otherwise the sheet swallows them (the deck can't move).
  @Test func arrowsReachFocusedSheetControl() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    let left = KeyChord(key: .left)
    let playhead = h.model.playhead
    #expect(h.model.handleKey(left, isRepeat: false, inTextField: false) == .swallow)
    #expect(h.model.playhead == playhead)
    h.model.controlFocus("export-format", focused: true)
    #expect(h.model.handleKey(left, isRepeat: false, inTextField: false) == .pass)
    h.model.closeExportSheet()
    #expect(h.model.arrowControls.isEmpty)
  }

  /// Carry 4: a result with no first frame still makes a Done view.
  @Test func doneWithoutFirstFrame() {
    let result = ExportResult(url: URL(filePath: "/out/Spa Tour.mp4"), bytes: 84_100_000, firstFrame: nil,
                              usedSoftwareEncoder: false)
    let done = ExportDone(result)
    #expect(done.thumbnail == nil)
    #expect(done.fileName == "Spa Tour.mp4")
  }

  /// Carry 5: a failure's detail heads the Details text, then the log's last 30 lines.
  @Test func failureDetailsCarryDetail() {
    let log = (1...40).map { "line \($0)" }
    let other = ExportFailure(.other("AVFoundationErrorDomain -11800: The operation could not be completed"), log: log)
    #expect(other.sentence == "Something went wrong while saving.")
    let lines = other.details.split(separator: "\n").map(String.init)
    #expect(lines.first == "AVFoundationErrorDomain -11800: The operation could not be completed")
    #expect(Array(lines.suffix(30)) == (11...40).map { "line \($0)" })
    #expect(lines.count == 1 + 3 + 30)  // the detail, domain / code / description (T36), the log
    let full = ExportFailure(.diskFull, log: ["a"])
    #expect(full.sentence == "The disk is full.")
    #expect(full.details.hasPrefix("Domain: ") && full.details.hasSuffix("\na"))
  }

  /// §4.8 ruling: sheet fields change the Reel without an undo step, and undo leaves them as they are.
  @Test func fieldsRecordNoUndoStep() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    let before = h.model.history.undoCount
    h.model.setExportQuality(.standard)
    h.model.setExportFileName("x.mp4")
    h.model.setExportFormat(.original)
    #expect(h.model.history.undoCount == before)
    h.model.closeExportSheet()
    h.model.undo()
    #expect(h.model.reel?.export.quality == .standard)
    #expect(h.model.reel?.export.fileName == "x.mp4")
  }

  /// The sheet renders 560 px wide with every row in (an HDR clip, Quick disabled, a file already there).
  @Test func sheetRenders() async throws {
    let h = Harness()
    var f = StubMedia.facts()
    f.hdr = .hlg
    h.media.script("IMG_4821.MOV", .facts(f))
    await h.importAll(["IMG_4821.MOV", "b.mov"], in: "/Users/me/Movies/Spa Tour")
    h.model.perform(.rename("Spa Tour"), coalesce: nil)
    h.store.add("/Users/me/Movies/Spa Tour/Spa Tour.mp4")
    _ = try open(h)
    let renderer = ImageRenderer(content: ExportSheetView(model: h.model).fixedSize(horizontal: false, vertical: true)
      .background(Tokens.bg0))
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    #expect(image.width == 2 * 560)
    if let out = ProcessInfo.processInfo.environment["TRIMLAB_SHEET_PNG"],
       let dest = CGImageDestinationCreateWithURL(URL(filePath: out) as CFURL, "public.png" as CFString, 1, nil) {
      CGImageDestinationAddImage(dest, image, nil)
      CGImageDestinationFinalize(dest)
    }
  }

  // MARK: review fixes

  /// Finder drops (and any import) wait while the sheet is open: it describes the Reel as it is.
  @Test func importRefusedWhileSheetOpen() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    await h.importAll(["c.mov"])
    #expect(h.names == ["a.mov", "b.mov"])
    #expect(h.noteTexts.last == "Finish or cancel the export first.")
    h.model.finderDragOver(at: CGPoint(x: 10, y: 10), count: 1)
    h.model.finderDragOver(at: nil, count: 1)
    #expect(h.model.activeDrag == nil && !h.model.dropArmed)
    await h.model.finderDrop([Harness.url("d.mov")]).value
    #expect(h.names == ["a.mov", "b.mov"])
    h.model.closeExportSheet()
    await h.importAll(["c.mov"])
    #expect(h.names == ["a.mov", "b.mov", "c.mov"])
  }

  /// A clip probing again (a relink) holds Export until its facts are in.
  @Test func canExportWaitsForLoading() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    #expect(h.model.canExport)
    let b = try #require(h.model.reel?.clips.last?.id)
    h.model.loading[b] = .probing
    #expect(!h.model.canExport)
    #expect(h.model.exportBlockLine == "Wait for the clips to finish loading.")
    h.model.loading[b] = .ready
    #expect(h.model.canExport)
  }

  /// The summary follows the form's cut: a stored Quick that isn't allowed reads as Exact.
  @Test func summaryFollowsFormCut() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    var spec = try #require(h.model.reel?.export)
    spec.cut = .quick
    h.model.perform(.setExport(spec), coalesce: nil, record: false)
    #expect(h.model.exportForm?.spec.cut == .exact)
    #expect(h.model.exportSummary?.contains("H.264") == true)
  }

  /// v1's sanitize_filename (Task 14 carry): no "/" or ":", no leading dots, a typed video extension replaced, the
  /// stem at most 220 bytes, then .mp4 (.mov for a Quick ProRes cut).
  @Test func fileNameSanitized() throws {
    func name(_ typed: String?, reelName: String = "Spa Tour", export: ExportSpec = ExportSpec(),
              codec: String = "hevc", clips: Int = 2) -> String {
      var spec = export
      spec.fileName = typed
      return ExportForm(reel: reel(Array(repeating: facts(5, codec: codec), count: clips), name: reelName,
                                   export: spec), firstClipFolderWritable: true).fileName
    }
    #expect(name("Spa 10/29") == "Spa 1029.mp4")
    #expect(name("final") == "final.mp4")
    #expect(name("x.mov") == "x.mp4")  // Exact H.264 writes .mp4
    #expect(name("x.MKV") == "x.mp4")
    #expect(name("notes.txt") == "notes.txt.mp4")
    #expect(name("..hidden: one") == "hidden one.mp4")
    #expect(name("///") == "trimlab-export.mp4")
    #expect(name("   ") == "Spa Tour.mp4")  // empty is the default
    #expect(name(nil, reelName: "Day 1/2: pool") == "Day 12 pool.mp4")
    #expect(name("x.mp4", export: ExportSpec(format: .original, cut: .quick), codec: "prores", clips: 1) == "x.mov")

    let long = String(repeating: "a", count: 300)
    #expect(name(long) == String(repeating: "a", count: 220) + ".mp4")
    let wide = String(repeating: "é", count: 150)  // 300 bytes: cut at a whole character
    let cut = name(wide)
    #expect(cut == String(repeating: "é", count: 110) + ".mp4")
    #expect(cut.dropLast(4).utf8.count <= 220)

    // The field keeps what she typed; the file name is the safe one.
    var form = ExportForm(reel: reel([facts(5), facts(5)]), firstClipFolderWritable: true)
    form.set(fileName: "final")
    #expect(form.fieldText == "final")
    #expect(form.fileName == "final.mp4")
    #expect(form.destination.lastPathComponent == "final.mp4")
  }

  /// Typing a name doesn't restart Quick's sample scan for the same cut.
  @Test func quickEstimateNotRestartedForSameCut() async throws {
    let h = Harness()
    h.media.answerQuickBytes(2_000_000)
    await h.importAll(["a.mov"])
    _ = try open(h)
    h.model.setExportFormat(.original)
    h.model.setExportCut(.quick)
    h.model.setExportFileName("one")
    h.model.setExportFileName("two")
    await h.model.pendingQuickEstimate?.value
    #expect(h.media.quickBytesCalls == 1)
    #expect(h.model.exportSummary != nil)
  }

  /// The destination check runs once per change of what it reads, not on every read (T36 re-runs it at Export).
  @Test func issueComputedPerChange() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    _ = try open(h)
    #expect(h.model.exportIssue == nil)
    h.store.add("/shoot/shoot.mp4")  // appears behind the sheet's back
    #expect(h.model.exportIssue == nil)
    h.model.setExportFileName("shoot")  // same destination, new field text: checked again
    #expect(h.model.exportIssue == .exists)
  }

  /// Ruling: several missing clips are named once, with the others counted.
  @Test func severalMissingLine() async throws {
    #expect(ExportForm.missingLine(first: "IMG_4821.MOV", others: 0)
      == "IMG_4821.MOV is missing. Locate it or remove it from the Reel.")
    #expect(ExportForm.missingLine(first: "IMG_4821.MOV", others: 1)
      == "IMG_4821.MOV and 1 other clip is missing. Locate them or remove them from the Reel.")
    #expect(ExportForm.missingLine(first: "IMG_4821.MOV", others: 2)
      == "IMG_4821.MOV and 2 other clips are missing. Locate them or remove them from the Reel.")

    let h = Harness()
    await h.importAll(["a.mov", "b.mov", "c.mov"])
    _ = try open(h)
    let ids = try #require(h.model.reel?.clips.map(\.id))
    h.model.session.resolved[ids[1]] = nil
    h.model.session.resolved[ids[2]] = nil
    h.model.setExportFileName("x")  // a change: the check runs again
    #expect(h.model.exportBlockLine == "b.mov and 1 other clip is missing. Locate them or remove them from the Reel.")
    h.model.closeExportSheet()

    for id in ids { h.model.missing.insert(id) }
    h.model.requestExport()
    #expect(h.model.modals.top == nil)
    #expect(h.noteTexts.last == "a.mov and 2 other clips are missing. Locate them or remove them from the Reel.")
  }
}
