import AVFoundation
import Foundation
import Observation
import TrimlabMedia
import TrimlabModel

public enum PlayState: Hashable, Sendable { case paused, playing(rate: Double) }

public enum StripZoom: Hashable, Sendable { case fit, pxPerSecond(Double) }

/// The deck's peek: the source frame under the pointer while it hovers a handle or the clip (§4.4).
public struct Peek: Hashable, Sendable {
  public var clipID: UUID
  public var sourceTime: RationalTime
  public init(clipID: UUID, sourceTime: RationalTime) {
    self.clipID = clipID
    self.sourceTime = sourceTime
  }
}

public enum ExportState: Sendable {
  case idle, editing
  /// `progress` 0...1; `eta` in seconds, nil until known.
  case running(progress: Double, eta: Double?)
  case done(ExportResult)
  case failed(ExportError, details: String)
}

/// A one-line note under the stage. `.quiet` is information, `.error` something that didn't happen.
public struct Note: Hashable, Identifiable, Sendable {
  public enum Kind: Hashable, Sendable { case quiet, error }
  public let id: UUID
  public var text: String
  public var kind: Kind
  public init(id: UUID = UUID(), text: String, kind: Kind) {
    self.id = id
    self.text = text
    self.kind = kind
  }
}

/// A tile's state while its facts arrive. `.preparing` is a .mkv/.avi being remuxed.
public enum LoadState: Hashable, Sendable { case probing, preparing, ready, missing }

