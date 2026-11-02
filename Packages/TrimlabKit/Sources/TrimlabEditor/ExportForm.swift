import CoreGraphics
import Foundation
import TrimlabMedia
import TrimlabModel

/// §4.9, §5.7. What the export sheet shows and allows for a Reel, worked out from the Reel's own export settings
/// (which a new Reel takes from the prefs: `EditorModel.defaultExport`). Pure: the model supplies whether the first
/// clip's folder is writable and, for Quick, where the cut really starts.
public struct ExportForm: Equatable, Sendable {
  public static let quickSingleTip = "Quick works on a single clip saved as Original."
  public static let quickHDRTip = "Quick can't convert HDR."
  public static let reelFileLine = "That's one of the Reel's files. Choose another name."
  public static let existsLine = "A file with this name is already there."
  public static let folderLine = "A folder with that name is already there. Choose another name."
  public static let unwritableLine = "Can't save in this folder. Choose another."
  public static let fallbackNote = "Saving to Movies › trimlab 2: the clips' folder is read-only."

  /// The Reel the sheet describes, its export settings as the sheet has them.
  public private(set) var reel: Reel
  /// The clips left out of the plan (missing sources).
  public let missing: Set<UUID>
  /// Whether the first clip's folder takes new files; when it doesn't, the default folder is `~/Movies/trimlab 2/`.
  public let firstClipFolderWritable: Bool
  /// Quick only: the keyframe the cut really starts at (`KeyframeIndex.snappedIn`), once known; nil reads as In.
  public var quickStart: RationalTime?

  public init(reel: Reel, firstClipFolderWritable: Bool, missing: Set<UUID> = [], quickStart: RationalTime? = nil) {
    self.reel = reel
    self.missing = missing
    self.firstClipFolderWritable = firstClipFolderWritable
    self.quickStart = quickStart
    if reel.export.cut == .quick, quickRule != .allowed { self.reel.export.cut = .exact }
  }

  public var spec: ExportSpec { reel.export }

  // MARK: rows

  public var quickRule: QuickRule {
    var r = reel
    r.export.cut = .quick
    return QuickCut.isAllowed(r)
  }

  /// Quick's tooltip while it shows disabled; nil while it can be chosen.
  public var quickTip: String? {
    switch quickRule {
    case .allowed: nil
    case .needsSingleOriginal: Self.quickSingleTip
    case .cantConvertHDR: Self.quickHDRTip
    }
  }

  /// The HDR row shows when any clip is HDR.
  public var showsHDRRow: Bool { reel.clips.contains { $0.facts.hdr != .sdr } }

  private var plan: CompositionPlan { Planner.plan(reel, missing: missing) }

  /// Under Format: "1080×1920, ready for Instagram." or "1920×1080 at 29.97 fps, from the first clip."
  public var caption: String {
    if spec.format == .reel { return "1080×1920, ready for Instagram." }
    let p = plan
    return "\(p.renderSize.width)×\(p.renderSize.height) at \(Formatting.fps(p.frameDuration)) fps, from the first clip."
  }

  /// The §4.3.6 line in `--warn`, for a Reel-format export past 3:00.
  public var overLimitLine: String? {
    guard spec.format == .reel, let excess = reel.overLimit(missing: missing) else { return nil }
    return Formatting.overLimitLine(excess)
  }

  // MARK: summary

  /// "48.2 s  ·  about 84 MB  ·  H.264  ·  with sound": the length, the size, the video and the sound, two spaces
  /// either side of each `·`. Numbers keep their units (no-break space, §4.12).
  public func summary(bytes: Int64) -> String {
    let quick = spec.cut == .quick
    var length = plan.total
    if quick, let clip = reel.clips.first {
      length = clip.outTime - (quickStart ?? clip.inTime)
    }
    let size = bytes < 1_000_000 ? "under 1\(Self.nbsp)MB" : "about \(bytes / 1_000_000)\(Self.nbsp)MB"
    let video = quick ? "video kept as recorded" : plan.hdrOut ? "HEVC" : "H.264"
    let hasSound = !spec.removeAudio && reel.clips.contains { !missing.contains($0.id) && $0.facts.hasAudio }
    let sound = !hasSound ? "no sound" : quick ? "sound kept as recorded" : "with sound"
    return [Formatting.total(max(length, .zero)), size, video, sound].joined(separator: "  ·  ")
  }

