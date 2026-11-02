import Foundation
import TrimlabMedia
import TrimlabModel

/// One poster or sprite the strip is waiting for, with the file it is made from.
struct StripJob {
  enum Kind { case poster, sprite }
  let kind: Kind
  let clip: ReelClip
  let url: URL
}

/// The strip's frames (§4.1, §4.3.1): a poster per tile first (`media.poster`, about 10 ms each), then the 40-frame
/// sprite (`media.sprite`, about 1 s each) that replaces it, made by up to `spriteWorkers` workers in the background.
/// Posters go before sprites and tiles on screen before tiles off it (M-5). Missing and loading tiles ask for none.
extension EditorModel {
  static let spriteWorkers = 3
  /// A sprite that failed this many times isn't asked for again this session.
  static let spriteAttempts = 2

  /// The file a tile's sprite comes from, or nil when it shouldn't ask: missing, still loading, or no known file.
  func spriteURL(for clip: ReelClip) -> URL? {
    guard !missing.contains(clip.id), loading[clip.id].map({ $0 == .ready }) ?? true else { return nil }
    return url(for: clip.id)
  }

  /// The sources whose tiles can show frames now; the model re-asks whenever this changes (`watchStripSources`).
  public var stripSpriteSources: [SourceRef] {
    (reel?.clips ?? []).filter { spriteURL(for: $0) != nil }.map(\.source)
  }

  /// Asks for frames whenever `stripSpriteSources` changes: a probe landing, a relink, an undo, an open. The model
  /// does this, not the strip view: SwiftUI stops running a covered window's view tasks, so with the app behind
  /// another one the tiles whose probes landed after that never asked (Task 42 acceptance 2, miss 1). Runs from
  /// `init` for the model's life; each change is handled once, on the next main-actor turn. Any write to `reel`,
  /// `loading` or `missing` wakes it, so it asks only when the sources really changed.
  func watchStripSources() {
    withObservationTracking { _ = stripSpriteSources } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let sources = self.stripSpriteSources
        if sources != self.stripSourcesAsked {
          self.stripSourcesAsked = sources
          self.requestStripSprites()
        }
        self.watchStripSources()
      }
    }
  }

  /// What a tile draws: its sprite, or until that lands its poster.
  func stripFrames(for source: SourceRef) -> StripSprite? { stripSprites[source] ?? stripPosters[source] }

  /// Queues a poster (once) and a sprite for every tile that can show frames and has none, isn't queued, and hasn't
  /// used its retry.
  public func requestStripSprites() {
    guard let reel else { return }
    for clip in reel.clips {
      guard let url = spriteURL(for: clip) else { continue }
      let source = clip.source
      if stripSprites[source] != nil { continue }
      if !session.postersAsked.contains(source) {
        session.postersAsked.insert(source)
        session.stripQueue.append(StripJob(kind: .poster, clip: clip, url: url))
      }
      if spritePending.contains(source) || session.spriteFailures[source, default: 0] >= Self.spriteAttempts { continue }
      spritePending.insert(source)
      session.stripQueue.append(StripJob(kind: .sprite, clip: clip, url: url))
    }
    guard spriteWorker == nil, !session.stripQueue.isEmpty else { return }
    spriteWorker = Task { [weak self] in
      // Workers stop when the queue is empty; anything queued while they wind down starts another round, and the
      // last empty check and the reset of `spriteWorker` happen in one main-actor turn.
      while let model = self, !model.session.stripQueue.isEmpty, !Task.isCancelled {
        await withTaskGroup(of: Void.self) { group in
          for _ in 0..<Self.spriteWorkers { group.addTask { await model.drainStrip() } }
        }
      }
      if !Task.isCancelled, let model = self {
        model.spriteWorker = nil
        if let began = model.importStarted, model.session.inFlight.isEmpty {  // §10, once the probes are in
          model.importStarted = nil
          MediaLog.note("strip: \(model.stripSprites.count) sprites ready \(Self.millis(since: began)) ms after the import began")
          let bare = Set(model.stripSpriteSources).filter { model.stripSprites[$0] == nil }.count
          if bare > 0 { MediaLog.note("strip: \(bare) tiles still without a sprite (failed twice)") }
        }
      }
    }
  }

  /// The next job: posters before sprites, and within each a tile on screen before one off it, in strip order.
  func takeStripJob() -> StripJob? {
    guard !session.stripQueue.isEmpty else { return nil }
    let onScreen = stripSourcesOnScreen()
    func rank(_ job: StripJob) -> Int {
      (job.kind == .poster ? 0 : 2) + (onScreen?.contains(job.clip.source) == false ? 1 : 0)
    }
    let queue = session.stripQueue
    guard let best = queue.indices.min(by: { rank(queue[$0]) < rank(queue[$1]) }) else { return nil }
    return session.stripQueue.remove(at: best)
  }

  /// The sources of the tiles the strip shows now, or nil when it hasn't been laid out (every tile counts as shown).
  func stripSourcesOnScreen() -> Set<SourceRef>? {
    guard stripWidth > 0, let clips = (draftReel ?? reel)?.clips else { return nil }
    let shown = Set(stripLayout().tiles.filter { $0.rect.maxX >= 0 && $0.rect.minX <= stripWidth }.map(\.id))
    return Set(clips.filter { shown.contains($0.id) }.map(\.source))
  }

  /// One worker: takes queued jobs until none are left. A job whose clip has left the Reel is dropped, and a poster
  /// whose sprite has already landed is skipped.
  private func drainStrip() async {
    while !Task.isCancelled, let job = takeStripJob() {
      let source = job.clip.source
      guard reel?.clips.contains(where: { $0.source == source }) == true else {
        if job.kind == .sprite { spritePending.remove(source) }
        continue
      }
      switch job.kind {
      case .poster:
        guard stripSprites[source] == nil else { continue }
        var made: StripSprite?
        do {
          made = await StripSprite.poster(try await media.poster(job.clip, at: job.url))
        } catch {
          MediaLog.note("strip: poster for \(job.url.lastPathComponent) failed: \(error)")
        }
        guard !Task.isCancelled else { return }  // a reset cleared the queue and owns the state now
        if let made, stripSprites[source] == nil { stripPosters[source] = made }
        notePostersReady()
      case .sprite:
        var made: StripSprite?
        do {
          made = await StripSprite.make(try await media.sprite(job.clip, at: job.url))
          if made == nil { MediaLog.note("strip: sprite for \(job.url.lastPathComponent) could not be cut into frames") }
        } catch {
          MediaLog.note("strip: sprite for \(job.url.lastPathComponent) failed: \(error)")
        }
        guard !Task.isCancelled else { return }
        spritePending.remove(source)
        if let made {
          stripSprites[source] = made
          stripPosters[source] = nil
        } else {
          session.spriteFailures[source, default: 0] += 1
        }
        notePostersReady()
      }
    }
  }

  /// §10 strip with posters: once the import's probes are in and every tile that can show frames has some, logs how
  /// long that took from the import's start (once per import).
  private func notePostersReady() {
    guard let began = postersStarted, session.inFlight.isEmpty, let reel else { return }
    let ready = reel.clips.filter { spriteURL(for: $0) != nil }
    guard ready.allSatisfy({ stripFrames(for: $0.source) != nil }) else { return }
    postersStarted = nil
    MediaLog.note("strip: \(ready.count) tiles with posters \(Self.millis(since: began)) ms after the import began")
  }
}