/// §7.3. The editor's whole state and its intents. Views read it; every change to the Reel goes through `perform`.
@MainActor @Observable
public final class EditorModel {
  public internal(set) var reel: Reel? {
    didSet { if editingReelName { renameStateChanged() } }
  }
  /// Another primary clip resets the deck to 1× (§4.4).
  public internal(set) var selection = Selection() {
    didSet {
      guard oldValue.primary != selection.primary else { return }
      resetDeckZoom()
      if deckPressed != nil { dropDeckPress() }  // the press was on the clip the deck no longer shows
    }
  }
  public internal(set) var history = History()
  public internal(set) var playhead = RationalTime.zero
  public internal(set) var playState = PlayState.paused
  public var stripZoom = StripZoom.fit
  /// The deck's zoom, 1× (the whole clip) to `DeckLayout.maxZoom` (frame level). Read clamped through `deckLayout()`.
  public var deckZoom: Double = 1
  /// Where the zoomed deck's visible window starts, in source time (zero at 1×). Read clamped through `deckLayout()`.
  public internal(set) var deckOffset = RationalTime.zero
  /// The deck handle held right now: Task 33's drag sets it; the canvas draws its glow from it.
  public internal(set) var deckGrab: DeckLayout.Handle?
  /// The deck's waveform peaks (50 a second) and Quick's keyframes, by source file, as they arrive
  /// (`requestDeckMedia`). The filmstrip shares the strip's sprite (`stripSprites`).
  public internal(set) var deckPeaks: [SourceRef: [Float16]] = [:]
  public internal(set) var deckKeyframes: [SourceRef: KeyframeIndex] = [:]
  /// Deck media asked for and not back yet: its block shimmers.
  public internal(set) var deckPending: Set<DeckFetch> = []
  public internal(set) var peek: Peek?
  public internal(set) var modals = ModalStack() {
    didSet { renameStateChanged() }
  }
  public internal(set) var exportState = ExportState.idle
  /// The open export sheet's own state: Replace chosen, Quick's estimate (`ExportForm.swift`).
  public internal(set) var exportSheet = ExportSheetState()
  /// Quick's size estimate on its way (tests await it).
  @ObservationIgnored public internal(set) var pendingQuickEstimate: Task<Void, Never>?
  /// The cut `pendingQuickEstimate` is scanning, so a change that leaves it alone (a file name) doesn't restart it.
  @ObservationIgnored var pendingQuickKey: QuickEstimate.Key?
  /// The sheet's form and destination checks for the inputs they were worked out from (`sheetChecks`).
  @ObservationIgnored var sheetCache: SheetChecks?
  /// Bumped each time the sheet opens: every opening checks the disk afresh.
  @ObservationIgnored var sheetOpenings = 0
  /// The file the running (or last) export writes, as the progress view names it.
  public internal(set) var exportFileName: String?
  /// The running export's stream, read to its end (tests await it; `EditorModel+Export.swift`).
  @ObservationIgnored public internal(set) var pendingExport: Task<Void, Never>?
  /// The export the sheet is showing. A force-closed sheet clears it, so whatever that export reports next cancels it.
  @ObservationIgnored var exportToken: UUID?
  /// The export whose stream is still being read, whether or not a sheet shows it (a force-closed sheet's export runs
  /// on until it's cancelled). Nothing new starts while it's set, and Quit cancels it.
  public internal(set) var liveExport: UUID?
  /// Bumped when the sheet's disk checks are redone with no other change the views would see (Export's recheck).
  public internal(set) var sheetRevision = 0
  /// Whether AirDrop can send the file Done shows, asked once as it shows.
  public internal(set) var exportAirDropOK = false
  public internal(set) var notes: [Note] = []
  /// Keyed by clip id, for the clips in the Reel only.
  public internal(set) var loading: [UUID: LoadState] = [:]
  public internal(set) var missing: Set<UUID> = []
  /// Rebuilt after every change to `reel` or `missing`; nil without a Reel.
  public internal(set) var plan: CompositionPlan?
  public internal(set) var projectURL: URL?
  public var prefs: Prefs
  /// `-TLExportFolder`: the folder every new Reel's export settings start with (nil: the first clip's folder).
  public var exportFolderOverride: String?
  /// The Reel as a handle drag (Task 33) has it right now: set during the drag, nil otherwise, never recorded in
  /// history or saved. The strip draws from `draftReel ?? reel`, so a live trim moves it without a commit.
  public internal(set) var draftReel: Reel?
  /// `draftReel`'s plan, rebuilt with it (read only while `draftReel` is set).
  @ObservationIgnored var draftPlan: CompositionPlan?
  /// The strip's frames by source file (split halves share one), as they arrive (`requestStripSprites`).
  public internal(set) var stripSprites: [SourceRef: StripSprite] = [:]
  /// Sprites asked for and not back yet: their tiles shimmer until a poster or the sprite lands.
  public internal(set) var spritePending: Set<SourceRef> = []
  /// Each source's poster as a one-frame strip sprite (§4.1: facts, poster, then sprite): what a tile draws until its
  /// sprite lands, which then replaces it.
  public internal(set) var stripPosters: [SourceRef: StripSprite] = [:]
  /// How far the zoomed strip is scrolled, in px (0 in Fit). Read clamped through `stripLayout()`.
  public internal(set) var stripScrollX: CGFloat = 0
  /// A reorder past the threshold, or Finder files over the strip: what the caret and ghost draw from.
  public internal(set) var activeDrag: StripDrag?
  /// Finder files over the window but not the strip: v1's armed hairline frame (a drop appends).
  public internal(set) var dropArmed = false
  /// The control Tab last moved to inside the top modal (`ModalStack.next`), or the one that opened a modal that has
  /// just closed. The modal views draw their focus ring from it (§4.10).
  public internal(set) var focusedControl: String? {
    didSet { focusRing = handlingKey }
  }
  /// Whether `focusedControl` came from the keyboard (Tab, Esc, Return, Space, a control reporting keyboard focus):
  /// only then does the control draw its ring. A modal closed with the mouse hands focus back without one (§4.10;
  /// coordinator ruling, Task 37 review).
  public internal(set) var focusRing = true
  /// Set while `handleKey` runs, so a focus change it makes counts as the keyboard's.
  @ObservationIgnored var handlingKey = false

