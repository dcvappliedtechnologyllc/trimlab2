import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import TrimlabEditor
import TrimlabMedia
import TrimlabModel

/// Scripted media: per file name, the probe answer (facts or an error) and the capture date. Records how many
/// probes ran at once.
final class StubMedia: MediaServices {
  enum Answer: Sendable {
    case facts(ClipFacts)
    case error(any Error)
  }

  struct Waiter {
    let id: UUID
    let ready: @Sendable (State) -> Bool
    let continuation: CheckedContinuation<Bool, Never>
  }

  struct State {
    /// When set, `asset(_:at:)` hands out `TrackedAsset`s that report where they were freed.
    var assetDeaths: AssetDeaths?
    var answers: [String: Answer] = [:]
    var captureDates: [String: Date] = [:]
    var ffmpeg = true
    var inFlight = 0
    var maxInFlight = 0
    var probesStarted = 0
    var probesFinished = 0
    var held = false
    /// When set, every probe after the first `holdAfter` starts as if `hold()` had been called.
    var holdAfter: Int?
    /// Probes of these file names start as if `hold()` had been called. Unlike `holdAfter`, this doesn't depend on
    /// which concurrent probe starts first.
    var holdNames: Set<String> = []
    /// When set (only `probeConcurrencyFour`), each probe waits until this many are in flight before answering, so
    /// the concurrency limit, not luck, decides how many overlap.
    var rendezvous: Int?
    var heldProbes: [CheckedContinuation<Void, Never>] = []
    var waiters: [Waiter] = []
    var abandoned: Set<UUID> = []
    var prunedKeeping: [[SourceRef]] = []
    var assetsMade = 0
    /// The file of every `sprite` call, in order.
    var spriteRequests: [String] = []
    var spriteInFlight = 0
    var maxSpriteInFlight = 0
    /// How long each `sprite` call takes before it answers.
    var spriteDelay: Duration = .zero
    /// Every `poster` and `sprite` call, in order: "poster <path>" / "sprite <path>".
    var thumbRequests: [String] = []
    /// When set, `poster` answers a 9:16 image instead of failing.
    var postersWork = false
    /// File names `resolve` can't find (their clips open as missing).
    var unresolvable: Set<String> = []
    /// Sources under the first folder resolve to the same names under the second (a moved folder).
    var moved: (String, String)?
    /// Every file `probe` was asked for, by name, in order.
    var probedNames: [String] = []
    /// While set, `asset` waits at its start until `releaseAssets()` (a slow asset load).
    var assetsHeld = false
    var heldAssets: [CheckedContinuation<Void, Never>] = []
    var assetsStarted = 0
    /// While set, `importItem` waits at its start until `releaseItems()` (a slow folder read of capture dates).
    var itemsHeld = false
    var heldItems: [CheckedContinuation<Void, Never>] = []
    var itemsStarted = 0
    /// The file of every `peaks` / `keyframes` call, in order.
    var peakRequests: [String] = []
    var keyframeRequests: [String] = []
    /// What `peaks` and `keyframes` answer (nil `keyframes`: it throws).
    var peakAnswer: [Float16] = []
    var keyframeAnswer: [RationalTime]? = [.zero]
    /// What `quickBytes` answers.
    var quickBytesAnswer: Int64 = 0
    var quickBytesCalls = 0
    /// Every `export` call, in order, and the stream it handed back (the test drives it).
    var exports: [ExportRequest] = []
    var exportContinuation: AsyncThrowingStream<ExportEvent, Error>.Continuation?
    var cancelCalls = 0
    /// Whether `cancelExport` ends the stream (as the runner does); false: a stream that never ends.
    var finishOnCancel = true
    var cancelAnswer = true
    /// What `recentLog` answers.
    var log: [String] = []
  }

  struct ExportRequest: Sendable {
    let reel: Reel
    let dest: URL
    let sources: [UUID: URL]
    let quick: RationalTime?
    let replacing: Bool
  }
  let state = Mutex(State())

  /// The facts used for any file without a scripted answer: 10 s at 29.97.
  static func facts(_ duration: RationalTime = RationalTime(10, 1), fps: RationalTime = RationalTime(1001, 30000),
                    needsRemux: Bool = false) -> ClipFacts {
    ClipFacts(duration: duration, frameDuration: fps, displayWidth: 1080, displayHeight: 1920, rotation: 0,
              videoCodec: "hevc", hasAudio: true, hdr: .sdr, bitrate: 10_000_000, captureDate: nil,
              needsRemux: needsRemux)
  }

  func script(_ name: String, _ answer: Answer) { state.withLock { $0.answers[name] = answer } }
  func date(_ name: String, _ date: Date) { state.withLock { $0.captureDates[name] = date } }
  var maxInFlight: Int { state.withLock { $0.maxInFlight } }
  var probesStarted: Int { state.withLock { $0.probesStarted } }

