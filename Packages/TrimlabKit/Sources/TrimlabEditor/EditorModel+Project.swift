import Foundation
import TrimlabMedia
import TrimlabModel

/// §8.2. The `.trimlab` file: autosave, reopen, missing clips and Locate…, changed sources.
extension EditorModel {
  /// How long after the last edit the Reel is saved.
  static let autosaveDelay: Duration = .seconds(1)

  /// Written into a clip's `extra` when it's saved while its probe is still running: its facts are placeholders, so
  /// a reopen probes it again (with `.probed` semantics) instead of trusting them (Phase 4 review C1).
  nonisolated static let needsProbeKey = "needsProbe"

  static let fallbackNote = "Saved the Reel in Movies › trimlab 2: the clips' folder is read-only."

  /// The longest quit waits for the last write.
  static let quitSaveLimit: Duration = .seconds(3)

  // MARK: autosave

  /// Saves the Reel `autosaveDelay` after the last call, on `clock`. Each call restarts the wait.
  func scheduleAutosave() {
    cancelAutosave()
    guard reel != nil else { return }
    let generation = autosaveGeneration
    // The deadline is read now, on the main actor, as `note` does.
    let current: any Clock<Duration> = clock
    let elapsed = sleeper(until: Self.autosaveDelay, on: current)
    autosaveSleep = elapsed
    pendingAutosave = Task { [weak self] in
      guard await elapsed.value, let self, self.autosaveGeneration == generation else { return }
      await self.saveNow().value
    }
  }

  /// Drops a waiting debounce; its task wakes and stands down.
  func cancelAutosave() {
    autosaveGeneration += 1
    autosaveSleep?.cancel()
    autosaveSleep = nil
  }

  /// Clips whose facts are placeholders: an import's tiles still probing, and clips opened flagged and not probed
  /// yet. A clip re-probing because its source changed (or was located) keeps real stored facts: not flagged.
  var placeholderClipIDs: Set<UUID> {
    loadingClipIDs.subtracting(session.reprobing).union(session.unprobed)
  }

  /// Whether `a` and `b` name the same file, however they're spelled (`..`, symlinks).
  static func sameFile(_ a: URL, _ b: URL?) -> Bool {
    guard let b else { return false }
    return a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
  }

  /// Clips that count toward the first file: their probes have landed (`.ready`).
  private var readyClipCount: Int {
    reel?.clips.count(where: { loading[$0.id] == .ready }) ?? 0
  }

  /// Saves the Reel (New Reel, open, quit, window close, and the debounce). A Reel without a file yet gets one once
  /// two of its clips are ready; after that it's written to the same file every time, whatever it holds. The write
  /// runs off the main actor, after every write queued before it; the returned task ends once it has landed (and
  /// any fallback it led to).
  @discardableResult
  public func saveNow() -> Task<Void, Never> {
    cancelAutosave()
    guard let reel else { return Task {} }
    if let renaming = pendingRename { return save(reel, after: renaming, unprobed: placeholderClipIDs) }
    if let projectURL { return save(reel, to: projectURL) }
    guard readyClipCount >= 2, let first = reel.clips.first else { return Task {} }  // a one-clip trim leaves no file
    let (url, fellBack) = newProjectLocation(firstClip: first, named: session.renamed ? reel.name : nil)
    return save(reel, to: url, makeFolder: fellBack, announce: fellBack ? Self.fallbackNote : nil)
  }

  /// Waits for `work` or for `limit` on `clock`, whichever ends first. (A task group would wait for stuck work too:
  /// its children can't be abandoned.)
  func waitAtMost(_ limit: Duration, for work: Task<Void, Never>) async {
    let current: any Clock<Duration> = clock
    let timer = sleeper(until: limit, on: current)
    let (first, done) = AsyncStream<Void>.makeStream()
    Task { await work.value; done.yield() }
    Task { _ = await timer.value; done.yield() }
    for await _ in first { break }
    timer.cancel()
  }

  /// A save asked for while the Reel's file is being renamed (`EditorModel+Rename.swift`) waits for the rename, so
  /// it never goes to the old name. The Reel still open is then saved as it is by then; one closed meanwhile (New
  /// Reel, open) is saved as it was, carrying the name its file was moved for, wherever the file now is, with the
  /// clips that were still probing (`unprobed`, taken now: the reset forgets them) flagged `needsProbe`.
  private func save(_ reel: Reel, after renaming: Task<RenamedFile, Never>, unprobed: Set<UUID>) -> Task<Void, Never> {
    let done = Task {
      let renamed = await renaming.value
      if self.reel?.id == reel.id {
        await self.saveNow().value
        return
      }
      guard let url = renamed.url else { return }
      var last = reel
      if let name = renamed.movedFor { last.name = name }
      await self.save(last, to: url, closed: true, unprobed: unprobed).value
    }
    pendingSave = done
    return done
  }