  /// Bumped by a press on the strip, deck or stage (`pointerPressed`): focused caption controls let go of focus.
  public internal(set) var focusResetToken = 0
  /// Focused controls that take plain ← / → for themselves (`controlFocus`); while any is, the arrows pass.
  @ObservationIgnored var arrowControls: Set<String> = []
  /// Whether a text field had focus at the last key event (`handleKey`); `keyContext` reports it.
  @ObservationIgnored var textFieldFocused = false
  /// The strip's width, as the view last laid it out; the model hit-tests against it.
  @ObservationIgnored public internal(set) var stripWidth: CGFloat = 0
  /// The strip's frame in its window (SwiftUI global space, top-left origin), as the view last reported it; nil
  /// while no strip is on screen. Scroll-wheel events count only inside it.
  @ObservationIgnored public internal(set) var stripFrame: CGRect?
  /// The deck's width, as the view last laid it out (the zoom ceiling depends on it).
  @ObservationIgnored public internal(set) var deckWidth: CGFloat = 0
  /// The deck's frame in its window (SwiftUI global space), as the view last reported it; nil while none is on
  /// screen. Scroll-wheel events count only inside it.
  @ObservationIgnored public internal(set) var deckFrame: CGRect?
  /// Deck fetches running, cancelled by `reset`.
  @ObservationIgnored var deckFetches: [DeckFetch: Task<Void, Never>] = [:]
  /// The last deck fetch started (tests await it).
  @ObservationIgnored public internal(set) var pendingDeckMedia: Task<Void, Never>?
  /// A press on the strip that hasn't been released (`stripPress`).
  @ObservationIgnored var stripPressed: StripPress?
  /// A press on the deck that hasn't been released (`deckPress`).
  @ObservationIgnored var deckPressed: DeckPress?
  /// A press on the strip or deck is held (the app's stall watchdog counts it as a drag).
  public var pointerHeld: Bool { stripPressed != nil || deckPressed != nil }
  /// The next auto-scroll tick of a reorder near an edge (tests await it).
  @ObservationIgnored public internal(set) var pendingAutoScroll: Task<Void, Never>?
  /// The clock sleep under `pendingAutoScroll`, cancelled with it.
  @ObservationIgnored var autoScrollSleep: Task<Bool, Never>?

  /// The open Reel's session caches (`Session`); `reset` replaces them all at once.
  @ObservationIgnored var session = Session()

  let platform: any PlatformServices
  let media: any MediaServices
  let store: any ProjectStore
  let clock: any Clock<Duration>
  /// The Reel preview (§5.3). Its player is what the stage shows.
  public let preview: any PreviewDriving
  /// Per-clip source players for peek (§4.2).
  let scrub = ScrubPool()
  /// The scrub player showing `peek`, once its asset is loaded; nil outside peek.
  public internal(set) var peekPlayer: AVPlayer?

  /// The other end of a Shift-click range.
  @ObservationIgnored var anchor: UUID?
  /// The last cache prune started (tests await it).
  @ObservationIgnored var pendingPrune: Task<Void, Never>?
  /// Import batches still running; New Reel and open cancel them.
  @ObservationIgnored var importTasks: [UUID: Task<Void, Never>] = [:]
  /// The debounced save waiting on `clock` (tests await it); `saveNow` and a newer edit replace it.
  @ObservationIgnored public internal(set) var pendingAutosave: Task<Void, Never>?
  /// The clock sleep under `pendingAutosave`, cancelled with it.
  @ObservationIgnored var autosaveSleep: Task<Bool, Never>?
  /// Bumped by every `scheduleAutosave` and `saveNow`; an older debounce that wakes up late stands down.
  @ObservationIgnored var autosaveGeneration = 0
  /// Project files a save was refused at (`ProjectWriteError.wouldReplaceRefusedFile` / another Reel): never
  /// written again this session.
  @ObservationIgnored var neverAutosave: Set<URL> = []
  /// The last project write queued: each write waits for the one before it, so they land in the order asked.
  @ObservationIgnored var writeChain: Task<ProjectWriteError?, Never>?
  /// The last save's whole course, fallbacks included (tests and quit await it).
  @ObservationIgnored public internal(set) var pendingSave: Task<Void, Never>?
  /// How many times the plan has been rebuilt (tests count it).
  @ObservationIgnored var replanCount = 0
  /// The header's Reel name is a text field (`beginRenameReel`) until it's committed or cancelled.
  public internal(set) var editingReelName = false
  /// What the rename field holds while it's open.
  public internal(set) var reelNameDraft = ""
  /// ⌘E asked for while a rename's move was in flight: the sheet opens once it lands (tests await it).
  @ObservationIgnored var pendingExportRequest: Task<Void, Never>?
  /// Committed renames whose move landed under a modal: their name change waits for it to close.
  @ObservationIgnored var heldRenameLands: [@MainActor () -> Void] = []
  /// The Reel's file being renamed to follow its name (`EditorModel+Rename.swift`), through the write chain; ends
  /// with where the file is after it. Saves asked for meanwhile wait for it (tests await it).
  @ObservationIgnored var pendingRename: Task<RenamedFile, Never>?
  /// Bumped by every file rename queued; only the newest clears `pendingRename`.
  @ObservationIgnored var renameGeneration = 0
  /// The last re-probe of an opened Reel's changed sources, or of clips Locate… relinked (tests await it).
  @ObservationIgnored public internal(set) var pendingReprobe: Task<Void, Never>?