  /// While held, every probe waits at its start until `release()`.
  func hold() { state.withLock { $0.held = true } }
  func release() {
    let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.held = false
      s.holdAfter = nil
      s.holdNames = []
      defer { s.heldProbes = [] }
      return s.heldProbes
    }
    for c in held { c.resume() }
  }

  /// Returns as soon as `n` probes have started (signalled, no polling); false after `timeout`, so a bug fails
  /// instead of hanging. The timeout is only ever reached by a failing test.
  func waitForProbes(_ n: Int, timeout: Duration = .seconds(20)) async -> Bool {
    await waitUntil(timeout: timeout) { $0.probesStarted >= n }
  }

  /// As `waitForProbes`, for probes that have answered.
  func waitForFinished(_ n: Int, timeout: Duration = .seconds(20)) async -> Bool {
    await waitUntil(timeout: timeout) { $0.probesFinished >= n }
  }

  /// Applies `body`, then resumes every waiter whose condition now holds.
  private func change(_ body: (inout State) -> Void) {
    let ready = state.withLock { s -> [Waiter] in
      body(&s)
      let snapshot = s
      let hits = s.waiters.filter { $0.ready(snapshot) }
      s.waiters.removeAll { w in hits.contains { $0.id == w.id } }
      return hits
    }
    for w in ready { w.continuation.resume(returning: true) }
  }

  private func waitUntil(timeout: Duration, _ ready: @escaping @Sendable (State) -> Bool) async -> Bool {
    let id = UUID()
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withTaskCancellationHandler {
          await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let answer: Bool? = self.state.withLock { s in
              if s.abandoned.remove(id) != nil { return false }
              if ready(s) { return true }
              s.waiters.append(Waiter(id: id, ready: ready, continuation: c))
              return nil
            }
            if let answer { c.resume(returning: answer) }
          }
        } onCancel: {
          let waiter: Waiter? = self.state.withLock { s in
            guard let i = s.waiters.firstIndex(where: { $0.id == id }) else {
              s.abandoned.insert(id)  // not registered yet: it returns false when it gets there
              return nil
            }
            return s.waiters.remove(at: i)
          }
          waiter?.continuation.resume(returning: false)
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  // MARK: MediaServices

  func importItem(_ url: URL) async -> ImportItem {
    var held = false
    change { s in
      s.itemsStarted += 1
      held = s.itemsHeld
    }
    if held {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow = state.withLock { s -> Bool in
          if !s.itemsHeld { return true }
          s.heldItems.append(c)
          return false
        }
        if resumeNow { c.resume() }
      }
    }
    let date = state.withLock { $0.captureDates[url.lastPathComponent] }
    return ImportItem(url: url, captureDate: date, fileCreated: nil)
  }

  func probe(_ url: URL, ref: SourceRef) async throws -> ClipFacts {
    var held = false
    var rendezvous: Int?
    change { s in
      s.inFlight += 1
      s.probesStarted += 1
      s.probedNames.append(url.lastPathComponent)
      s.maxInFlight = max(s.maxInFlight, s.inFlight)
      held = s.held || s.holdAfter.map { s.probesStarted > $0 } ?? false || s.holdNames.contains(url.lastPathComponent)
      rendezvous = s.rendezvous
    }
    defer { change { s in s.inFlight -= 1; s.probesFinished += 1 } }
    if held {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow = state.withLock { s -> Bool in
          if !s.held && s.holdAfter == nil && !s.holdNames.contains(url.lastPathComponent) { return true }
          s.heldProbes.append(c)
          return false
        }
        if resumeNow { c.resume() }
      }
    }
    if let n = rendezvous { _ = await waitUntil(timeout: .seconds(20)) { $0.inFlight >= n || $0.rendezvous == nil } }
    switch state.withLock({ $0.answers[url.lastPathComponent] }) {
    case .facts(let f)?: return f
    case .error(let e)?: throw e
    case nil: return Self.facts(needsRemux: ["mkv", "avi"].contains(url.pathExtension.lowercased()))
    }
  }

  func sourceRef(_ url: URL, projectFolder: URL?) throws -> SourceRef {
    var relative: String?
    if let folder = projectFolder, url.path.hasPrefix(folder.path + "/") {
      relative = String(url.path.dropFirst(folder.path.count + 1))
    }
    return SourceRef(relativePath: relative, absolutePath: url.path, size: 1_000,
                     modified: Date(timeIntervalSince1970: 1_000))
  }

  func poster(_ clip: ReelClip, at url: URL) async throws -> CGImage {
    let works = state.withLock { s -> Bool in
      s.thumbRequests.append("poster \(url.path)")
      return s.postersWork
    }
    guard works, let image = Self.posterImage() else { throw MediaCacheError.unreadable("stub") }
    return image
  }
  /// A 90 × 160 mid-grey image.
  static func posterImage() -> CGImage? {
    guard let ctx = CGContext(data: nil, width: 90, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
    return ctx.makeImage()
  }
  func postersWork(_ on: Bool) { state.withLock { $0.postersWork = on } }
  var thumbRequests: [String] { state.withLock { $0.thumbRequests } }
  func sprite(_ clip: ReelClip, at url: URL) async throws -> Sprite {
    let delay = state.withLock { s -> Duration in
      s.thumbRequests.append("sprite \(url.path)")
      s.spriteRequests.append(url.path)
      s.spriteInFlight += 1
      s.maxSpriteInFlight = max(s.maxSpriteInFlight, s.spriteInFlight)
      return s.spriteDelay
    }
    defer { state.withLock { $0.spriteInFlight -= 1 } }
    if delay > .zero { try? await Task.sleep(for: delay) }
    throw MediaCacheError.unreadable("stub")
  }
  func spriteDelay(_ d: Duration) { state.withLock { $0.spriteDelay = d } }
  var maxSpriteInFlight: Int { state.withLock { $0.maxSpriteInFlight } }
  var spriteRequests: [String] { state.withLock { $0.spriteRequests } }
  func peaks(_ clip: ReelClip, at url: URL) async throws -> [Float16] {
    state.withLock { s in
      s.peakRequests.append(url.path)
      return s.peakAnswer
    }
  }
  func keyframes(_ clip: ReelClip, at url: URL) async throws -> KeyframeIndex {
    let times = state.withLock { s in
      s.keyframeRequests.append(url.path)
      return s.keyframeAnswer
    }
    guard let times else { throw MediaCacheError.unreadable("stub") }
    return KeyframeIndex(times: times)
  }
  var peakRequests: [String] { state.withLock { $0.peakRequests } }
  var keyframeRequests: [String] { state.withLock { $0.keyframeRequests } }
  func answerPeaks(_ p: [Float16]) { state.withLock { $0.peakAnswer = p } }
  func answerKeyframes(_ t: [RationalTime]?) { state.withLock { $0.keyframeAnswer = t } }
  func asset(_ clip: ReelClip, at url: URL) async throws -> AVURLAsset {
    var held = false
    change { s in
      s.assetsMade += 1
      s.assetsStarted += 1
      held = s.assetsHeld
    }
    if held {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow = state.withLock { s -> Bool in
          if !s.assetsHeld { return true }
          s.heldAssets.append(c)
          return false
        }
        if resumeNow { c.resume() }
      }
    }
    if let deaths = state.withLock({ $0.assetDeaths }) { return TrackedAsset(url: url, deaths: deaths) }
    return AVURLAsset(url: url)
  }
  func holdItems() { state.withLock { $0.itemsHeld = true } }
  func releaseItems() {
    let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.itemsHeld = false
      defer { s.heldItems = [] }
      return s.heldItems
    }
    for c in held { c.resume() }
  }
  /// Returns once `n` `importItem` calls have started in all; false after `timeout`.
  func waitForItems(_ n: Int, timeout: Duration = .seconds(20)) async -> Bool {
    await waitUntil(timeout: timeout) { $0.itemsStarted >= n }
  }
  func trackAssets(_ deaths: AssetDeaths) { state.withLock { $0.assetDeaths = deaths } }
  func holdAssets() { state.withLock { $0.assetsHeld = true } }
  func releaseAssets() {
    let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.assetsHeld = false
      defer { s.heldAssets = [] }
      return s.heldAssets
    }
    for c in held { c.resume() }
  }
  /// Returns as soon as `n` asset loads have started in all (signalled); false after `timeout`.
  func waitForAssets(_ n: Int, timeout: Duration = .seconds(20)) async -> Bool {
    await waitUntil(timeout: timeout) { $0.assetsStarted >= n }
  }
  var assetsMade: Int { state.withLock { $0.assetsMade } }
  func quickBytes(_ clip: ReelClip, at url: URL, range: Range<RationalTime>, includeAudio: Bool) async -> Int64 {
    state.withLock { s in
      s.quickBytesCalls += 1
      return s.quickBytesAnswer
    }
  }
  var quickBytesCalls: Int { state.withLock { $0.quickBytesCalls } }
  func answerQuickBytes(_ b: Int64) { state.withLock { $0.quickBytesAnswer = b } }
  func ffmpegAvailable() -> Bool { state.withLock { $0.ffmpeg } }
  func resolve(_ clip: ReelClip, projectFolder: URL?) -> URL? {
    var url = URL(filePath: clip.source.absolutePath)
    if let (from, to) = state.withLock({ $0.moved }), url.path.hasPrefix(from + "/") {
      url = URL(filePath: to + url.path.dropFirst(from.count))
    }
    return state.withLock { $0.unresolvable.contains(url.lastPathComponent) } ? nil : url
  }
  func move(from: String, to: String) { state.withLock { $0.moved = (from, to) } }
  func unresolvable(_ names: Set<String>) { state.withLock { $0.unresolvable = names } }
  var probedNames: [String] { state.withLock { $0.probedNames } }
  func pruneCache(keeping refs: [SourceRef]) async { state.withLock { $0.prunedKeeping.append(refs) } }

  // MARK: export

  func export(reel: Reel, dest: URL, sources: [UUID: URL], quick: RationalTime?,
              replacing: Bool) -> AsyncThrowingStream<ExportEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
    change { s in
      s.exports.append(ExportRequest(reel: reel, dest: dest, sources: sources, quick: quick, replacing: replacing))
      s.exportContinuation = continuation
    }
    return stream
  }

  @discardableResult
  func cancelExport() async -> Bool {
    let (c, answer) = state.withLock { s -> (AsyncThrowingStream<ExportEvent, Error>.Continuation?, Bool) in
      s.cancelCalls += 1
      return (s.finishOnCancel ? s.exportContinuation : nil, s.cancelAnswer)
    }
    c?.finish(throwing: CancellationError())
    return answer
  }
  /// What `cancelExport` reports: false as when the file was already being saved.
  func answerCancel(_ stopped: Bool) { state.withLock { $0.cancelAnswer = stopped } }

  func recentLog(_ lines: Int) -> [String] { state.withLock { Array($0.log.suffix(lines)) } }

  var exports: [ExportRequest] { state.withLock { $0.exports } }
  var cancelCalls: Int { state.withLock { $0.cancelCalls } }
  func neverFinishOnCancel() { state.withLock { $0.finishOnCancel = false } }
  func scriptLog(_ lines: [String]) { state.withLock { $0.log = lines } }
  /// Returns once `n` exports have started; false after `timeout`.
  func waitForExports(_ n: Int, timeout: Duration = .seconds(20)) async -> Bool {
    await waitUntil(timeout: timeout) { $0.exports.count >= n }
  }
  /// Hands `event` to the running export's stream.
  func send(_ event: ExportEvent) { _ = state.withLock { $0.exportContinuation }?.yield(event) }
  /// Ends the running export's stream, with `error` if given.
  func finishExport(throwing error: (any Error)? = nil) {
    let c = state.withLock { $0.exportContinuation }
    if let error { c?.finish(throwing: error) } else { c?.finish() }
  }
}