  static let nbsp = "\u{00A0}"

  // MARK: file

  /// What the File name field shows: the name as she typed it, else the default (made safe).
  public var fieldText: String { spec.fileName ?? fileName }

  /// The file name written: the typed name or the default (one clip's `<stem>_<in>-<out>`, or the Reel's name), made
  /// safe by v1's rules (`Naming.sanitized`: no "/" or ":", a typed video extension replaced, a 220-byte stem) and
  /// ending `.mp4` (`.mov` for a Quick ProRes cut, which is what `QuickCut` writes).
  public var fileName: String {
    let typed = spec.fileName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    let base = typed ?? (Naming.exportFileName(reel) as NSString).deletingPathExtension
    return Naming.sanitized(base, ext: outputExtension)
  }

  /// `.mov` for a Quick cut of a ProRes clip, `.mp4` otherwise.
  var outputExtension: String {
    guard spec.cut == .quick, let clip = reel.clips.first, QuickCut.fileType(for: clip) == .mov else { return ".mp4" }
    return ".mov"
  }

  /// The chosen folder (remembered per Reel), else the first clip's own, else `~/Movies/trimlab 2/`.
  public var folder: URL {
    if let chosen = spec.folder { return URL(filePath: chosen, directoryHint: .isDirectory) }
    guard let first = reel.clips.first else { return Naming.fallbackFolder }
    let own = URL(filePath: first.source.absolutePath, directoryHint: .notDirectory).deletingLastPathComponent()
    return firstClipFolderWritable ? own : Naming.fallbackFolder
  }

  /// The quiet note under Save to when the clips' folder is read-only and nothing was chosen.
  public var folderNote: String? {
    spec.folder == nil && !reel.clips.isEmpty && !firstClipFolderWritable ? Self.fallbackNote : nil
  }

  /// The file the export writes: `folder/fileName`, with a Quick cut's extension as `QuickCut` writes it.
  public var destination: URL {
    let dest = folder.appending(path: fileName, directoryHint: .notDirectory)
    guard spec.cut == .quick, let clip = reel.clips.first else { return dest }
    return QuickCut.destination(for: clip, dest: dest)
  }

  /// §4.9's checks against `destination`: a Reel file, a missing clip, a file already there, an unwritable folder.
  public func issue(projectFile: URL?, resolve: (ReelClip) -> URL?, fileExists: (URL) -> Bool,
                    isFolder: (URL) -> Bool = { ExportPreflight.isDirectory($0) }, isWritable: (URL) -> Bool)
    -> PreflightIssue? {
    ExportPreflight.check(dest: destination, reel: reel, projectFile: projectFile, resolve: resolve,
                          fileExists: fileExists, isFolder: isFolder, isWritable: isWritable)
  }

  /// The line that blocks Export for `issue`; nil when there's none or when the sheet asks instead (Replace / Keep both).
  /// `otherMissing`: how many clips besides the one `.missing` names are missing too.
  public static func blockLine(_ issue: PreflightIssue?, otherMissing: Int = 0) -> String? {
    switch issue {
    case .isReelFile?: reelFileLine
    case .missing(let name)?: missingLine(first: name, others: otherMissing)
    case .folderUnwritable?: unwritableLine
    case .isFolder?: folderLine
    case .exists?, nil: nil
    }
  }

  /// §4.9's missing line; with more than one clip missing the first is named and the rest counted (ruling).
  public static func missingLine(first: String, others: Int) -> String {
    switch others {
    case ...0: "\(first) is missing. Locate it or remove it from the Reel."
    case 1: "\(first) and 1 other clip is missing. Locate them or remove them from the Reel."
    default: "\(first) and \(others) other clips are missing. Locate them or remove them from the Reel."
    }
  }

  public static let loadingLine = "Wait for the clips to finish loading."
  /// A sheet reopened while the last export is still tidying up (at most `ExportRunner.cancelWait`, 2.5 s). Invented
  /// copy (Task 37), flagged for the owner.
  public static let finishingLine = "Finishing the last export…"

