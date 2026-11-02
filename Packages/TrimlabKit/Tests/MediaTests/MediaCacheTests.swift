import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TrimlabMedia
@testable import TrimlabModel

@Suite(.serialized) struct MediaCacheTests {
  /// A temp cache root that is removed when the test ends.
  private static func withRoot<T>(limit: Int64 = 2 << 30,
                                  _ body: (URL, MediaCache) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appending(path: "trimlab2-cache-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root, MediaCache(root: root, limitBytes: limit))
  }

  private static func ref(_ url: URL, size: Int64 = 1, modified: TimeInterval = 0) -> SourceRef {
    SourceRef(relativePath: nil, absolutePath: url.path, size: size, modified: Date(timeIntervalSince1970: modified))
  }

  @Test func spriteHas40FramesAt2x() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      let sprite = try await cache.sprite(for: Self.ref(url), asset: asset)
      #expect(sprite.frames == 40)
      #expect(sprite.times.count == 40)
      #expect(sprite.image.height == 128)
      #expect(sprite.image.width == 40 * 72)  // 1080x1920 at 128 px tall
      let d = RationalTime(try await asset.load(.duration))
      #expect(sprite.times[0] == .zero)
      #expect(sprite.times[1] == RationalTime(d.value, d.timescale * 40))
    }
  }

  @Test func rotatedSpriteCellIsPortrait() async throws {
    let url = try await Fixtures.url("rotated.mov")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      let sprite = try await cache.sprite(for: Self.ref(url), asset: asset)
      let cellWidth = sprite.image.width / 40
      #expect(sprite.image.height > cellWidth)
    }
  }

  @Test func rotatedPosterIsPortrait() async throws {
    let url = try await Fixtures.url("rotated.mov")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      let poster = try await cache.poster(for: Self.ref(url), asset: asset)
      #expect(poster.height > poster.width)
    }
  }

  @Test func peaksAre20ms() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      let peaks = try await cache.peaks(for: Self.ref(url), asset: asset)
      #expect(abs(peaks.count - 250) <= 2)
      let top = peaks.map { Float($0) }.max() ?? 0
      #expect(abs(top - 1.0) < 0.01)
    }
  }

  /// The peaks reader blocks in copyNextSampleBuffer; a dozen at once (the cooperative pool's width) must
  /// not park every pool thread and starve other work.
  @Test func twelveConcurrentPeaksDoNotStarveThePool() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    try await Self.withRoot { _, cache in
      let results = try await withThrowingTaskGroup(of: Int?.self) { group in
        for i in 0..<12 {
          group.addTask {
            let asset = AVURLAsset(url: url)
            return try await cache.peaks(for: Self.ref(url, size: Int64(100 + i)), asset: asset).count
          }
        }
        // Canary: needs a pool thread while the peaks reads are in flight; must finish within a bound.
        group.addTask {
          let start = ContinuousClock.now
          for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)); await Task.yield() }
          #expect(ContinuousClock.now - start < .seconds(5), "canary starved")
          return nil
        }
        var counts: [Int] = []
        for try await r in group { if let r { counts.append(r) } }
        return counts
      }
      #expect(results.count == 12)
      #expect(results.allSatisfy { abs($0 - 250) <= 2 })
    }
  }

  @Test func silentClipHasEmptyPeaks() async throws {
    let url = try await Fixtures.url("noaudio.mp4")
    let asset = AVURLAsset(url: url)
    let r = Self.ref(url)
    try await Self.withRoot { _, cache in
      let peaks = try await cache.peaks(for: r, asset: asset)
      #expect(peaks.isEmpty)
      let file = cache.dir(for: r).appending(path: "peaks.bin")
      let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
      #expect(size == 0)
    }
  }

  @Test func secondCallHitsCache() async throws {
    let url = try await Fixtures.url("landscape.mp4")
    let asset = AVURLAsset(url: url)
    let r = Self.ref(url)
    try await Self.withRoot { _, cache in
      // Warm-up hit on a different ref, so one-time ImageIO setup is not in the measurement.
      let warm = Self.ref(url, size: 99)
      _ = try await cache.poster(for: warm, asset: asset)
      _ = try await cache.poster(for: warm, asset: asset)
      _ = try await cache.poster(for: r, asset: asset)
      let file = cache.dir(for: r).appending(path: "poster.jpg")
      let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
      let clock = ContinuousClock()
      let took = try await clock.measure { _ = try await cache.poster(for: r, asset: asset) }
      let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
      #expect(before == after)
      #expect(took < .milliseconds(50))
    }
  }

  @Test func concurrentSameRefGeneratesOnce() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    let r = Self.ref(url)
    try await Self.withRoot { _, cache in
      async let a = cache.sprite(for: r, asset: asset)
      async let b = cache.sprite(for: r, asset: asset)
      let (sa, sb) = try await (a, b)
      #expect(sa.frames == 40 && sb.frames == 40)
      #expect(await cache.generationsStarted == 1)
    }
  }

  @Test func oneCancelledCallerDoesNotStopTheOthers() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    let r = Self.ref(url)
    try await Self.withRoot { _, cache in
      let keeper = Task { try await cache.sprite(for: r, asset: asset) }
      let quitter = Task { try await cache.sprite(for: r, asset: asset) }
      while await cache.inFlight == 0 { try await Task.sleep(for: .milliseconds(1)) }
      quitter.cancel()
      await #expect(throws: CancellationError.self) { _ = try await quitter.value }
      #expect(try await keeper.value.frames == 40)
      #expect(await cache.generationsStarted == 1)
    }
  }

  @Test func snapBeforeFirstKeyframeReturnsFirst() {
    let index = KeyframeIndex(times: [RationalTime(2, 1), RationalTime(4, 1)])
    #expect(index.snappedIn(RationalTime(1, 1)) == RationalTime(2, 1))
  }

  @Test func keyChangesWithMtime() async throws {
    try await Self.withRoot { _, cache in
      let a = Self.ref(URL(filePath: "/x.mov"), size: 10, modified: 100)
      var b = a
      b.modified = Date(timeIntervalSince1970: 101)
      var c = a
      c.size = 11
      let ka = cache.key(for: a)
      #expect(cache.key(for: b) != ka)
      #expect(cache.key(for: c) != ka)
      #expect(cache.key(for: a) == ka)
      #expect(ka.count == 40)
    }
  }

  @Test func keyframesFromCursor() async throws {
    let url = try await Fixtures.url("keyframes.mp4")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      let index = try await cache.keyframes(for: Self.ref(url), asset: asset)
      #expect(index.times.map { $0.seconds } == [0, 1, 2, 3, 4, 5])
      #expect(index.snappedIn(RationalTime(seconds: 3.4)) == RationalTime(3, 1))
      #expect(index.snappedIn(RationalTime(3, 1)) == RationalTime(3, 1))
    }
  }

  @Test func pruneKeepsOpenReel() async throws {
    try await Self.withRoot(limit: 1024) { root, cache in
      let fm = FileManager.default
      for (i, name) in ["k1", "k2", "k3"].enumerated() {
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 500).write(to: dir.appending(path: "poster.jpg"))
        // k1 oldest, k3 newest.
        let t = Date(timeIntervalSinceNow: Double(i - 10) * 100)
        try fm.setAttributes([.modificationDate: t], ofItemAtPath: dir.path)
        var tv = [timeval(tv_sec: Int(t.timeIntervalSince1970), tv_usec: 0),
                  timeval(tv_sec: Int(t.timeIntervalSince1970), tv_usec: 0)]
        utimes(dir.path, &tv)
      }
      await cache.prune(keeping: ["k1"])
      // k1 is oldest but kept; k2 is the oldest of the rest and goes; 1000 B fits.
      #expect(fm.fileExists(atPath: root.appending(path: "k1").path))
      #expect(!fm.fileExists(atPath: root.appending(path: "k2").path))
      #expect(fm.fileExists(atPath: root.appending(path: "k3").path))
    }
  }

  @Test func concurrencyIsThree() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<8 {
          group.addTask {
            // Distinct sizes give distinct cache keys, so every request really generates.
            _ = try await cache.sprite(for: Self.ref(url, size: Int64(i + 1)), asset: asset)
          }
        }
        try await group.waitForAll()
      }
      #expect(await cache.maxObservedInFlight == 3)
    }
  }

  @Test func cancellationStops() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    let r = Self.ref(url)
    try await Self.withRoot { root, cache in
      let task = Task { try await cache.sprite(for: r, asset: asset) }
      while await cache.inFlight == 0 { try await Task.sleep(for: .milliseconds(1)) }
      try await Task.sleep(for: .milliseconds(10))  // generation has started; cancel mid-flight
      task.cancel()
      await #expect(throws: CancellationError.self) { _ = try await task.value }
      let dir = cache.dir(for: r)
      #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "sprite.jpg").path))
      let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
      #expect(leftovers.isEmpty)
    }
  }

  @Test func cancelledWaiterIsRemovedAndThrows() async throws {
    let url = try await Fixtures.url("portrait_hevc.mov")
    let asset = AVURLAsset(url: url)
    try await Self.withRoot { _, cache in
      // Fill the three slots, then queue a fourth and cancel it while it waits.
      let busy = (0..<3).map { i in
        Task { try await cache.sprite(for: Self.ref(url, size: Int64(100 + i)), asset: asset) }
      }
      try await Task.sleep(for: .milliseconds(5))
      let queued = Task { try await cache.sprite(for: Self.ref(url, size: 200), asset: asset) }
      try await Task.sleep(for: .milliseconds(5))
      queued.cancel()
      await #expect(throws: CancellationError.self) { _ = try await queued.value }
      for t in busy { _ = try await t.value }
      // No slot leaked: a further request runs and the counter returns to zero.
      let again = try await cache.sprite(for: Self.ref(url, size: 300), asset: asset)
      #expect(again.frames == 40)
      #expect(await cache.inFlight == 0)
    }
  }

  /// M6: leftover tmp files from a crash go at launch, in every entry, kept or not; fresh ones and real
  /// entries stay.
  @Test func sweepOrphansRemovesOldTemporariesOnly() async throws {
    try await Self.withRoot { root, cache in
      let fm = FileManager.default
      let old = Date(timeIntervalSinceNow: -2 * 3_600)
      var made: [String: URL] = [:]
      for (entry, names) in [("aaaa", [".remux.0123.mov", ".poster.jpg.ABCD.tmp", "remux.mov", "poster.jpg"]),
                             ("bbbb", [".remux.4567.mov", ".peaks.bin.EF01.tmp"])] {
        let dir = root.appending(path: entry, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
          let file = dir.appending(path: name)
          try Data("x".utf8).write(to: file)
          try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
          made["\(entry)/\(name)"] = file
        }
      }
      let fresh = root.appending(path: "bbbb/.remux.fresh.mov")
      try Data("x".utf8).write(to: fresh)

      let removed = cache.sweepOrphans(olderThan: 3_600)
      #expect(removed == 4)
      for key in ["aaaa/.remux.0123.mov", "aaaa/.poster.jpg.ABCD.tmp", "bbbb/.remux.4567.mov", "bbbb/.peaks.bin.EF01.tmp"] {
        #expect(!fm.fileExists(atPath: made[key]!.path), "\(key) should be swept")
      }
      for key in ["aaaa/remux.mov", "aaaa/poster.jpg"] {
        #expect(fm.fileExists(atPath: made[key]!.path), "\(key) should stay")
      }
      #expect(fm.fileExists(atPath: fresh.path))
    }
  }
}