  /// The last `show` handed to the preview (tests await it).
  @ObservationIgnored public internal(set) var pendingPreview: Task<Void, Never>?
  /// The last scheduled note dismissal (tests await it).
  @ObservationIgnored public internal(set) var pendingNoteDismissal: Task<Void, Never>?
  /// The last preview seek (tests await it).
  @ObservationIgnored public internal(set) var pendingSeek: Task<Void, Never>?
  /// Bumped by every preview request; an older request that wakes up late stands down.
  @ObservationIgnored var previewGeneration = 0
  /// Bumped by every peek; a scrub player whose asset arrives after a newer peek isn't shown.
  @ObservationIgnored var peekGeneration = 0
  /// Makes the queued sprites, `EditorModel.spriteWorkers` at a time (tests await it).
  @ObservationIgnored var spriteWorker: Task<Void, Never>?
  /// The `stripSpriteSources` the watcher last asked for (`watchStripSources`); nil after a reset, so the next
  /// Reel asks even when its sources are the same.
  @ObservationIgnored var stripSourcesAsked: [SourceRef]?
  /// When the latest import began; the §10 timings (probes landed, sprites ready) are logged against it.
  @ObservationIgnored var importStarted: ContinuousClock.Instant?
  /// The same start, for the `strip: N posters ready` line (§10 strip with posters); cleared once it's logged.
  @ObservationIgnored var postersStarted: ContinuousClock.Instant?

  enum ProbeOutcome { case facts(ClipFacts), failed }

  public init(platform: any PlatformServices, media: any MediaServices, store: any ProjectStore, prefs: Prefs,
              clock: any Clock<Duration>, preview: any PreviewDriving) {
    self.platform = platform
    self.media = media
    self.store = store
    self.prefs = prefs
    self.clock = clock
    self.preview = preview
    preview.loop = prefs.loop
    preview.onTime = { [weak self] t in self?.previewTime(t) }
    preview.onEnd = { [weak self] in self?.previewEnded() }
    watchStripSources()
  }

  /// The Reel's assets don't die on the main actor (`Offload`): freeing a Reel's worth there froze it for seconds.
  isolated deinit {
    let cache = session.assetCache
    session.assetCache = [:]
    let players = scrub.takeAll() + (peekPlayer.map { [$0] } ?? [])
    Offload.release(items: players.compactMap(\.currentItem), also: (consume cache, players))
  }

  /// Clips in the Reel still waiting for their facts (probing, or a .mkv/.avi being prepared). Export waits for them.
  public var loadingClipIDs: Set<UUID> {
    Set(loading.filter { $0.value == .probing || $0.value == .preparing }.keys)
  }

  /// The file a clip plays from: the one URL the player, export and thumbnails use. Nil if it isn't known (missing).
  public func url(for clipID: UUID) -> URL? { session.resolved[clipID] }

  // MARK: notes

  /// Adds a note under the stage; it goes by itself after `NoteLine.lifetime` on `clock`.
  public func note(_ text: String, _ kind: Note.Kind = .quiet) {
    let added = Note(text: text, kind: kind)
    notes.append(added)
    // The deadline is read now, on the main actor; `sleep(for:)` would read the clock later, off it.
    let current: any Clock<Duration> = clock
    let elapsed = sleeper(until: NoteLine.lifetime, on: current)
    pendingNoteDismissal = Task { [weak self] in
      guard await elapsed.value else { return }
      self?.dismissNote(added.id)
    }
  }

  /// How far the Reel runs past 3:00, for the warning (§4.3.6): a Reel-format rule, nil for Original.
  public var overLimit: RationalTime? {
    guard let shown = draftReel ?? reel, shown.export.format == .reel else { return nil }
    return shown.overLimit(missing: missing)
  }

  public func dismissNote(_ id: UUID) { notes.removeAll { $0.id == id } }

  var exportRunning: Bool {
    if case .running = exportState { true } else { false }
  }

  /// §4.1 (v1 ruling): adding clips, opening a project and New Reel are refused while an export runs.
  func refuseDuringExport() -> Bool {
    guard exportRunning else { return false }
    note(Self.exportFirstNote)
    return true
  }

  static let exportFirstNote = "Finish or cancel the export first."

  /// Imports also wait while a modal is up (§4.10): the export sheet describes the Reel as it is. The same note for
  /// the sheet; the key map and the ffmpeg card refuse quietly.
  func refuseImport() -> Bool {
    if refuseDuringExport() { return true }
    guard modals.top != nil else { return false }
    if modals.contains(.exportSheet) { note(Self.exportFirstNote) }
    return true
  }

