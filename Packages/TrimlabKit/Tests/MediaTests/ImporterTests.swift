import Foundation
import Synchronization
import Testing
@testable import TrimlabMedia
@testable import TrimlabModel

@Suite(.serialized) struct ImporterTests {
  private static let ffmpeg = FFmpegLocation.find()

  private static func withRoot<T>(_ body: (URL, MediaCache) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appending(path: "trimlab2-import-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root, MediaCache(root: root))
  }

  private static func ref(_ url: URL) throws -> SourceRef {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return SourceRef(relativePath: nil, absolutePath: url.path, size: Int64(values.fileSize ?? 0),
                     modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0))
  }

  private static func requireFFmpeg() throws -> FFmpegLocation {
    try #require(ffmpeg, "ffmpeg is required for the importer tests")
  }

  private static let fake = FFmpegLocation(ffmpeg: URL(filePath: "/nonexistent/ffmpeg"))

  private static func leftovers(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.hasPrefix(".remux.") || $0 == "remux.mov" }
  }

  @Test func mkvRemuxes() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let importer = Importer()
      let start = ContinuousClock.now
      let url = try await importer.playableURL(source: src, ref: ref, ffmpeg: ffmpeg, cache: cache)
      // §10's 2 s under TRIMLAB_TIMING=1; 4× looser in a parallel run, whose load slows the remux.
      #expect(ContinuousClock.now - start < .seconds(Timing.strict ? 2 : 8))
      #expect(url == cache.remuxURL(for: ref))
      #expect(FileManager.default.fileExists(atPath: url.path))
      let facts = try await Prober.facts(for: src, playableURL: url)
      #expect(facts.needsRemux)
    }
  }

  @Test func aviRemuxes() async throws {
    let src = try await Fixtures.url("sample.avi")
    let ffmpeg = try Self.requireFFmpeg()
    try await Self.withRoot { _, cache in
      let url = try await Importer().playableURL(source: src, ref: try Self.ref(src), ffmpeg: ffmpeg, cache: cache)
      let facts = try await Prober.facts(for: src, playableURL: url)
      #expect(facts.needsRemux)
      #expect(url.pathExtension == "mov")
    }
  }

  @Test func secondCallUsesCache() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let importer = Importer()
      let first = try await importer.playableURL(source: src, ref: ref, ffmpeg: ffmpeg, cache: cache)
      #expect(importer.launchCount == 1)
      let second = try await importer.playableURL(source: src, ref: ref, ffmpeg: nil, cache: cache)  // not even needed
      #expect(second == first)
      #expect(importer.launchCount == 1)
    }
  }

  @Test func noFFmpegRefuses() async throws {
    let src = try await Fixtures.url("sample.mkv")
    try await Self.withRoot { _, cache in
      let importer = Importer()
      await #expect(throws: ImportError.needsFFmpeg) {
        _ = try await importer.playableURL(source: src, ref: try Self.ref(src), ffmpeg: nil, cache: cache)
      }
      #expect(importer.launchCount == 0)
    }
  }

  @Test func theoraWontPlay() async throws {
    let src = try await Fixtures.url("theora.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      await #expect(throws: ImportError.formatWontPlay) {
        _ = try await Importer().playableURL(source: src, ref: ref, ffmpeg: ffmpeg, cache: cache)
      }
      #expect(Self.leftovers(cache.dir(for: ref)).isEmpty)
    }
  }

  @Test func argvLogged() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    let (_, logged) = try await MediaLog.capturing {
      try await Self.withRoot { _, cache in
        _ = try await Importer().playableURL(source: src, ref: try Self.ref(src), ffmpeg: ffmpeg, cache: cache)
      }
    }
    #expect(logged.contains { $0.contains("-c copy -map 0") && $0.contains("-movflags +faststart") })
  }

  @Test func movPassesThrough() async throws {
    let src = try await Fixtures.url("portrait_hevc.mov")
    try await Self.withRoot { _, cache in
      let importer = Importer()
      let url = try await importer.playableURL(source: src, ref: try Self.ref(src), ffmpeg: nil, cache: cache)
      #expect(url == URL(fileURLWithPath: src.path))
      #expect(importer.launchCount == 0)
    }
  }

  @Test func unicodeAndSpacedPathRemuxes() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    let work = FileManager.default.temporaryDirectory.appending(path: "trimlab2-spaced-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
    let dir = work.appending(path: "spaced é", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let copy = dir.appending(path: "clip é 1.mkv")
    try FileManager.default.copyItem(at: src, to: copy)
    try await Self.withRoot { _, cache in
      let url = try await Importer().playableURL(source: copy, ref: try Self.ref(copy), ffmpeg: ffmpeg, cache: cache)
      let facts = try await Prober.facts(for: copy, playableURL: url)
      #expect(facts.needsRemux)
    }
  }

  @Test func concurrentCallsShareOneRemux() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let importer = Importer()
      let urls = try await withThrowingTaskGroup(of: URL.self) { group in
        for _ in 0..<4 { group.addTask { try await importer.playableURL(source: src, ref: ref, ffmpeg: ffmpeg, cache: cache) } }
        return try await group.reduce(into: [URL]()) { $0.append($1) }
      }
      #expect(Set(urls).count == 1)
      #expect(importer.launchCount == 1)
    }
  }

  @Test func cancelKillsChildAndLeavesNothing() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let pid = Mutex<pid_t?>(nil)
    // Stands in for ffmpeg: writes the tmp file, then sleeps. `exec` keeps the pid.
    let importer = Importer(
      commandOverride: { _, tmp in ["/bin/sh", "-c", "echo partial > \"$0\"; exec /bin/sleep 60", tmp.path] },
      onLaunch: { p in pid.withLock { $0 = p } })
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let task = Task { try await importer.playableURL(source: src, ref: ref, ffmpeg: Self.fake, cache: cache) }
      let deadline = ContinuousClock.now + .seconds(5)
      while pid.withLock({ $0 }) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      let child = try #require(pid.withLock { $0 })
      #expect(kill(child, 0) == 0)
      let dir = cache.dir(for: ref)
      while Self.leftovers(dir).isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      #expect(!Self.leftovers(dir).isEmpty)  // the tmp really existed mid-run

      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      var gone = false
      for _ in 0..<300 where !gone {
        if kill(child, 0) != 0 && errno == ESRCH { gone = true } else { try await Task.sleep(for: .milliseconds(10)) }
      }
      #expect(gone)
      #expect(Self.leftovers(dir).isEmpty)
    }
  }

  @Test func failureKeepsLastThirtyStderrLinesAndDoesNotBlock() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let importer = Importer(commandOverride: { _, _ in
      ["/usr/bin/awk", "BEGIN { for (i = 0; i < 50000; i++) print \"noise \" i > \"/dev/stderr\"; exit 3 }"]
    })
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      do {
        _ = try await importer.playableURL(source: src, ref: ref, ffmpeg: Self.fake, cache: cache)
        Issue.record("expected remuxFailed")
      } catch let ImportError.remuxFailed(text) {
        let lines = text.split(separator: "\n")
        #expect(lines.count == 30)
        #expect(lines.last == "noise 49999")
        #expect(lines.first == "noise 49970")
      }
      #expect(Self.leftovers(cache.dir(for: ref)).isEmpty)
    }
  }

  // MARK: Phase 3 review

  /// I1: the project folder moved with its clips; the ref's absolute path is stale but `source` resolves.
  @Test func staleAbsolutePathRemuxesTheResolvedSource() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let ffmpeg = try Self.requireFFmpeg()
    try await Self.withRoot { _, cache in
      var ref = try Self.ref(src)
      ref.absolutePath = "/nonexistent/moved away/sample.mkv"
      let url = try await Importer().playableURL(source: src, ref: ref, ffmpeg: ffmpeg, cache: cache)
      #expect(url == cache.remuxURL(for: ref))
      let facts = try await Prober.facts(for: src, playableURL: url)
      #expect(facts.needsRemux)
    }
  }

  /// I1: a non-remux source comes back as the resolved URL, not the ref's path.
  @Test func passThroughReturnsTheResolvedSource() async throws {
    let src = try await Fixtures.url("portrait_hevc.mov")
    try await Self.withRoot { _, cache in
      var ref = try Self.ref(src)
      ref.absolutePath = "/nonexistent/portrait_hevc.mov"
      let url = try await Importer().playableURL(source: src, ref: ref, ffmpeg: nil, cache: cache)
      #expect(url == src)
    }
  }

  /// I2: the cache's paths are reachable without `await`.
  @Test func cachePathsAreSync() async throws {
    let cache = MediaCache(root: URL(filePath: "/tmp/trimlab2-sync-root"))
    let ref = try Self.ref(try await Fixtures.url("sample.mkv"))
    func sync() -> (String, URL, URL) { (cache.key(for: ref), cache.dir(for: ref), cache.remuxURL(for: ref)) }
    let (key, dir, remux) = sync()
    #expect(dir.lastPathComponent == key)
    #expect(remux == dir.appending(path: "remux.mov"))
  }

  /// I3: an ffmpeg that isn't there reads as "needs ffmpeg", not a Cocoa error.
  @Test func missingFFmpegExecutableIsNeedsFFmpeg() async throws {
    let src = try await Fixtures.url("sample.mkv")
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      await #expect(throws: ImportError.needsFFmpeg) {
        _ = try await Importer().playableURL(source: src, ref: ref, ffmpeg: Self.fake, cache: cache)
      }
      #expect(Self.leftovers(cache.dir(for: ref)).isEmpty)
    }
  }

  /// I3: an ffmpeg file without the executable bit is "needs ffmpeg" too.
  @Test func nonExecutableFFmpegIsNeedsFFmpeg() async throws {
    let src = try await Fixtures.url("sample.mkv")
    try await Self.withRoot { root, cache in
      let file = root.appending(path: "ffmpeg")
      try Data("not a program".utf8).write(to: file)
      await #expect(throws: ImportError.needsFFmpeg) {
        _ = try await Importer().playableURL(source: src, ref: try Self.ref(src),
                                             ffmpeg: FFmpegLocation(ffmpeg: file), cache: cache)
      }
    }
  }

  /// I3: a cache folder that can't be made is `remuxFailed`, not a leaked CocoaError.
  @Test func unwritableCacheIsRemuxFailed() async throws {
    let src = try await Fixtures.url("sample.mkv")
    try await Self.withRoot { root, _ in
      let blocker = root.appending(path: "a file")
      try Data().write(to: blocker)
      let cache = MediaCache(root: blocker)  // the root is a file, so no entry folder can be made under it
      do {
        _ = try await Importer(commandOverride: { _, _ in ["/usr/bin/true"] })
          .playableURL(source: src, ref: try Self.ref(src), ffmpeg: Self.fake, cache: cache)
        Issue.record("expected remuxFailed")
      } catch ImportError.remuxFailed(let text) {
        #expect(!text.isEmpty)
      } catch {
        Issue.record("expected ImportError.remuxFailed, got \(type(of: error)): \(error)")
      }
    }
  }

  /// M2: the remux is validated as the tmp file and only then published as remux.mov.
  @Test func validatesBeforePublishing() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let good = try await Fixtures.url("tiny.mp4")
    let publishedAtValidation = Mutex<Bool?>(nil)
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let output = cache.remuxURL(for: ref)
      let importer = Importer(
        commandOverride: { _, tmp in ["/bin/cp", good.path, tmp.path] },
        onValidate: { publishedAtValidation.withLock { $0 = FileManager.default.fileExists(atPath: output.path) } })
      let url = try await importer.playableURL(source: src, ref: ref, ffmpeg: Self.fake, cache: cache)
      #expect(url == output)
      #expect(FileManager.default.fileExists(atPath: output.path))
    }
    #expect(publishedAtValidation.withLock { $0 } == false)
  }

  /// M2: cancelled while validating → CancellationError, the tmp is gone, nothing is published or called broken.
  @Test func cancelDuringValidationKeepsNothingAndSaysCancelled() async throws {
    let src = try await Fixtures.url("sample.mkv")
    let good = try await Fixtures.url("tiny.mp4")
    let validating = Mutex(false)
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let importer = Importer(
        commandOverride: { _, tmp in ["/bin/cp", good.path, tmp.path] },
        onValidate: {
          validating.withLock { $0 = true }
          try? await Task.sleep(for: .seconds(10))  // ends early once the remux is cancelled
        })
      let (_, logged) = try await MediaLog.capturing {
        let task = Task { try await importer.playableURL(source: src, ref: ref, ffmpeg: Self.fake, cache: cache) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !validating.withLock({ $0 }), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(validating.withLock { $0 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
      }
      #expect(!logged.contains { $0.contains("does not play") })
      #expect(Self.leftovers(cache.dir(for: ref)).isEmpty)
    }
  }

  /// M2: a cache hit marks the entry as used for LRU.
  @Test func cacheHitTouchesTheEntry() async throws {
    let src = try await Fixtures.url("sample.mkv")
    try await Self.withRoot { _, cache in
      let ref = try Self.ref(src)
      let dir = cache.dir(for: ref)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data("remuxed".utf8).write(to: cache.remuxURL(for: ref))
      let old = Date(timeIntervalSinceNow: -30 * 86_400)
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
      _ = try await Importer().playableURL(source: src, ref: ref, ffmpeg: nil, cache: cache)
      let used = try #require(try dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      #expect(used.timeIntervalSinceNow > -60)
    }
  }

  @Test func sentences() {
    #expect(ImportError.needsFFmpeg.sentence(ext: "mkv") == "trimlab needs ffmpeg to open .mkv and .avi files. Install it with Homebrew:")
    #expect(ImportError.needsFFmpegCommand == "brew install ffmpeg-full")
    #expect(ImportError.formatWontPlay.sentence(ext: "avi") == "Can't open this .avi: its video format won't play on a Mac.")
  }
}
