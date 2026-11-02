import Foundation
import TrimlabMedia
import TrimlabModel

/// §4.1. Drops, the Open panel, Finder and the Dock all come in through `importURLs`.
extension EditorModel {
  /// How many files are probed at once (§4.1).
  static let probeLimit = 4

  /// Adds movies (and the top level of folders) to the Reel: at `gap` (a strip drop) or at the end. A `.trimlab`
  /// opens instead. The tiles appear as one undo step and fill in as their probes land; the returned task ends when
  /// every probe has settled. New Reel and opening a project cancel it.
  @discardableResult
  public func importURLs(_ urls: [URL], at gap: Int?) -> Task<Void, Never> {
    guard !refuseImport() else { return Task {} }  // first: a refused drop shows nothing else
    let id = UUID()
    let task = Task {
      await self.runImport(urls, at: gap, batch: id)
      self.importTasks[id] = nil
    }
    importTasks[id] = task
    return task
  }

  static func needsRemux(_ url: URL) -> Bool { Prober.remuxExtensions.contains(url.pathExtension.lowercased()) }

  private func runImport(_ urls: [URL], at gap: Int?, batch: UUID) async {
    let found = await Self.classify(urls, store: store)  // folder listing off the main actor
    guard !Task.isCancelled, !refuseImport() else { return }
    var movies = found.movies
    let skipped = found.skipped
    if skipped > 0 { note("Skipped \(skipped) \(skipped == 1 ? "file" : "files") trimlab can't open.") }
    if let project = found.project { openProject(project, keepingBatch: batch) }

    // Without ffmpeg, .mkv and .avi are refused before they get a tile, and the card says why.
    if movies.contains(where: Self.needsRemux), !media.ffmpegAvailable() {
      openFFmpegCard(refusing: movies.filter(Self.needsRemux))
      movies.removeAll(where: Self.needsRemux)
    }
    guard !movies.isEmpty else { return }
    await addAndProbe(movies, at: gap)
  }

  struct Found: Sendable {
    var movies: [URL] = []
    var project: URL?
    var skipped = 0
  }

  /// Movies (folders expanded one level), the first `.trimlab`, and how many files can't be opened. Hidden files,
  /// subfolders and `.trimlab` files inside a dropped folder are passed over without counting; so is an empty folder.
  @concurrent
  static func classify(_ urls: [URL], store: any ProjectStore) async -> Found {
    var found = Found()
    for url in urls {
      let ext = url.pathExtension.lowercased()
      if ext == "trimlab" {
        if found.project == nil { found.project = url }
      } else if Prober.supportedExtensions.contains(ext) {
        found.movies.append(url)
      } else if store.isFolder(url) {
        for name in store.list(url).sorted() where !name.hasPrefix(".") {
          let child = url.appending(path: name, directoryHint: .notDirectory)
          let childExt = child.pathExtension.lowercased()
          if Prober.supportedExtensions.contains(childExt) {
            found.movies.append(child)
          } else if childExt != "trimlab", !store.isFolder(child) {
            found.skipped += 1
          }
        }
      } else {
        found.skipped += 1
      }
    }
    return found
  }

  /// One file to probe for one clip: an import's tile, a changed or placeholder source on reopen, a located file.
  struct ProbeJob: Sendable {
    let id: UUID
    let url: URL
    let ref: SourceRef
  }

  /// What a tile shows while its file is probed: `.preparing` for a .mkv/.avi being remuxed.
  static func loadState(for url: URL) -> LoadState { needsRemux(url) ? .preparing : .probing }

  /// The one probe pipeline (§4.1): `media.probe` over `jobs`, `probeLimit` at a time, each result handed to
  /// `settle` on the main actor as it lands. Once the calling task is cancelled nothing new starts.
  func runProbes(_ jobs: [ProbeJob], settle: (ProbeJob, Result<ClipFacts, any Error>) -> Void) async {
    let media = self.media
    await Self.limited(jobs, each: { job in
      do {
        return (job, .success(try await media.probe(job.url, ref: job.ref)))
      } catch {
        return (job, Result<ClipFacts, any Error>.failure(error))
      }
    }, settle: { (out: (ProbeJob, Result<ClipFacts, any Error>)) in settle(out.0, out.1) })
  }

