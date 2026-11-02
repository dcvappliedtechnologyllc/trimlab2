import Foundation

/// Why a `.trimlab` file wasn't opened. Either way the file is left exactly as it was (§8.2).
public enum ProjectError: Error, Equatable {
  /// Made by a newer build (its schema); refused rather than opened and saved back without its new fields.
  case newerVersion(Int)
  /// Not a project file, truncated, or damaged.
  case unreadable

  /// The plain sentence the editor shows (§8.2, Task 31).
  public var message: String {
    switch self {
    case .newerVersion: "This Reel was made by a newer version of trimlab."
    case .unreadable: "This Reel file can't be read."
    }
  }
}

/// The `.trimlab` file (§8.2, §8.3): the `Reel` as pretty, sorted-key JSON with `"schema"` and `"app"` at the top.
/// Dates are seconds since 2001-01-01 as a JSON number (`.deferredToDate`, pre-flight F6), so sub-second
/// modification times survive for change detection.
public enum ProjectCodec {
  /// Written next to the Reel's keys; never kept in `Reel.extra`.
  public static let app = "trimlab 2.0"

  public static func encode(_ r: Reel) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .deferredToDate
    // JSON can't hold NaN or infinity; spelling them out makes encoding total, so a save can't fail here.
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf",
                                                                  nan: "nan")
    do {
      return try encoder.encode(Envelope(reel: r))
    } catch {
      preconditionFailure("a Reel always encodes: \(error)")
    }
  }

  public static func decode(_ data: Data) throws(ProjectError) -> Reel {
    try decode(data, steps: Migrations.steps, current: Reel.currentSchema)
  }

  /// The seam for migration tests (F8: a parameter, not a mutable static).
  static func decode(_ data: Data, steps: [Int: Migrations.Step],
                     current: Int = Reel.currentSchema) throws(ProjectError) -> Reel {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate

    // The schema is read first: a newer file may be shaped nothing like this one.
    guard let schema = try? decoder.decode(Header.self, from: data).schema, schema >= 0 else { throw .unreadable }
    if schema > current { throw .newerVersion(schema) }

    var body = data
    if schema < current {
      guard var object = try? decoder.decode(JSONObject.self, from: data) else { throw .unreadable }
      for n in schema..<current {
        guard let step = steps[n] else { throw .unreadable }
        object = step(object)
        object["schema"] = .number(Double(n + 1))
      }
      guard let migrated = try? JSONEncoder().encode(object) else { throw .unreadable }
      body = migrated
    }

    guard var reel = try? decoder.decode(Reel.self, from: body) else { throw .unreadable }
    reel.extra["app"] = nil  // Task 9 carry: the app tag belongs to the file, not the Reel
    guard reel.clips.allSatisfy(TimeBounds.isSane) else { throw .unreadable }  // before any time arithmetic
    for i in reel.clips.indices { reel.clips[i].join = reel.clips[i].join.snapped }
    guard TimeBounds.reelIsSane(reel.clips) else { throw .unreadable }
    reel.clips = reel.clips.map(sanitised)
    return reel
  }

  private struct Header: Decodable { let schema: Int }

  /// The Reel's own keys plus `"app"`, in one object.
  private struct Envelope: Encodable {
    let reel: Reel
    func encode(to encoder: any Encoder) throws {
      var r = reel
      r.schema = Reel.currentSchema  // a build only ever writes its own schema
      r.extra["app"] = nil
      try r.encode(to: encoder)
      var c = encoder.container(keyedBy: DynamicKey.self)
      try c.encode(ProjectCodec.app, forKey: DynamicKey("app"))
    }
  }
}

/// Load-time range check (fix round 1): RationalTime arithmetic traps on overflow, and sanitising floors and
/// subtracts every clip time, so a damaged file must be refused before any arithmetic runs.
enum TimeBounds {
  static let maxMagnitude: Int64 = 1 << 40
  static let timescales: ClosedRange<Int32> = 1...1_000_000_000
  static let maxDuration = RationalTime(86_400, 1)
  static let maxFrame = RationalTime(1, 1)
  static let displaySides: ClosedRange<Int> = 2...16_384
  static let rotations: Set<Int> = [0, 90, 180, 270]
  /// The lcm of one clip's timescales (with the 1/2 s minimum span). Keeping it ≤ 10^7 keeps every product in that
  /// clip's sanitising and trim arithmetic below Int64 (≤ 86 400 s × 10^7 × 10^7). It says nothing about arithmetic
  /// across clips (the plan's running total): that is `reelIsSane`'s bound.
  static let maxCommonTimescale: Int64 = 10_000_000
  /// The lcm of every time in the Reel (with the 1/2 s span and 1/4 s fade). Keeping it ≤ 10^8 keeps every
  /// timescale the plan builds (sums, differences, halved fades) inside Int32, and 1000 clips × 24 h at 10^8
  /// inside Int64.
  static let maxReelTimescale: Int64 = 100_000_000
  static let maxClips = 1000

