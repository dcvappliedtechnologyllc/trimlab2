import AVFoundation
import Foundation
import TrimlabMedia
import TrimlabModel

/// The open Reel's session caches: everything `reset` forgets when a Reel is opened or closed.
struct Session {
  /// Tells a load that lands after a reset that its session is gone.
  let id = UUID()
  /// The file each clip plays from, by clip id: the dropped URL, the resolved one on open, the new one on relink.
  var resolved: [UUID: URL] = [:]
  /// Probes still running, by clip id, with the state their tile shows (it may be undone away meanwhile).
  var inFlight: [UUID: LoadState] = [:]
  /// Facts every probe of this session returned, by clip id: an undo or redo can bring back a snapshot taken while
  /// the tile still had its placeholder facts (or a tile whose probe failed), and this puts it right.
  var probed: [UUID: EditorModel.ProbeOutcome] = [:]
  /// Sources relinked without an undo step (Locate…, a changed source on reopen), by clip id: an undo or redo that
  /// brings back an older snapshot gets them again, so the file and `url(for:)` agree.
  var relinked: [UUID: SourceRef] = [:]
  /// Loaded assets by file, kept for the Reel's life (§5.3): split halves and repeats share one.
  var assetCache: [URL: AVURLAsset] = [:]
  /// Asset loads in flight, by file: concurrent preview refreshes (one per probe that lands during an import)
  /// share one load instead of each making an `AVURLAsset` that is then thrown away.
  var assetLoads: [URL: Task<AVURLAsset?, Never>] = [:]
  /// Failed attempts per sprite: one retry is allowed on a later request, then it isn't asked for again.
  var spriteFailures: [SourceRef: Int] = [:]
  /// Failed attempts per deck fetch: one retry on a later request, then it isn't asked for again.
  var deckFailures: [DeckFetch: Int] = [:]
  /// Posters and sprites waiting their turn, in strip order, with the file each is made from. Workers take posters
  /// before sprites, and tiles on screen before tiles off it (`takeStripJob`).
  var stripQueue: [StripJob] = []
  /// Sources whose poster has been asked for (landed, failed or queued): one try each.
  var postersAsked: Set<SourceRef> = []
  /// A ⌥← / ⌥→ move has started a gesture that its key-up (or a resign) has yet to end.
  var moveKeyHeld = false
  /// The last save failed (not refused): its note isn't shown again until a save succeeds.
  var saveFailing = false
  /// Saves in a row that failed (`ProjectWriteError.failed`); the second falls back to Movies.
  var writeFailures = 0
  /// Clips opened with `needsProbe` whose probe hasn't landed yet (missing ones included): saved flagged again.
  var unprobed: Set<UUID> = []
  /// Clips probing again with real stored facts (a changed source, a located file): never flagged `needsProbe`.
  var reprobing: Set<UUID> = []
  /// .mkv and .avi files refused for want of ffmpeg while its card is up: they come in if a recheck finds it.
  var ffmpegPending: [URL] = []
  /// The Reel was renamed before it had a file: its first file is named after it, not the first clip's folder.
  var renamed = false
}

extension EditorModel {
  // MARK: reels

  /// Saves the Reel, closes it and shows the empty state.
  public func newReel() {
    guard !refuseDuringExport() else { return }
    commitOpenRename()
    saveNow()
    reset(to: nil, projectURL: nil)
  }

  /// Opens a `.trimlab`, replacing the open Reel (saved first, so no confirm). The stored facts draw at once; sources
  /// resolve and changed ones re-probe in the background (`resolveOpened`). A file that can't be opened leaves the
  /// open Reel as it was, with a note.
  public func open(project url: URL) { openProject(url, keepingBatch: nil) }