  /// "Keep both": the destination's name with " 2" (then " 3", …) added, free among `existing`.
  public mutating func keepBoth(existing: Set<String>) {
    reel.export.fileName = Naming.keepBoth(fileName, existing: existing)
  }

  /// A folder as people name it: its own name, never a path or `~` ("Spa Tour", "Documents"); "Home" for the home
  /// folder.
  public static func plainName(_ folder: URL) -> String {
    let path = folder.standardizedFileURL.path
    if path == URL.homeDirectory.standardizedFileURL.path { return "Home" }
    let name = folder.lastPathComponent
    return name.isEmpty ? path : name
  }

  // MARK: changes

  /// Reel or Original. Reel switches a Quick cut to Exact, visibly (v1 ruling).
  public mutating func set(format: ExportSpec.Format) {
    reel.export.format = format
    exactUnlessQuickAllowed()
  }

  /// Quick only while it's allowed.
  public mutating func set(cut: ExportSpec.Cut) {
    guard cut == .exact || quickRule == .allowed else { return }
    reel.export.cut = cut
  }

  public mutating func set(quality: ExportSpec.Quality) { reel.export.quality = quality }

  /// Turning conversion on switches a Quick cut to Exact.
  public mutating func set(convertHDR: Bool) {
    reel.export.convertHDR = convertHDR
    exactUnlessQuickAllowed()
  }

  public mutating func set(removeAudio: Bool) { reel.export.removeAudio = removeAudio }

  /// Kept as typed (the field shows it; `fileName` is the safe form). An empty name goes back to the default.
  public mutating func set(fileName: String) {
    reel.export.fileName = fileName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileName
  }

  public mutating func set(folder: URL) { reel.export.folder = folder.standardizedFileURL.path }

  private mutating func exactUnlessQuickAllowed() {
    if reel.export.cut == .quick, quickRule != .allowed { reel.export.cut = .exact }
  }
}

/// §4.9 Done, as the Done view shows it. The first frame can be missing (logged by the runner); the view then shows
/// the still's empty well.
public struct ExportDone {
  public static let fallbackText = "Saved with the slower software encoder."

  public let thumbnail: CGImage?
  public let fileName: String
  public let url: URL
  public let bytes: Int64
  public let usedSoftwareEncoder: Bool

  public init(_ result: ExportResult) {
    thumbnail = result.firstFrame
    fileName = result.url.lastPathComponent
    url = result.url
    bytes = result.bytes
    usedSoftwareEncoder = result.usedSoftwareEncoder
  }

  /// "84.1 MB, in Spa Tour": the size, then the folder's plain name (never a path or `~`).
  public var whereLine: String {
    "\(Self.size(bytes)), in \(ExportForm.plainName(url.deletingLastPathComponent()))"
  }

  /// After the software retry (§5.5 step 7); nil otherwise.
  public var fallbackLine: String? { usedSoftwareEncoder ? Self.fallbackText : nil }

  /// v1's size: one decimal in GB and MB, whole KB (at least 1) below; the unit kept on its number.
  static func size(_ b: Int64) -> String {
    let nbsp = ExportForm.nbsp
    if b >= 1_000_000_000 { return String(format: "%.1f", Double(b) / 1e9) + "\(nbsp)GB" }
    if b >= 1_000_000 { return String(format: "%.1f", Double(b) / 1e6) + "\(nbsp)MB" }
    return "\(max(1, Int((Double(b) / 1e3).rounded())))\(nbsp)KB"
  }

  /// The still's box: the output's shape with its long side 128 px (a Reel's 72×128, a landscape Original's 128×72).
  public static func stillSize(_ render: PixelSize?) -> CGSize {
    guard let render, render.width > 0, render.height > 0 else { return CGSize(width: 72, height: 128) }
    let w = Double(render.width), h = Double(render.height)
    return w < h ? CGSize(width: (128 * w / h).rounded(), height: 128) : CGSize(width: 128, height: (128 * h / w).rounded())
  }
}

/// §4.9 Error: the plain sentence, and the Details text: the failure's own detail (`ExportError.detail`), its domain,
/// code and description (the system error it came from, else the `ExportError` itself), then the log's last 30 lines.
public struct ExportFailure {
  public static let logLines = 30
  public let sentence: String
  public let details: String