/// One `EditorModel` over the stubs.
@MainActor struct Harness {
  let media = StubMedia()
  let platform = StubPlatform()
  let store = MemoryProjectStore()
  let clock = ManualClock()
  let preview = StubPreview()
  let model: EditorModel

  init(prefs: Prefs = Prefs()) {
    model = EditorModel(platform: platform, media: media, store: store, prefs: prefs, clock: clock, preview: preview)
  }

  static func url(_ name: String, in folder: String = "/shoot") -> URL {
    URL(filePath: "\(folder)/\(name)", directoryHint: .notDirectory)
  }

  /// Imports and waits for every probe to settle.
  func importAll(_ names: [String], at gap: Int? = nil, in folder: String = "/shoot") async {
    await model.importURLs(names.map { Harness.url($0, in: folder) }, at: gap).value
  }

  var names: [String] {
    model.reel?.clips.map { URL(filePath: $0.source.absolutePath).lastPathComponent } ?? []
  }
  var noteTexts: [String] { model.notes.map(\.text) }
}


/// Counts `TrackedAsset` deaths, and how many happened on the main thread.
final class AssetDeaths: Sendable {
  let total = Atomic<Int>(0)
  let onMain = Atomic<Int>(0)
}

/// An `AVURLAsset` that records whether it was freed on the main thread (main-actor stall, hang-report.md).
final class TrackedAsset: AVURLAsset, @unchecked Sendable {
  let deaths: AssetDeaths
  init(url: URL, deaths: AssetDeaths, precise: Bool = false) {
    self.deaths = deaths
    super.init(url: url, options: precise ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil)
  }
  deinit {
    if Thread.isMainThread {
      deaths.onMain.add(1, ordering: .relaxed)
      if ProcessInfo.processInfo.environment["TRIMLAB_ASSET_STACKS"] == "1" {
        print("asset freed on main:\n" + Thread.callStackSymbols.prefix(30).joined(separator: "\n"))
      }
    }
    deaths.total.add(1, ordering: .relaxed)
  }
}