  // MARK: edits

  /// Applies `edit`; on success records the state before it (unless `record` is false), re-plans and schedules an
  /// autosave. An `EditError` leaves everything as it was, records nothing, and shows its note where it has one.
  /// Returns whether the edit applied.
  @discardableResult
  public func perform(_ edit: ReelEdit, coalesce: String?, record: Bool = true) -> Bool {
    // The export reads the Reel as it was when Export was pressed; nothing changes it, or is recorded, meanwhile.
    guard !exportRunning else { return false }
    if let id = Self.trimTarget(edit), loadingClipIDs.contains(id), let clip = reel?.clips.first(where: { $0.id == id }) {
      note("Wait for \(Self.fileName(clip)) to finish loading.")
      return false
    }
    do {
      try applyEdit(edit, coalesce: coalesce, record: record)
      return true
    } catch {
      if let sentence = Self.sentence(for: error) { note(sentence) }
      return false
    }
  }

  /// Trims and splits need the clip's real facts, so they wait while it loads (Task 26 review I2).
  static func trimTarget(_ edit: ReelEdit) -> UUID? {
    switch edit {
    case .split(let id, _), .setIn(let id, _), .setOut(let id, _), .resetIn(let id), .resetOut(let id): id
    default: nil
    }
  }

  static func fileName(_ clip: ReelClip) -> String {
    URL(filePath: clip.source.absolutePath, directoryHint: .notDirectory).lastPathComponent
  }

  /// `perform` without the note: for callers (import) that word the failure themselves.
  func applyEdit(_ edit: ReelEdit, coalesce: String?, record: Bool) throws(EditError) {
    guard let current = reel else { throw .unknownClip }
    let next = try apply(edit, to: current)  // apply first: History has no way to drop a step
    if record { history.record(current, selection, coalesce: coalesce) }
    reel = next
    selection = Self.carried(selection, from: current, to: next)
    if anchor.map({ next.index(of: $0) == nil }) ?? false { anchor = selection.primary }
    if case .relink(let id, let source, _) = edit { noteRelink(id, source) }
    carryResolved(from: current, to: next)
    pruneLoading()
    let planBefore = plan
    replan()
    if record { _ = followPrimary() }
    // A file name or folder from the export sheet leaves the plan as it was: no preview rebuild per keystroke.
    if case .setExport = edit, plan == planBefore {
      preview.muted = next.export.removeAudio
    } else {
      refreshPreview(after: edit)
    }
    scheduleAutosave()
  }

  /// A clip new to the Reel (a split's second half) plays from the same file as the clip it came from.
  private func carryResolved(from old: Reel, to new: Reel) {
    for clip in new.clips where session.resolved[clip.id] == nil {
      if let twin = old.clips.first(where: { $0.source == clip.source && session.resolved[$0.id] != nil }) {
        session.resolved[clip.id] = session.resolved[twin.id]
      }
    }
  }

  /// `loading` covers the clips in the Reel: entries for clips that left go, and clips that came back (undo, redo)
  /// while their probe still runs show it again.
  func pruneLoading() {
    let present = Set(reel?.clips.map(\.id) ?? [])
    loading = loading.filter { present.contains($0.key) }
    for (id, state) in session.inFlight where present.contains(id) { loading[id] = state }
  }

  static func sentence(for error: EditError) -> String? {
    switch error {
    case .splitTooCloseToEdge: "Too close to the clip's edge to split."
    case .spanTooShort, .crossesHandle, .unknownClip, .emptyInsert, .unsupportedTiming: nil
    }
  }

  /// The selection after an edit: ids that went are dropped; a primary that went passes to the clip that took its
  /// place (the next one), else the one before it, else nothing.
  static func carried(_ sel: Selection, from old: Reel, to new: Reel) -> Selection {
    let present = Set(new.clips.map(\.id))
    var out = Selection(primary: sel.primary, all: sel.all.intersection(present))
    guard let primary = sel.primary, !present.contains(primary) else { return out }
    guard let oldIndex = old.index(of: primary), !new.clips.isEmpty else { return Selection() }
    let goneBefore = old.clips[..<oldIndex].filter { !present.contains($0.id) }.count
    let next = new.clips[min(oldIndex - goneBefore, new.clips.count - 1)].id
    out.primary = next
    if out.all.isEmpty { out.all = [next] } else { out.all.insert(next) }
    return out
  }