  public init(_ error: ExportError, cause: ExportCause? = nil, log: [String]) {
    sentence = error.sentence
    let ns = error as NSError
    // trimlab's own errors: the sentence describes them (the detail, if any, heads the text already).
    let origin = cause ?? ExportCause(domain: ns.domain, code: ns.code, description: error.sentence)
    let head = [error.detail].compactMap { $0 } + [
      "Domain: \(origin.domain)", "Code: \(origin.code)", "Description: \(origin.description)",
    ]
    details = (head + log.suffix(Self.logLines)).joined(separator: "\n")
  }
}

/// The sheet's state that isn't an export setting: Replace chosen for the current destination, and Quick's estimate.
public struct ExportSheetState: Equatable, Sendable {
  /// Replace was chosen for this destination; any other destination asks again.
  public var replacing: URL?
  /// What Quick's summary needs, for the cut it was worked out for.
  public var quick: QuickEstimate?
  /// A line after an export that ended without a file: "Export cancelled. Nothing was saved." (v1); goes with the
  /// next change.
  public var note: String?
  /// The Error view's Details disclosure is open (Copy shows with it).
  public var detailsOpen = false

  public init() {}
}

public struct QuickEstimate: Equatable, Sendable {
  /// The clip's file, its In and Out, and whether sound counts: when any changes the estimate is redone.
  public var key: Key
  public var start: RationalTime
  public var bytes: Int64

  public struct Key: Equatable, Sendable {
    var source: SourceRef
    var inTime, outTime: RationalTime
    var includeAudio: Bool
  }
}

// MARK: - the model's side

/// The export sheet's intents (§4.9). Every field applies to the Reel's own export settings with no undo step (§4.8:
/// export settings aren't undone; Task 35 ruling), so they're kept with the Reel and saved with it.
extension EditorModel {
  /// The control that opens the sheet (Export… and ⌘E): focus goes back to it on close.
  static let sheetOpener = "export-button"
  /// Every sheet control's id starts with this.
  static let sheetControlPrefix = "export-"

  public var exportSheetOpen: Bool { modals.contains(.exportSheet) }

  /// The form for the open Reel; nil without clips. Worked out (with the disk checks) once per change of what it
  /// reads (`SheetInputs`), not on every read.
  public var exportForm: ExportForm? { sheetChecks()?.form }

  /// The destination check for the form as it stands, as of the last change to what it reads. It doesn't watch the
  /// disk: a file that appears behind the sheet's back is caught by the next change, and by Export's own preflight.
  public var exportIssue: PreflightIssue? { sheetChecks()?.issue }

  /// The inline line that disables Export, if any: the last export still tidying up, a destination problem, else
  /// clips still loading.
  public var exportBlockLine: String? {
    guard let checks = sheetChecks() else { return nil }
    if liveExport != nil, !exportRunning { return ExportForm.finishingLine }
    if let line = ExportForm.blockLine(checks.issue, otherMissing: checks.otherMissing) { return line }
    return loadingClipIDs.isEmpty ? nil : ExportForm.loadingLine
  }

  /// A file already there that hasn't been answered with Replace: the sheet asks "Replace / Keep both".
  public var exportAsksReplace: Bool { exportIssue == .exists }

  /// Export goes only with nothing in the way: no destination problem (or Replace chosen for this file) and every
  /// clip's facts in.
  public var canExport: Bool {
    guard liveExport == nil, let checks = sheetChecks(), loadingClipIDs.isEmpty else { return false }
    switch checks.issue {
    case nil: return true
    case .exists?: return exportSheet.replacing == checks.form.destination
    default: return false
    }
  }

  /// The summary line, or nil while Quick's sample sizes are on their way (the line keeps its box).
  public var exportSummary: String? {
    guard let form = exportForm else { return nil }
    if form.spec.cut == .quick {
      guard let q = exportSheet.quick, q.key == quickKey(form.reel) else { return nil }
      return form.summary(bytes: q.bytes)
    }
    return form.summary(bytes: ExportEstimator.bytes(reel: form.reel))
  }