  /// Everything one write needs, taken on the main actor and used off it.
  struct WriteJob: Sendable {
    let reel: Reel
    let unprobed: Set<UUID>
    let url: URL
    let makeFolder: Bool
  }

  /// Queues one write of `reel` at `url`. A file other than `projectURL` becomes the Reel's file at once (so a save
  /// made before this one lands goes to the same place); it's given back if the write fails, and when it lands it's
  /// noted as recent and `announce` is shown. A file a save was refused at is never written again. `closed`: the last
  /// save of a Reel already closed, which leaves `projectURL` (the open Reel's) alone; `unprobed`, its placeholder
  /// clips as they were (nil: the open Reel's now).
  private func save(_ reel: Reel, to url: URL, makeFolder: Bool = false, announce: String? = nil,
                    closed: Bool = false, unprobed: Set<UUID>? = nil) -> Task<Void, Never> {
    guard !neverAutosave.contains(url) else { return Task {} }
    let isNew = !closed && projectURL != url
    if isNew { projectURL = url }
    let job = WriteJob(reel: reel, unprobed: unprobed ?? placeholderClipIDs, url: url,
                       makeFolder: makeFolder)
    let previous = writeChain
    let store = self.store
    // Chained: each write starts after the one queued before it, so the newest save is the last to land.
    let write = Task { () -> ProjectWriteError? in
      _ = await previous?.value
      return await Self.write(job, store: store)
    }
    writeChain = write
    let done = Task {
      await self.landed(await write.value, reelID: reel.id, url: url, isNew: isNew, announce: announce)
    }
    pendingSave = done
    return done
  }

  /// Off the main actor: the flags, the relative paths (which resolve symlinks), the JSON and the atomic write
  /// (`F_FULLFSYNC`) all happen here.
  @concurrent
  nonisolated static func write(_ job: WriteJob, store: any ProjectStore) async -> ProjectWriteError? {
    let data = ProjectCodec.encode(forSaving(job.reel, unprobed: job.unprobed)
      .rebasingRelativePaths(to: job.url.deletingLastPathComponent()))
    do {
      if job.makeFolder { try store.makeFolder(job.url.deletingLastPathComponent()) }
      try store.write(data, to: job.url, reelID: job.reel.id)
      return nil
    } catch {
      return (error as? ProjectWriteError) ?? .failed("\(error)")
    }
  }

  /// The Reel as it's written: clips still waiting for their facts carry `needsProbeKey`.
  nonisolated static func forSaving(_ reel: Reel, unprobed: Set<UUID>) -> Reel {
    var out = reel
    for i in out.clips.indices where unprobed.contains(out.clips[i].id) {
      out.clips[i].extra[needsProbeKey] = .bool(true)
    }
    return out
  }

  /// A write has landed. Refused (a file this build can't open, or another Reel's): that file is never written
  /// again, and the Reel goes to the next free name beside it, with a note. Failed: one note per streak; a second
  /// failure in a row falls back to `~/Movies/trimlab 2/`. Nothing retries by itself beyond that.
  private func landed(_ failure: ProjectWriteError?, reelID: UUID, url: URL, isNew: Bool, announce: String?) async {
    let current = reel?.id == reelID ? reel : nil  // nil: that Reel has since been closed
    guard let failure else {
      if isNew { platform.noteRecent(url) }
      guard current != nil else { return }
      session.saveFailing = false
      session.writeFailures = 0
      if let announce { note(announce) }
      return
    }
    MediaLog.note("project: save to \(url.path) \(failure.logDetail)")
    let refused = failure == .wouldReplaceRefusedFile || failure == .wouldReplaceAnotherReel
    if refused { neverAutosave.insert(url) }
    guard let reel = current else {
      note(failure.message, .error)  // the closed Reel's last save: said plainly, nowhere to redirect it
      return
    }
    switch failure {
    case .wouldReplaceRefusedFile, .wouldReplaceAnotherReel:
      // A write queued before an earlier refusal already moved the Reel: that redirect stands, once.
      guard projectURL == url else { return }
      let folder = url.deletingLastPathComponent()
      let taken = Set(store.list(folder)).union(neverAutosave.map(\.lastPathComponent))
      let name = Naming.keepBoth(url.lastPathComponent, existing: taken)
      let why = failure == .wouldReplaceAnotherReel
        ? "\(url.lastPathComponent) belongs to another Reel."
        : "trimlab can't open the \(url.lastPathComponent) that's there."
      await save(reel, to: folder.appending(path: name, directoryHint: .notDirectory),
                 announce: "Saved as \(name): \(why)").value
    case .failed:
      session.writeFailures += 1
      if isNew, projectURL == url { projectURL = nil }  // a new file that didn't land isn't the Reel's yet
      let fallback = Naming.fallbackFolder
      if session.writeFailures >= 2,
         url.deletingLastPathComponent().standardizedFileURL != fallback.standardizedFileURL {
        session.writeFailures = 0
        let name = Naming.keepBoth(url.lastPathComponent, existing: Set(store.list(fallback)))
        await save(reel, to: fallback.appending(path: name, directoryHint: .notDirectory), makeFolder: true,
                   announce: Self.fallbackNote).value
        return
      }
      if !session.saveFailing { note(failure.message, .error) }
      session.saveFailing = true
    }
  }