  public func undo() {
    guard !exportRunning else { return }
    dropDeckPress()
    guard let current = reel, let step = history.undo(current: (current, selection)) else { return }
    restore(step, over: current)
  }

  public func redo() {
    guard !exportRunning else { return }
    dropDeckPress()
    guard let current = reel, let step = history.redo(current: (current, selection)) else { return }
    restore(step, over: current)
  }

  /// Undo and redo bring back the Reel and the selection, but never the export settings (Task 13 ruling).
  private func restore(_ step: (Reel, Selection), over current: Reel) {
    var restored = step.0
    let sel = step.1
    restored.export = current.export
    reel = restored
    selection = sel
    anchor = sel.primary
    pruneLoading()
    reconcileProbes()
    replan()
    _ = followPrimary()
    refreshPreview(after: nil)
    if restored.name != current.name { followRenamed(restored.name) }  // the file follows the name (§6.1)
    scheduleAutosave()
  }

  /// Puts probe results that landed while their tile was out of the Reel (or before the snapshot was taken) back
  /// in, without recording: relinks are applied again, facts are applied, failed tiles leave.
  private func reconcileProbes() {
    guard let current = reel else { return }
    var failed: Set<UUID> = []
    for clip in current.clips {
      // A relink made without an undo step (Locate…, a changed source) holds in every snapshot (review I2).
      if let source = session.relinked[clip.id] {
        var facts = clip.facts
        if case .facts(let probed)? = session.probed[clip.id] { facts = probed }
        if clip.source != source || clip.facts != facts {
          try? applyEdit(.relink(clip.id, source, facts), coalesce: nil, record: false)
        }
        if missing.contains(clip.id) { continue }
        loading[clip.id] = session.inFlight[clip.id] ?? .ready
        continue
      }
      switch session.probed[clip.id] {
      case .facts(let facts)?:
        do {
          if clip.facts != facts { try applyEdit(.probed(clip.id, facts), coalesce: nil, record: false) }
          loading[clip.id] = .ready
        } catch {
          // The facts can't join this Reel (`.unsupportedTiming`): refused like an unplayable file (review M1).
          session.probed[clip.id] = .failed
          failed.insert(clip.id)
          if let sentence = Self.failureSentence(nil, fileName: Self.fileName(clip)) { note(sentence, .error) }
        }
      case .failed?: failed.insert(clip.id)
      case nil: break
      }
    }
    if !failed.isEmpty { try? applyEdit(.delete(failed), coalesce: nil, record: false) }
  }

  public func endGesture() { history.endGesture() }

  func replan() {
    replanCount += 1
    plan = reel.map { Planner.plan($0, missing: missing) }
    if draftReel != nil { refreshDraft() }
  }

  // MARK: selection

  /// A plain click selects `id` alone; `extend` (Shift) selects the run from the anchor to `id`; `toggle` (⌘) adds
  /// or removes `id`.
  public func select(_ id: UUID, extend: Bool, toggle: Bool) {
    guard let reel, let index = reel.index(of: id) else { return }
    if toggle {
      if selection.all.contains(id) {
        selection.all.remove(id)
        if selection.primary == id {
          selection.primary = reel.clips.first { selection.all.contains($0.id) }?.id
        }
      } else {
        selection.all.insert(id)
        selection.primary = id
      }
      anchor = selection.primary
    } else if extend, let from = (anchor ?? selection.primary).flatMap(reel.index(of:)) {
      selection.all = Set(reel.clips[min(from, index)...max(from, index)].map(\.id))
      selection.primary = id
    } else {
      selection = Selection(primary: id, all: [id])
      anchor = id
    }
  }

  public func selectAll() {
    guard let reel, !reel.clips.isEmpty else { return }
    selection.all = Set(reel.clips.map(\.id))
    if selection.primary == nil { selection.primary = reel.clips.first?.id }
  }

  /// Esc: back to the primary clip alone.
  public func collapseSelection() {
    selection.all = selection.primary.map { [$0] } ?? []
    anchor = selection.primary
  }
}

/// A task that ends (true) once `d` has passed on `clock`, counted from this call; false if it was cancelled.
func sleeper(until d: Duration, on clock: some Clock<Duration>) -> Task<Bool, Never> {
  let deadline = clock.now.advanced(by: d)
  return Task {
    do {
      try await clock.sleep(until: deadline, tolerance: nil)
      return true
    } catch {
      return false
    }
  }
}