  /// What the form and its checks read; a change to any of it works them out again.
  struct SheetInputs: Equatable {
    var reel: Reel
    var missing: Set<UUID>
    var resolved: [UUID: URL]
    var projectURL: URL?
    var quick: QuickEstimate?
    /// Bumped by each opening of the sheet, so every opening checks the disk afresh.
    var opening: Int
    /// Bumped by a recheck (`recheckSheet`); observed, so the views redraw what it finds.
    var revision: Int
  }

  struct SheetChecks {
    var inputs: SheetInputs
    var form: ExportForm
    var issue: PreflightIssue?
    var otherMissing: Int
  }

  /// The cached form and checks, worked out again when their inputs changed.
  func sheetChecks() -> SheetChecks? {
    guard let reel, let first = reel.clips.first else { return nil }
    let inputs = SheetInputs(reel: reel, missing: missing, resolved: session.resolved, projectURL: projectURL,
                             quick: exportSheet.quick, opening: sheetOpenings, revision: sheetRevision)
    if let cached = sheetCache, cached.inputs == inputs { return cached }
    let own = URL(filePath: first.source.absolutePath, directoryHint: .notDirectory).deletingLastPathComponent()
    var form = ExportForm(reel: reel, firstClipFolderWritable: store.isWritable(own), missing: missing)
    if form.spec.cut == .quick, let q = exportSheet.quick, q.key == quickKey(form.reel) { form.quickStart = q.start }
    let resolved = session.resolved
    let issue = form.issue(projectFile: projectURL, resolve: { resolved[$0.id] }, fileExists: store.exists,
                           isFolder: store.isFolder, isWritable: store.isWritable)
    let unresolved = reel.clips.filter { resolved[$0.id] == nil }.count
    let checks = SheetChecks(inputs: inputs, form: form, issue: issue, otherMissing: max(unresolved - 1, 0))
    sheetCache = checks
    return checks
  }

  // MARK: open and close

  /// Opens the sheet over the editor (`requestExport` has already refused a missing or loading clip). A Quick cut
  /// that isn't allowed shows as Exact; the fallback folder is made if it's the one shown.
  func openExportSheet() {
    guard let form = exportForm else { return }
    if form.spec != reel?.export { apply(form) }
    if form.folderNote != nil { try? store.makeFolder(form.folder) }
    exportSheet = ExportSheetState()
    sheetOpenings += 1
    exportState = .editing
    modals.open(.exportSheet, opener: Self.sheetOpener)
    focusedControl = nil
    registerSheetControls()
    refreshQuickEstimate()
  }

  /// Cancel, Esc or the scrim (also from Done and Error): focus goes back to Export…. Never while an export runs:
  /// only the progress view's Cancel stops it.
  public func closeExportSheet() {
    guard exportSheetOpen, !exportRunning else { return }
    shutExportSheet()
  }

  func shutExportSheet() {
    focusedControl = modals.close(.exportSheet)
    arrowControls = arrowControls.filter { !$0.hasPrefix(Self.sheetControlPrefix) }
    exportState = .idle
    pendingQuickEstimate?.cancel()
    pendingQuickEstimate = nil
    pendingQuickKey = nil
    exportSheet = ExportSheetState()
    sheetCache = nil
  }

  // MARK: fields

  public func setExportFormat(_ f: ExportSpec.Format) { change { $0.set(format: f) } }
  public func setExportCut(_ c: ExportSpec.Cut) { change { $0.set(cut: c) } }
  public func setExportQuality(_ q: ExportSpec.Quality) { change { $0.set(quality: q) } }
  public func setExportConvertHDR(_ on: Bool) { change { $0.set(convertHDR: on) } }
  public func setExportFileName(_ name: String) { change { $0.set(fileName: name) } }

  /// Choose…: the native folder panel, starting at the folder shown. The pick is remembered for this Reel only.
  @discardableResult
  public func chooseExportFolder() -> Task<Void, Never> {
    let start = exportForm?.folder
    return Task { [weak self] in
      guard let self, let picked = await self.platform.chooseFolder(start: start), self.exportSheetOpen else { return }
      self.change { $0.set(folder: picked) }
    }
  }

  /// Keep both: the name gets " 2" (or the next free number) in the destination folder.
  public func exportKeepBoth() {
    guard let form = exportForm else { return }
    let existing = Set(store.list(form.folder))
    change { $0.keepBoth(existing: existing) }
  }