  private func addAndProbe(_ urls: [URL], at gap: Int?) async {
    let media = self.media
    let began = ContinuousClock.now
    let items = await Self.limited(urls) { await media.importItem($0) }
    guard await holdWhileAModalIsUp() else { return }  // the key map or export sheet may have opened meanwhile
    guard !refuseDuringExport() else { return }  // an export may have started meanwhile
    let ordered = ImportOrder.sorted(items)
    guard let first = ordered.first?.url else { return }

    // Relative paths only against a project file's folder once there is one; every save rebases them
    // (`Reel.rebasingRelativePaths(to:)`).
    let projectFolder = projectURL?.deletingLastPathComponent()

    var jobs: [ProbeJob] = []
    var tiles: [ReelClip] = []
    for item in ordered {
      do {
        let ref = try media.sourceRef(item.url, projectFolder: projectFolder)
        let tile = ReelClip.make(source: ref, facts: Self.placeholder(item), framing: prefs.defaultFraming)
        tiles.append(tile)
        jobs.append(ProbeJob(id: tile.id, url: item.url, ref: ref))
      } catch {
        noteFailure(error, url: item.url)
      }
    }
    guard !tiles.isEmpty else { return }

    if reel == nil {
      var fresh = Reel.empty(name: first.deletingLastPathComponent().lastPathComponent)
      fresh.export = defaultExport
      reel = fresh
    }
    for job in jobs {
      session.resolved[job.id] = job.url
      session.inFlight[job.id] = Self.loadState(for: job.url)
    }
    do {
      try applyEdit(.insert(tiles, at: gap ?? reel?.clips.count ?? 0), coalesce: nil, record: true)
    } catch {
      for job in jobs {
        session.inFlight[job.id] = nil
        session.resolved[job.id] = nil
        noteFailure(nil, url: job.url)
      }
      return
    }
    selection = Selection(primary: tiles[0].id, all: [tiles[0].id])
    anchor = tiles[0].id
    if followPrimary() { seekPreview() }  // the selection rule, for the first new tile

    importStarted = began
    postersStarted = began
    await runProbes(jobs) { self.settle($0, $1) }
    MediaLog.note("import: \(jobs.count) clips probed in \(Self.millis(since: began)) ms")  // §10: load 18 assets
    // The batch has settled: the cache is pruned to its limit with the Reel's clips kept (§4.6). Off the main actor.
    guard !Task.isCancelled, let reel else { return }
    await media.pruneCache(keeping: reel.clips.map(\.source))
  }

