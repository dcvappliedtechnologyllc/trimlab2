import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import TrimlabModel
import UniformTypeIdentifiers

public enum MediaCacheError: Error, Equatable {
  case noVideoTrack
  case unreadable(String)
}

/// 40 thumbnails side by side, edge to edge, 64 pt (128 px) tall.
public struct Sprite: @unchecked Sendable {
  public let image: CGImage
  public let frames: Int
  /// `i × duration / 40` (v1 ruling).
  public let times: [RationalTime]

  public init(image: CGImage, frames: Int, times: [RationalTime]) {
    self.image = image
    self.frames = frames
    self.times = times
  }
}

/// `cancelAllCGImageGeneration()` is documented as callable from any thread.
private struct GeneratorCanceller: @unchecked Sendable {
  let generator: AVAssetImageGenerator
  init(_ generator: AVAssetImageGenerator) { self.generator = generator }
  func cancel() { generator.cancelAllCGImageGeneration() }
}

/// On-disk cache of posters, sprites, peaks, keyframes and remuxes (§4.6), keyed by sha1(path + size + mtime).
public actor MediaCache {
  public static let defaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Caches/trimlab 2", directoryHint: .isDirectory)

  static let spriteFrames = 40
  static let spriteHeight = 128  // 64 px at 2x
  static let posterLongSide = 1280
  static let maxGenerations = 3
  /// 20 ms at 48 kHz.
  static let peakWindow = 960

  private let root: URL
  private let limitBytes: Int64

  // The "at most 3 generations" semaphore: an actor-internal slot counter plus a FIFO waiter queue.
  private(set) var inFlight = 0
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

  /// Test hook: the highest number of generations that ever ran at once.
  public private(set) var maxObservedInFlight = 0
  /// Test hook: how many generations actually started (coalesced callers count once).
  public private(set) var generationsStarted = 0

  public init(root: URL = MediaCache.defaultRoot, limitBytes: Int64 = 2 << 30) {
    self.root = root
    self.limitBytes = limitBytes
  }

  // MARK: keys and paths

  // Nonisolated: they read only `root`, so sync callers (and the importer) reach them without a hop.

  public nonisolated func key(for ref: SourceRef) -> String {
    let text = "\(ref.absolutePath)|\(ref.size)|\(ref.modified.timeIntervalSince1970)"
    return Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public nonisolated func dir(for ref: SourceRef) -> URL {
    root.appending(path: key(for: ref), directoryHint: .isDirectory)
  }

  public nonisolated func remuxURL(for ref: SourceRef) -> URL {
    dir(for: ref).appending(path: "remux.mov")
  }

  // MARK: poster

  public func poster(for ref: SourceRef, asset: AVURLAsset) async throws -> CGImage {
    let file = dir(for: ref).appending(path: "poster.jpg")
    if let hit = Self.readImage(file) { touch(ref); return hit }
    return try await coalesce(kind: "poster", ref: ref) {
      if let hit = Self.readImage(file) { return hit }  // another request finished it while we queued
      let image = try await Self.makePoster(asset)
      try Self.writeAtomically(Self.jpegData(image), to: file)
      MediaLog.note("cache: poster \(file.path)")
      return image
    }
  }

  // MARK: sprite

  public func sprite(for ref: SourceRef, asset: AVURLAsset) async throws -> Sprite {
    let file = dir(for: ref).appending(path: "sprite.jpg")
    if let hit = Self.readImage(file) {
      touch(ref)
      return Sprite(image: hit, frames: Self.spriteFrames, times: try await Self.spriteTimes(asset))
    }
    return try await coalesce(kind: "sprite", ref: ref) {
      if let hit = Self.readImage(file) {
        return Sprite(image: hit, frames: Self.spriteFrames, times: try await Self.spriteTimes(asset))
      }
      let sprite = try await Self.makeSprite(asset)
      try Self.writeAtomically(Self.jpegData(sprite.image), to: file)
      MediaLog.note("cache: sprite \(file.path)")
      return sprite
    }
  }

  // MARK: peaks

  public func peaks(for ref: SourceRef, asset: AVURLAsset) async throws -> [Float16] {
    let file = dir(for: ref).appending(path: "peaks.bin")
    if let data = try? Data(contentsOf: file) { touch(ref); return Self.decodePeaks(data) }
    return try await coalesce(kind: "peaks", ref: ref) {
      if let data = try? Data(contentsOf: file) { return Self.decodePeaks(data) }
      let peaks = try await Self.makePeaks(asset)
      try Self.writeAtomically(Self.encodePeaks(peaks), to: file)
      MediaLog.note("cache: peaks \(peaks.count) \(file.path)")
      return peaks
    }
  }

  // MARK: keyframes

  public func keyframes(for ref: SourceRef, asset: AVURLAsset) async throws -> KeyframeIndex {
    let file = dir(for: ref).appending(path: "keyframes.bin")
    if let data = try? Data(contentsOf: file), let hit = try? JSONDecoder().decode(KeyframeIndex.self, from: data) {
      touch(ref)
      return hit
    }
    return try await coalesce(kind: "keyframes", ref: ref) {
      let index = try await KeyframeIndex.read(asset)
      try Self.writeAtomically(try JSONEncoder().encode(index), to: file)
      MediaLog.note("cache: keyframes \(index.times.count) \(file.path)")
      return index
    }
  }

  // MARK: pruning

  /// Removes least-recently-used entry directories until the cache fits `limitBytes`. Never removes a key in `keeping`.
  public func prune(keeping keys: Set<String>) async {
    let fm = FileManager.default
    let entries = (try? fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentAccessDateKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])) ?? []
    var items: [(url: URL, used: Date, size: Int64)] = []
    for url in entries {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentAccessDateKey, .contentModificationDateKey])
      guard values?.isDirectory == true else { continue }
      let used = [values?.contentAccessDate, values?.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
      items.append((url, used, Self.treeSize(url)))
    }
    var total = items.reduce(Int64(0)) { $0 + $1.size }
    for item in items.sorted(by: { $0.used < $1.used }) where total > limitBytes {
      if keys.contains(item.url.lastPathComponent) { continue }
      do {
        try fm.removeItem(at: item.url)
        total -= item.size
        MediaLog.note("cache: pruned \(item.url.lastPathComponent)")
      } catch {
        MediaLog.note("cache: could not prune \(item.url.lastPathComponent): \(error)")
      }
    }
  }

  /// Removes `.remux.*.mov` and `.*.tmp` files older than `age` seconds from every entry, kept ones included:
  /// they are only ever an interrupted remux or write (a crash, a force quit). The app calls this at launch.
  /// Returns how many files went.
  @discardableResult
  public nonisolated func sweepOrphans(olderThan age: TimeInterval) -> Int {
    let fm = FileManager.default
    let cutoff = Date(timeIntervalSinceNow: -age)
    let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
    var removed = 0
    for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
      let files = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.contentModificationDateKey]))
        ?? []
      for file in files {
        let name = file.lastPathComponent
        let orphan = (name.hasPrefix(".remux.") && name.hasSuffix(".mov")) || (name.hasPrefix(".") && name.hasSuffix(".tmp"))
        guard orphan else { continue }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, modified < cutoff else { continue }
        do {
          try fm.removeItem(at: file)
          removed += 1
          MediaLog.note("cache: swept \(entry.lastPathComponent)/\(name)")
        } catch {
          MediaLog.note("cache: could not sweep \(entry.lastPathComponent)/\(name): \(error)")
        }
      }
    }
    return removed
  }

  /// Marks an entry as just used so LRU sees it.
  nonisolated func touch(_ ref: SourceRef) {
    var now = timeval()
    gettimeofday(&now, nil)
    var times = [now, now]
    _ = utimes(dir(for: ref).path, &times)
  }

  // MARK: in-flight coalescing

  private struct FlightID: Hashable {
    let kind: String
    let key: String
  }

  private struct Flight {
    let token: UUID
    let task: Task<any Sendable, any Error>
    var awaiters = 0
  }

  private var flights: [FlightID: Flight] = [:]

  /// One generation per (kind, key): concurrent callers await the same task. A caller that is cancelled
  /// throws `CancellationError`; the shared task is cancelled only when its last awaiter leaves.
  private func coalesce<T: Sendable>(kind: String, ref: SourceRef,
                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let id = FlightID(kind: kind, key: key(for: ref))
    if flights[id] == nil {
      let token = UUID()
      let task = Task<any Sendable, any Error> {
        do {
          let value = try await self.generate(work)
          self.finish(id, token: token)
          return value
        } catch {
          self.finish(id, token: token)
          throw error
        }
      }
      flights[id] = Flight(token: token, task: task)
    }
    flights[id]!.awaiters += 1
    let flight = flights[id]!
    let value: any Sendable
    do {
      value = try await withTaskCancellationHandler {
        try await flight.task.value
      } onCancel: {
        Task { await self.leave(id, token: flight.token) }
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
    try Task.checkCancellation()
    return value as! T
  }

  private func finish(_ id: FlightID, token: UUID) {
    // A flight abandoned by its last awaiter may already have been replaced by a newer one.
    if flights[id]?.token == token { flights[id] = nil }
  }

  /// A cancelled awaiter leaves; the last one out cancels the work and frees the slot for a fresh request.
  private func leave(_ id: FlightID, token: UUID) {
    guard var flight = flights[id], flight.token == token else { return }
    flight.awaiters -= 1
    if flight.awaiters <= 0 {
      flight.task.cancel()
      flights[id] = nil
    } else {
      flights[id] = flight
    }
  }

  // MARK: concurrency (async semaphore)

  /// Waits for one of the three slots, runs `work`, frees the slot. Throws `CancellationError` if cancelled
  /// while queued or running.
  private func generate<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    generationsStarted += 1
    do {
      return try await work()
    } catch {
      // AVFoundation reports its own cancellation error; callers get the Swift one.
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if inFlight < Self.maxGenerations {
      inFlight += 1
      maxObservedInFlight = max(maxObservedInFlight, inFlight)
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        // Runs on the actor. A task cancelled before it got here never reaches the queue.
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func release() {
    if waiters.isEmpty {
      inFlight -= 1
    } else {
      // The slot passes straight to the next waiter, so inFlight is unchanged.
      waiters.removeFirst().continuation.resume()
    }
  }

  // MARK: generators (off the actor)

  @concurrent
  private static func makePoster(_ asset: AVURLAsset) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: posterLongSide, height: posterLongSide)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let canceller = GeneratorCanceller(generator)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await generator.image(at: .zero).image
    } onCancel: {
      canceller.cancel()
    }
  }

  /// `i × duration / 40`, exact.
  @concurrent
  private static func spriteTimes(_ asset: AVURLAsset) async throws -> [RationalTime] {
    let duration = RationalTime(try await asset.load(.duration))
    guard duration > .zero else { throw MediaCacheError.unreadable("no duration") }
    return (0..<spriteFrames).map { i in
      let n = Int64(i)
      let d = Int64(duration.timescale) * Int64(spriteFrames)
      if d <= Int64(Int32.max) { return RationalTime(duration.value * n, Int32(d)) }
      return RationalTime(seconds: duration.seconds * Double(i) / Double(spriteFrames), timescale: 60_000)
    }
  }

  @concurrent
  private static func makeSprite(_ asset: AVURLAsset) async throws -> Sprite {
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw MediaCacheError.noVideoTrack
    }
    let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
    let shown = natural.applying(transform)
    let w = abs(shown.width), h = abs(shown.height)
    guard w > 0, h > 0 else { throw MediaCacheError.unreadable("empty frame size") }
    let cellH = spriteHeight
    let cellW = max(1, Int((Double(cellH) * w / h).rounded()))
    let times = try await spriteTimes(asset)

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: cellW, height: cellH)
    // Each cell shows its own time, not the nearest keyframe.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    guard let context = CGContext(data: nil, width: cellW * spriteFrames, height: cellH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw MediaCacheError.unreadable("no bitmap context") }
    context.interpolationQuality = .high

    let canceller = GeneratorCanceller(generator)
    return try await withTaskCancellationHandler {
      for (i, t) in times.enumerated() {
        try Task.checkCancellation()
        let image = try await generator.image(at: CMTime(t)).image
        context.draw(image, in: CGRect(x: i * cellW, y: 0, width: cellW, height: cellH))
      }
      try Task.checkCancellation()
      guard let sheet = context.makeImage() else { throw MediaCacheError.unreadable("no sprite image") }
      return Sprite(image: sheet, frames: spriteFrames, times: times)
    } onCancel: {
      canceller.cancel()
    }
  }

  /// Max-abs of both channels per 20 ms window, scaled so the loudest window is 1.0. Empty when there is no
  /// audio track or the audio is entirely silent.
  private static func makePeaks(_ asset: AVURLAsset) async throws -> [Float16] {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
    // The sample loop blocks in copyNextSampleBuffer, so it runs on its own thread, not a pool thread.
    nonisolated(unsafe) let boxedAsset = asset
    nonisolated(unsafe) let boxedTrack = track
    return try await BlockingWork.run { cancellation in
      try readPeaks(boxedAsset, boxedTrack, cancellation)
    }
  }

  private static func readPeaks(_ asset: AVURLAsset, _ track: AVAssetTrack,
                                _ cancellation: BlockingWork.Cancellation) throws -> [Float16] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaAudio.readerSettings)
    guard reader.canAdd(output) else { throw MediaCacheError.unreadable("cannot read audio") }
    reader.add(output)
    guard reader.startReading() else {
      throw MediaCacheError.unreadable(reader.error?.localizedDescription ?? "audio reader failed")
    }
    defer { if reader.status == .reading { reader.cancelReading() } }

    var windows: [Float] = []
    var current: Float = 0
    var filled = 0  // frames (L+R pairs) in the open window
    var scratch: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
      try cancellation.check()
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      let floats = length / MemoryLayout<Float>.size
      if scratch.count < floats { scratch = [Float](repeating: 0, count: floats) }
      let status = scratch.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats * MemoryLayout<Float>.size,
                                   destination: $0.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw MediaCacheError.unreadable("audio copy failed") }
      var i = 0
      while i + 1 < floats {
        current = max(current, abs(scratch[i]), abs(scratch[i + 1]))
        i += 2
        filled += 1
        if filled == peakWindow {
          windows.append(current)
          current = 0
          filled = 0
        }
      }
    }
    if reader.status == .failed {
      throw MediaCacheError.unreadable(reader.error?.localizedDescription ?? "audio reader failed")
    }
    try cancellation.check()
    if filled > 0 { windows.append(current) }
    guard let loudest = windows.max(), loudest > 0 else { return [] }
    return windows.map { Float16($0 / loudest) }
  }

  // MARK: file helpers

  private static func jpegData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw MediaCacheError.unreadable("no jpeg encoder") }
    CGImageDestinationAddImage(destination, image,
                               [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw MediaCacheError.unreadable("jpeg encode failed") }
    return data as Data
  }

  private static func readImage(_ file: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func encodePeaks(_ peaks: [Float16]) -> Data {
    peaks.withUnsafeBytes { Data($0) }
  }

  private static func decodePeaks(_ data: Data) -> [Float16] {
    let count = data.count / MemoryLayout<Float16>.size
    return [Float16](unsafeUninitializedCapacity: count) { buffer, initialized in
      data.withUnsafeBytes { raw in
        _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
      }
      initialized = count
    }
  }

  /// Writes to a temp file in the same directory, then renames over `file`; a failure leaves nothing behind.
  private static func writeAtomically(_ data: Data, to file: URL) throws {
    try Task.checkCancellation()
    let dir = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let temp = dir.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try data.write(to: temp)
      try Task.checkCancellation()
      guard rename(temp.path, file.path) == 0 else {
        throw MediaCacheError.unreadable("rename failed: errno \(errno)")
      }
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
  }

  private static func treeSize(_ url: URL) -> Int64 {
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
      return 0
    }
    var total: Int64 = 0
    for case let file as URL in walker {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}