  /// The first clip's folder and `<folder name>.trimlab` (then ` 2`, ` 3`), or the same name in
  /// `~/Movies/trimlab 2/` when that folder isn't writable. A Reel renamed before it had a file (`named`) is
  /// `<Reel name>.trimlab` there instead.
  private func newProjectLocation(firstClip: ReelClip, named: String?) -> (URL, fellBack: Bool) {
    let clipFolder = URL(filePath: firstClip.source.absolutePath, directoryHint: .notDirectory)
      .deletingLastPathComponent()
    let writable = store.isWritable(clipFolder)
    let folder = writable ? clipFolder : Naming.fallbackFolder
    let existing = Set(store.list(folder))
    let name = named.map { Naming.keepBoth("\($0).trimlab", existing: existing) }
      ?? Naming.projectFileName(folder: clipFolder, existing: existing)
    return (folder.appending(path: name, directoryHint: .notDirectory), !writable)
  }

  // MARK: reopen

  /// Why a file is probed again; it decides how the facts apply.
  enum ProbeReason: Sendable {
    /// Saved while still loading (`needsProbeKey`): applied as `.probed`, so an untouched trim takes the whole file.
    case placeholder
    /// Its size or date changed since the save: `.relink`, Out clamped to the new end.
    case relink
    /// Chosen with Locate… (or found by name beside the chosen file): `.relink`, Out clamped to the new end.
    case located
  }

  /// After `reset` to an opened Reel: the stored facts draw at once; each source is resolved (§7.1). A source that
  /// can't be found is missing; one that moved is relinked to where it is now; one saved while loading, or whose
  /// size or date changed, is probed again in the background.
  func resolveOpened(_ opened: Reel, projectFolder folder: URL, placeholders: Set<UUID>) {
    var jobs: [(ProbeJob, ProbeReason)] = []
    var moved: [ReelEdit] = []
    for clip in opened.clips {
      guard let found = media.resolve(clip, projectFolder: folder),
            let ref = try? media.sourceRef(found, projectFolder: folder) else {
        markMissing(clip.id)
        continue
      }
      session.resolved[clip.id] = found
      loading[clip.id] = .ready
      let job = ProbeJob(id: clip.id, url: found, ref: ref)
      if placeholders.contains(clip.id) {
        jobs.append((job, .placeholder))
      } else if ref.size != clip.source.size || ref.modified != clip.source.modified {
        jobs.append((job, .relink))
      } else if ref.absolutePath != clip.source.absolutePath {
        moved.append(.relink(clip.id, ref, clip.facts))
      }
    }
    applyUnrecorded(moved)
    replan()
    refreshPreview(after: nil)
    reprobe(jobs)
  }

  func markMissing(_ id: UUID) {
    missing.insert(id)
    session.resolved[id] = nil
    if reel?.index(of: id) != nil { loading[id] = .missing }
  }

  /// Probes `jobs` through the import pipeline (`probeLimit` at a time); New Reel and open cancel it.
  @discardableResult
  func reprobe(_ jobs: [(ProbeJob, ProbeReason)]) -> Task<Void, Never> {
    guard !jobs.isEmpty else { return Task {} }
    var reasons: [UUID: ProbeReason] = [:]
    for (job, reason) in jobs {
      reasons[job.id] = reason
      if reason != .placeholder { session.reprobing.insert(job.id) }
      session.inFlight[job.id] = Self.loadState(for: job.url)
      loading[job.id] = Self.loadState(for: job.url)
    }
    let id = UUID()
    let task = Task {
      await self.runProbes(jobs.map(\.0)) { job, result in
        self.settleReprobe(job, reasons[job.id] ?? .relink, result)
      }
      self.importTasks[id] = nil
    }
    importTasks[id] = task
    pendingReprobe = task
    return task
  }