  static func isSane(_ clip: ReelClip) -> Bool {
    let f = clip.facts
    let times = [f.duration, f.frameDuration, clip.inTime, clip.outTime]
    guard times.allSatisfy({ $0.value.magnitude < maxMagnitude.magnitude && timescales.contains($0.timescale) })
    else { return false }
    guard f.duration > .zero, f.duration <= maxDuration else { return false }
    guard f.frameDuration > .zero, f.frameDuration <= maxFrame else { return false }
    guard displaySides.contains(f.displayWidth), displaySides.contains(f.displayHeight),
          rotations.contains(f.rotation) else { return false }
    return commonTimescale(of: times, seed: 2, isAtMost: maxCommonTimescale)  // 2: Limits.minSpan's timescale
  }

  /// Phase 2 review: every clip can pass `isSane` while the Reel's lcm still overflows the plan's Int32 timescales.
  /// Checked on load and by `apply` for edits that bring in new times (insert, relink, probed).
  static func reelIsSane(_ clips: [ReelClip]) -> Bool {
    guard clips.count <= maxClips else { return false }
    let times = clips.lazy.flatMap { clip -> [RationalTime] in
      var t = [clip.facts.duration, clip.facts.frameDuration, clip.inTime, clip.outTime]
      if case .crossfade(let fade) = clip.join { t.append(fade) }
      return t
    }
    return commonTimescale(of: times, seed: 4, isAtMost: maxReelTimescale)  // 4 = lcm(2, 4): minSpan, shortFade
  }

  /// Whether the lcm of `seed` and every time's timescale stays ≤ `limit` (never overflowing on the way).
  private static func commonTimescale(of times: some Sequence<RationalTime>, seed: Int64,
                                      isAtMost limit: Int64) -> Bool {
    var common = seed
    for t in times {
      let ts = Int64(t.timescale)
      guard ts > 0 else { return false }
      let (scaled, overflow) = (common / IntMath.gcd(common, ts)).multipliedReportingOverflow(by: ts)
      guard !overflow, scaled <= limit else { return false }
      common = scaled
    }
    return true
  }
}

/// Why a project save didn't happen. The file on disk is unchanged in every case.
public enum ProjectWriteError: Error, Equatable {
  /// Something that isn't an openable project of this build is already there: a newer-schema Reel, or a file
  /// that can't be read. It's never replaced (§8.2; Task 31 `refusedProjectIsNeverAutosaved`).
  case wouldReplaceRefusedFile
  /// A different Reel (another `id`) is saved there. It's never replaced (ruling, fix round 1).
  case wouldReplaceAnotherReel
  /// The write itself failed (folder gone, disk full, read-only volume). The text is for the log only.
  case failed(String)

  /// The plain sentence for the editor: no paths, no system error text.
  public var message: String {
    switch self {
    case .wouldReplaceRefusedFile: "A Reel file trimlab can't open is already there, so trimlab left it alone."
    case .wouldReplaceAnotherReel: "A different Reel is already saved there, so trimlab left it alone."
    case .failed: "The Reel couldn't be saved. Check that its folder is still there and the disk has space."
    }
  }

  /// The detail for the log file.
  public var logDetail: String {
    switch self {
    case .wouldReplaceRefusedFile: "refused: existing file is newer-schema or unreadable"
    case .wouldReplaceAnotherReel: "refused: existing file holds a different Reel id"
    case .failed(let detail): "write failed: \(detail)"
    }
  }
}

/// Why renaming a Reel's file (`ProjectFile.move`) didn't happen. Nothing was changed on the disk.
public enum ProjectMoveError: Error, Equatable, Sendable {
  /// A file, folder or link is already at the new name (any case, as APFS compares by default).
  case taken
  /// Nothing is at the old name: the file was moved or deleted outside trimlab, or never landed.
  case noFile
  /// The file at the old name isn't this Reel's (another Reel's, or one this build can't read): it's left alone.
  case anotherReel
  /// The rename itself failed. The text is for the log only.
  case failed(String)
}

/// Reading and atomically writing `.trimlab` files. The app's live `ProjectStore` writes through here.
public enum ProjectFile {
  /// A temp file this old is left over from a crash, not a write in flight.
  static let staleTempAge: TimeInterval = 60

  public static func read(_ url: URL) throws(ProjectError) -> Reel {
    guard let data = try? Data(contentsOf: url) else { throw .unreadable }
    return try ProjectCodec.decode(data)
  }