  /// Replace: the file there will be replaced (only ever a file that isn't one of the Reel's).
  public func exportReplace() {
    guard exportIssue == .exists, let dest = exportForm?.destination else { return }
    exportSheet.replacing = dest
    registerSheetControls()
  }

  // MARK: keys

  /// Return or Space on a sheet control with keyboard focus (§4.10).
  func activateSheetControl(_ id: String) {
    switch id {
    case "export-cancel": closeExportSheet()
    case "export-go": startExport()
    case "export-choose": chooseExportFolder()
    case "export-hdr": if let on = exportForm?.spec.convertHDR { setExportConvertHDR(!on) }
    case "export-replace": exportReplace()
    case "export-keep-both": exportKeepBoth()
    case "export-stop": cancelExport()
    case "export-reveal": exportDone(.reveal)
    case "export-quicktime": exportDone(.quickTime)
    case "export-airdrop": exportDone(.airDrop)
    case "export-new-reel": newReelFromDone()
    case "export-details": toggleExportDetails()
    case "export-copy": copyExportDetails()
    case "export-close": closeExportSheet()
    case "export-back": exportBackToSettings()
    default: break
    }
  }

  /// The sheet's controls in Tab order, as the pane on show has them.
  var sheetControlIDs: [String] {
    switch exportState {
    case .running: return ["export-stop"]
    case .done: return ["export-reveal", "export-quicktime"] + (exportAirDropOK ? ["export-airdrop"] : [])
      + ["export-new-reel"]
    case .failed: return ["export-details"] + (exportSheet.detailsOpen ? ["export-copy"] : [])
      + ["export-close", "export-back"]
    case .idle, .editing: break
    }
    guard let form = exportForm else { return [] }
    var ids = ["export-format", "export-cut", "export-quality"]
    if form.showsHDRRow { ids.append("export-hdr") }
    ids += ["export-name", "export-choose"]
    if exportAsksReplace { ids += ["export-replace", "export-keep-both"] }
    return ids + ["export-cancel", "export-go"]
  }

  func registerSheetControls() { modals.register(sheetControlIDs, for: .exportSheet) }

  // MARK: internals

  private func change(_ body: (inout ExportForm) -> Void) {
    guard exportSheetOpen, !exportRunning, var form = exportForm else { return }
    let before = form.destination
    body(&form)
    guard form.spec != reel?.export else { return }
    exportSheet.note = nil
    apply(form)
    if exportForm?.destination != before { exportSheet.replacing = nil }
    registerSheetControls()
    refreshQuickEstimate()
  }

  private func apply(_ form: ExportForm) {
    perform(.setExport(form.spec), coalesce: nil, record: false)
  }

  private func quickKey(_ reel: Reel) -> QuickEstimate.Key? {
    guard let clip = reel.clips.first else { return nil }
    return QuickEstimate.Key(source: clip.source, inTime: clip.inTime, outTime: clip.outTime,
                             includeAudio: !reel.export.removeAudio && clip.facts.hasAudio)
  }

  /// Quick's size is the source's own samples from the keyframe at or before In to Out (§5.5 step 8), read off the
  /// main actor; the summary waits for it.
  func refreshQuickEstimate() {
    guard exportSheetOpen, let reel, reel.export.cut == .quick, let clip = reel.clips.first,
          let key = quickKey(reel), let url = url(for: clip.id)
    else { return }
    if exportSheet.quick?.key == key || pendingQuickKey == key { return }
    pendingQuickEstimate?.cancel()
    pendingQuickKey = key
    let known = deckKeyframes[clip.source]
    pendingQuickEstimate = Task { [weak self, media] in
      let index: KeyframeIndex? = if let known { known } else { try? await media.keyframes(clip, at: url) }
      let start = index?.snappedIn(clip.inTime) ?? clip.inTime
      let bytes = await media.quickBytes(clip, at: url, range: start..<clip.outTime, includeAudio: key.includeAudio)
      guard !Task.isCancelled, let self else { return }
      if self.pendingQuickKey == key { self.pendingQuickKey = nil }
      guard self.exportSheetOpen, self.reel.flatMap(self.quickKey) == key else { return }
      self.exportSheet.quick = QuickEstimate(key: key, start: start, bytes: bytes)
    }
  }
}