  /// New facts apply without an undo step; an Out past the new end is pulled back with a note. A probe that fails
  /// leaves the clip in the Reel, missing.
  private func settleReprobe(_ job: ProbeJob, _ reason: ProbeReason, _ result: Result<ClipFacts, any Error>) {
    guard !Task.isCancelled else { return }
    if case .failure(let error) = result, error is CancellationError { return }
    session.inFlight[job.id] = nil
    session.reprobing.remove(job.id)
    let before = reel?.clips.first { $0.id == job.id }
    switch result {
    case .success(let facts):
      session.probed[job.id] = .facts(facts)
      session.unprobed.remove(job.id)
      guard let before else { return }  // removed meanwhile: an undo brings it back with these facts
      do {
        if reason == .placeholder {
          try applyEdit(.probed(job.id, facts), coalesce: nil, record: false)
          if job.ref != before.source { try applyEdit(.relink(job.id, job.ref, facts), coalesce: nil, record: false) }
        } else {
          try applyEdit(.relink(job.id, job.ref, facts), coalesce: nil, record: false)
        }
      } catch {
        reprobeFailed(job, error: nil)
        return
      }
      loading[job.id] = .ready
      if reason != .placeholder, let after = reel?.clips.first(where: { $0.id == job.id }),
         after.outTime < before.outTime {
        let name = Self.fileName(after)
        note(reason == .located ? "\(name) is shorter; its Out moved to the new end."
                                : "\(name) changed; its Out moved to the new end.")
      }
    case .failure(let error):
      if (error as? ImportError) == .needsFFmpeg { openFFmpegCard(refusing: []) }
      reprobeFailed(job, error: error)
    }
  }

  private func reprobeFailed(_ job: ProbeJob, error: (any Error)?) {
    markMissing(job.id)
    replan()
    refreshPreview(after: nil)
    if let sentence = Self.failureSentence(error, fileName: job.url.lastPathComponent) { note(sentence, .error) }
  }

  /// `edits` (the relinks of sources that moved) applied to the Reel as one change, never an undo step. The caller
  /// re-plans and refreshes the preview once. An edit the Reel refuses is skipped.
  func applyUnrecorded(_ edits: [ReelEdit]) {
    guard var next = reel, !edits.isEmpty else { return }
    for edit in edits {
      guard let applied = try? apply(edit, to: next) else { continue }
      next = applied
      if case .relink(let id, let source, _) = edit { noteRelink(id, source) }
    }
    reel = next
    scheduleAutosave()
  }

  /// A clip now plays from `source`: `url(for:)` follows, and an undo or redo keeps it (`session.relinked`).
  func noteRelink(_ id: UUID, _ source: SourceRef) {
    session.resolved[id] = URL(filePath: source.absolutePath, directoryHint: .notDirectory)
    session.relinked[id] = source
  }

  // MARK: Locate…

  /// The inspector's Locate… for a missing clip: the Open panel (movies only); the chosen file relinks that clip, and
  /// every other missing clip whose file name is in the chosen folder relinks too. Each is then probed again. The
  /// returned task ends when those probes have settled.
  @discardableResult
  public func locate(_ id: UUID) -> Task<Void, Never> {
    let platform = self.platform
    return Task {
      let urls = await platform.openPanel(movies: true, projects: false)
      guard let chosen = urls.first else { return }
      await self.relinkMissing(id, to: chosen).value
    }
  }

  private func relinkMissing(_ id: UUID, to chosen: URL) -> Task<Void, Never> {
    guard let reel, missing.contains(id), let clip = reel.clips.first(where: { $0.id == id }) else { return Task {} }
    let folder = chosen.deletingLastPathComponent()
    var targets: [(UUID, URL)] = [(id, chosen)]
    for other in reel.clips where other.id != id && missing.contains(other.id) {
      if other.source.absolutePath == clip.source.absolutePath {
        targets.append((other.id, chosen))  // the same file (split halves, repeats)
        continue
      }
      let candidate = folder.appending(path: Self.fileName(other), directoryHint: .notDirectory)
      if store.exists(candidate) { targets.append((other.id, candidate)) }
    }
    let projectFolder = projectURL?.deletingLastPathComponent()
    var jobs: [(ProbeJob, ProbeReason)] = []
    for (target, url) in targets {
      guard let ref = try? media.sourceRef(url, projectFolder: projectFolder) else { continue }
      missing.remove(target)
      session.resolved[target] = url
      // A clip saved while loading was never probed: its facts are still placeholders (review C1).
      jobs.append((ProbeJob(id: target, url: url, ref: ref), session.unprobed.contains(target) ? .placeholder : .located))
    }
    return reprobe(jobs)
  }
}