  /// `open(project:)`; `batch` is the import batch doing the opening (a drop of a project plus movies), which goes
  /// on to append its movies, so the reset doesn't cancel it.
  @discardableResult
  func openProject(_ url: URL, keepingBatch batch: UUID?) -> Bool {
    guard !refuseDuringExport() else { return false }
    commitOpenRename()
    saveNow()
    var opened: Reel
    do {
      if Self.sameFile(url, projectURL), let reel {
        // The open Reel's own file: the write just queued may not have landed, so it opens from what it holds.
        opened = try ProjectCodec.decode(ProjectCodec.encode(Self.forSaving(reel, unprobed: placeholderClipIDs)))
      } else {
        opened = try ProjectCodec.decode(try store.read(url))
      }
    } catch let error as ProjectError {
      note(error.message, .error)
      return false
    } catch {
      note(ProjectError.unreadable.message, .error)
      return false
    }
    // Clips saved while still loading: their facts are placeholders, probed again before anything trusts them.
    var placeholders: Set<UUID> = []
    for i in opened.clips.indices where opened.clips[i].extra[Self.needsProbeKey] != nil {
      placeholders.insert(opened.clips[i].id)
      opened.clips[i].extra[Self.needsProbeKey] = nil
    }
    reset(to: opened, projectURL: url, keepingBatch: batch)
    session.unprobed = placeholders
    platform.noteRecent(url)
    resolveOpened(opened, projectFolder: url.deletingLastPathComponent(), placeholders: placeholders)
    // A Reel just opened is the set of cache entries to keep (Task 21 carry).
    let refs = opened.clips.map(\.source)
    let media = self.media
    pendingPrune = Task { await media.pruneCache(keeping: refs) }
    return true
  }

  /// Replaces the Reel and forgets the old one's session state. Running import batches are cancelled, except `batch`.
  func reset(to newReel: Reel?, projectURL url: URL?, keepingBatch batch: UUID? = nil) {
    for (id, task) in importTasks where id != batch { task.cancel() }
    importTasks = importTasks.filter { $0.key == batch }
    cancelAutosave()  // the old Reel was saved by the caller; its debounce means nothing now
    closeExportSheet()  // the sheet described the old Reel
    if modals.top == nil { focusedControl = nil }  // a handed-back `?` mustn't grab focus when it shows again
    pendingReprobe = nil
    editingReelName = false
    pendingRename = nil  // a rename still queued goes on (its file is known); the new Reel's saves don't wait for it
    heldRenameLands = []  // the closed Reel's name changes that waited for a modal
    pendingExportRequest?.cancel()  // a ⌘E waiting on the closed Reel's rename
    pendingExportRequest = nil
    // The old session holds the Reel's assets: they go off the main actor (`Offload`).
    let cache = session.assetCache
    session = Session()
    reel = newReel
    projectURL = url
    history.reset()
    selection = Selection()
    anchor = nil
    loading = [:]
    missing = []
    endPeek()
    // The old Reel's assets and the scrub players on them go together, off the main actor (`Offload`); the
    // preview's item goes when the empty plan is installed.
    let players = scrub.takeAll()
    Offload.release(items: players.compactMap(\.currentItem), also: (consume cache, players))
    spriteWorker?.cancel()
    spriteWorker = nil
    stripSourcesAsked = nil
    spritePending = []
    stripSprites = [:]
    stripPosters = [:]
    endStripInteraction()
    stripZoom = .fit
    stripScrollX = 0
    for task in deckFetches.values { task.cancel() }
    deckFetches = [:]
    pendingDeckMedia = nil
    deckPending = []
    deckPeaks = [:]
    deckKeyframes = [:]
    dropDeckPress()
    resetDeckZoom()
    if playState != .paused { preview.setRate(0) }
    playhead = .zero
    playState = .paused
    replan()
    refreshPreview(after: nil)
  }

  /// The export settings a new Reel starts with, from the prefs.
  var defaultExport: ExportSpec {
    ExportSpec(format: prefs.format, cut: prefs.cut, quality: prefs.quality, removeAudio: prefs.removeAudioDefault,
                folder: exportFolderOverride)
  }
}