  /// A batch whose dates were being read when the key map or the export sheet opened waits for it to close before its
  /// tiles land (§4.10: the sheet describes the Reel as it is; M-6). The ffmpeg card doesn't hold it: a batch opens
  /// that itself. False once the batch was cancelled (New Reel, open) meanwhile. A running export is answered by the
  /// caller's `refuseDuringExport`, as before. Polled: the wait is a user's modal, not a hot path.
  private func holdWhileAModalIsUp() async -> Bool {
    while !Task.isCancelled {
      guard modals.contains(.keyMap) || modals.contains(.exportSheet), !exportRunning else { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  /// Milliseconds since `start`, to one decimal (the §10 timing lines).
  static func millis(since start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%.1f", ms)
  }

  /// Placeholder facts: a 1 s tile until the probe lands (its trim is then the whole source).
  static func placeholder(_ item: ImportItem) -> ClipFacts {
    ClipFacts(duration: RationalTime(1, 1), frameDuration: RationalTime(1, 30), displayWidth: 1080,
              displayHeight: 1920, rotation: 0, videoCodec: "", hasAudio: false, hdr: .sdr, bitrate: 0,
              captureDate: item.captureDate, needsRemux: needsRemux(item.url))
  }

  private func settle(_ job: ProbeJob, _ result: Result<ClipFacts, any Error>) {
    guard !Task.isCancelled else { return }  // the batch was cancelled (New Reel, open): its results mean nothing
    session.inFlight[job.id] = nil
    let present = reel?.index(of: job.id) != nil
    switch result {
    case .success(let facts):
      session.probed[job.id] = .facts(facts)
      guard present else { return }  // undone meanwhile: kept in `probed` for a redo
      do {
        try applyEdit(.probed(job.id, facts), coalesce: nil, record: false)
        loading[job.id] = .ready
      } catch {
        // `.unsupportedTiming`: the plan can't hold this clip's times with the others; it's left out (§4.1 note).
        fail(job, present: true, error: nil)
      }
    case .failure(let error):
      if error is CancellationError { return }
      if (error as? ImportError) == .needsFFmpeg { openFFmpegCard(refusing: present ? [job.url] : []) }
      fail(job, present: present, error: error)
    }
  }

  /// The tile leaves the Reel without an undo step, so the batch's step undoes to the Reel before the drop.
  private func fail(_ job: ProbeJob, present: Bool, error: (any Error)?) {
    session.probed[job.id] = .failed
    loading[job.id] = nil
    if present { try? applyEdit(.delete([job.id]), coalesce: nil, record: false) }
    noteFailure(error, url: job.url)
  }

  private func noteFailure(_ error: (any Error)?, url: URL) {
    if let sentence = Self.failureSentence(error, fileName: url.lastPathComponent) { note(sentence, .error) }
  }

  /// The one place a file that couldn't be added becomes words (§4.1). `ImportError` → its `sentence(ext:)`;
  /// `ProbeError` → its own; anything else (or nil: a refused timing, an unreadable file) → "can't play". Nil (no
  /// note) for a cancel, and for `needsFFmpeg`, whose card says it.
  static func failureSentence(_ error: (any Error)?, fileName: String) -> String? {
    if error is CancellationError { return nil }
    if let e = error as? ImportError {
      return e == .needsFFmpeg ? nil : e.sentence(ext: (fileName as NSString).pathExtension.lowercased())
    }
    return ((error as? ProbeError) ?? .unplayable).sentence(fileName: fileName)
  }

  // MARK: bounded concurrency

  /// Runs `each` over `inputs`, `probeLimit` at a time, handing each result to `settle` on the main actor as it lands.
  /// Once the calling task is cancelled nothing new starts.
  static func limited<In: Sendable, Out: Sendable>(
    _ inputs: [In], each: @escaping @Sendable (In) async -> Out, settle: (Out) -> Void
  ) async {
    await withTaskGroup(of: Out.self) { group in
      var next = inputs.makeIterator()
      for _ in 0..<probeLimit {
        guard let input = next.next() else { break }
        guard group.addTaskUnlessCancelled(operation: { await each(input) }) else { break }
      }
      for await out in group {
        settle(out)
        if Task.isCancelled { continue }  // drain what's running, start nothing
        if let input = next.next() { _ = group.addTaskUnlessCancelled { await each(input) } }
      }
    }
  }

  /// `limited`, collecting the results in input order.
  static func limited<In: Sendable, Out: Sendable>(
    _ inputs: [In], _ each: @escaping @Sendable (In) async -> Out
  ) async -> [Out] {
    var results: [(Int, Out)] = []
    await limited(Array(inputs.enumerated()), each: { pair in (pair.offset, await each(pair.element)) },
                  settle: { results.append($0) })
    return results.sorted { $0.0 < $1.0 }.map(\.1)
  }
}

// MARK: - the ffmpeg card

/// §4.1: without ffmpeg, .mkv and .avi files are refused and a card says how to install it; the app rechecks when the
/// window becomes key again (`recheckFFmpeg`), and the refused files come in once it's there.
extension EditorModel {
  /// The card's controls, in Tab order.
  static let ffmpegCopy = "ffmpeg-copy"
  static let ffmpegClose = "ffmpeg-close"

  public var ffmpegCardOpen: Bool { modals.contains(.ffmpegCard) }

  /// Opens the card (or keeps it open) and remembers `urls` for a recheck that finds ffmpeg.
  func openFFmpegCard(refusing urls: [URL]) {
    if !ffmpegCardOpen { focusedControl = nil }
    modals.open(.ffmpegCard)
    modals.register([Self.ffmpegCopy, Self.ffmpegClose], for: .ffmpegCard)
    for url in urls where !session.ffmpegPending.contains(url) { session.ffmpegPending.append(url) }
  }

  /// Called by the app when the window becomes key: with the card up and ffmpeg now found, the card closes and the
  /// files it refused are added at the end of the Reel. Nil when there was nothing to do (no card, still no ffmpeg);
  /// otherwise the import (tests await it).
  @discardableResult
  public func recheckFFmpeg() -> Task<Void, Never>? {
    guard ffmpegCardOpen, media.ffmpegAvailable() else { return nil }
    let urls = session.ffmpegPending
    closeFFmpegCard()
    return urls.isEmpty ? Task {} : importURLs(urls, at: nil)
  }

  /// Close or Esc: the refused files are dropped.
  public func closeFFmpegCard() {
    guard ffmpegCardOpen else { return }
    focusedControl = modals.close(.ffmpegCard)
    session.ffmpegPending = []
  }

  /// Copy: `brew install ffmpeg-full` on the pasteboard.
  public func copyFFmpegCommand() { platform.copy(FFmpegCard.command) }

  func activateFFmpegCardControl(_ id: String) {
    switch id {
    case Self.ffmpegCopy: copyFFmpegCommand()
    case Self.ffmpegClose: closeFFmpegCard()
    default: break
    }
  }
}