  /// Atomic save (§8.2): a temp file in the same folder, flushed to the disk (`F_FULLFSYNC`), then swapped in with
  /// `FileManager.replaceItemAt`, which keeps the file's creation date, tags and extended attributes. A symlink is
  /// written through, never replaced. An existing file is replaced only if this build can open it and it holds the
  /// same Reel (`reelID`).
  public static func write(_ data: Data, to url: URL, reelID: UUID) throws(ProjectWriteError) {
    let fm = FileManager.default
    let target = url.resolvingSymlinksInPath()
    let exists = fm.fileExists(atPath: target.path)
    if exists {
      guard let existing = try? Data(contentsOf: target), let reel = try? ProjectCodec.decode(existing) else {
        throw .wouldReplaceRefusedFile
      }
      guard reel.id == reelID else { throw .wouldReplaceAnotherReel }
    }

    let folder = target.deletingLastPathComponent()
    let name = target.lastPathComponent
    sweepStaleTemps(named: name, in: folder)
    let temp = folder.appending(path: ".\(name).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
    guard fm.createFile(atPath: temp.path, contents: nil) else {
      throw .failed("can't create \(temp.path)")
    }
    do {
      let handle = try FileHandle(forWritingTo: temp)
      defer { try? handle.close() }
      try handle.write(contentsOf: data)
      fullSync(handle.fileDescriptor)
    } catch {
      try? fm.removeItem(at: temp)
      throw .failed("writing \(temp.path): \(error)")
    }

    if exists {
      do {
        _ = try fm.replaceItemAt(target, withItemAt: temp)
      } catch {
        try? fm.removeItem(at: temp)
        throw .failed("replacing \(target.path): \(error)")
      }
    } else if rename(temp.path, target.path) != 0 {
      let reason = String(cString: strerror(errno))
      try? fm.removeItem(at: temp)
      throw .failed("renaming to \(target.path): \(reason)")
    }
    syncFolder(folder)
  }

  /// Renames the Reel's file in its folder (the header's rename, §6.1), never replacing anything: `renamex_np` with
  /// `RENAME_EXCL` refuses whatever is at `to` (a file, a folder, a link, dangling or not) in the same system call, so
  /// nothing can slip in between a check and the rename. A volume without `RENAME_EXCL` (exFAT, some network shares:
  /// `ENOTSUP` or `EINVAL`) gets the portable form: an `O_EXCL` placeholder claims `to`, and a plain rename replaces
  /// only that. A change of case only (`to` is `from` itself on a case-insensitive volume) is a plain rename. A
  /// symlink at `from` is renamed itself, not its target. With `reelID`, a file at `from` that isn't that Reel's
  /// (another Reel's, or one this build can't read) is left alone (`.anotherReel`), as `write` refuses it.
  public static func move(_ from: URL, to: URL, reelID: UUID? = nil) throws(ProjectMoveError) {
    try move(from, to: to, reelID: reelID) { a, b in renamex_np(a, b, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
  }

  /// `move`, with the exclusive rename injectable (it returns 0 or the errno), so tests can play an exFAT volume.
  static func move(_ from: URL, to: URL, reelID: UUID?,
                   exclusiveRename: (String, String) -> Int32) throws(ProjectMoveError) {
    var source = stat(), target = stat()
    guard lstat(from.path, &source) == 0 else { throw .noFile }
    if let reelID {
      guard let data = try? Data(contentsOf: from), let reel = try? ProjectCodec.decode(data), reel.id == reelID else {
        throw .anotherReel
      }
    }
    let sameFile = lstat(to.path, &target) == 0 && target.st_dev == source.st_dev && target.st_ino == source.st_ino
    if sameFile, from.path == to.path { return }
    if sameFile {
      guard rename(from.path, to.path) == 0 else { throw moveError(errno, from, to) }
    } else {
      let code = exclusiveRename(from.path, to.path)
      if code == ENOTSUP || code == EINVAL {
        try placeholderRename(from, to: to)
      } else if code != 0 {
        throw moveError(code, from, to)
      }
    }
    syncFolder(to.deletingLastPathComponent())
  }

  /// Without `RENAME_EXCL`: `O_CREAT | O_EXCL` fails on anything at `to`, a dangling link included, so the name is
  /// ours before the plain rename replaces the empty placeholder. A rename that fails takes the placeholder away.
  private static func placeholderRename(_ from: URL, to: URL) throws(ProjectMoveError) {
    let fd = open(to.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard fd >= 0 else { throw moveError(errno, from, to) }
    _ = close(fd)
    guard rename(from.path, to.path) == 0 else {
      let code = errno
      _ = unlink(to.path)
      throw moveError(code, from, to)
    }
  }

  private static func moveError(_ code: Int32, _ from: URL, _ to: URL) -> ProjectMoveError {
    switch code {
    case EEXIST: .taken
    case ENOENT: .noFile
    default: .failed("renaming \(from.path) to \(to.path): \(String(cString: strerror(code)))")
    }
  }

  /// `F_FULLFSYNC` asks the drive itself to flush; plain `fsync` is the fallback where it isn't supported.
  private static func fullSync(_ fd: Int32) {
    if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
  }

  /// Best effort: makes the rename itself durable.
  private static func syncFolder(_ folder: URL) {
    let fd = open(folder.path, O_RDONLY)
    guard fd >= 0 else { return }
    fullSync(fd)
    _ = close(fd)
  }

  /// Removes `.<name>.*.tmp` files older than `staleTempAge` (a crash mid-save). Younger ones may be in flight.
  private static func sweepStaleTemps(named name: String, in folder: URL) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
    let cutoff = Date(timeIntervalSinceNow: -staleTempAge)
    for entry in entries where entry.hasPrefix(".\(name).") && entry.hasSuffix(".tmp") {
      let path = folder.appending(path: entry, directoryHint: .notDirectory).path
      guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
            modified < cutoff else { continue }
      try? fm.removeItem(atPath: path)
    }
  }
}
