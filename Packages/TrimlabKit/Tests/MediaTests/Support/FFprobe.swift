import Foundation

/// ffprobe as the test oracle (SPEC §2). Missing ffprobe fails the test, never skips it.
enum FFprobe {
  static let binDir = "/opt/homebrew/opt/ffmpeg-full/bin"
  static let path = binDir + "/ffprobe"
  static let ffmpegPath = binDir + "/ffmpeg"

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  struct FrameInfo: Sendable, Equatable {
    let ptsTime: Double
    let keyFrame: Bool
    let pktSize: Int
  }

  static func streams(_ url: URL) async throws -> [[String: Any]] {
    let json = try await json(["-show_streams", url.path])
    return json["streams"] as? [[String: Any]] ?? []
  }

  static func format(_ url: URL) async throws -> [String: Any] {
    let json = try await json(["-show_format", url.path])
    return json["format"] as? [String: Any] ?? [:]
  }

  static func frames(_ url: URL, stream: String = "v:0") async throws -> [FrameInfo] {
    let json = try await json([
      "-select_streams", stream, "-show_entries", "frame=pts_time,key_frame,pkt_size", url.path,
    ])
    let raw = json["frames"] as? [[String: Any]] ?? []
    return raw.map {
      FrameInfo(
        ptsTime: Double($0["pts_time"] as? String ?? "") ?? .nan,
        keyFrame: ($0["key_frame"] as? Int) == 1,
        pktSize: Int($0["pkt_size"] as? String ?? "") ?? 0)
    }
  }

  /// Luma average and standard deviation of the frame at `at`, from the raw Y plane at native
  /// depth (ffmpeg `extractplanes=y`, no range conversion), on the 8-bit code-value scale
  /// (limited range, 16...235): 10-bit values are divided by 4.
  static func signalstats(_ url: URL, at t: Double) async throws -> (yavg: Double, ystddev: Double) {
    let depth = try await bitDepth(url)
    let wide = depth > 8
    let data = try await runData(
      ffmpegPath,
      [
        "-v", "error", "-ss", "\(t)", "-i", url.path, "-frames:v", "1", "-vf", "extractplanes=y",
        "-pix_fmt", wide ? "gray10le" : "gray", "-f", "rawvideo", "-",
      ])
    let scale = wide ? 4.0 : 1.0
    var sum = 0.0, sumSq = 0.0
    var n = 0
    if wide {
      var i = 0
      while i + 1 < data.count {
        let v = Double(UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8) / scale
        sum += v; sumSq += v * v; n += 1; i += 2
      }
    } else {
      for byte in data { let v = Double(byte); sum += v; sumSq += v * v }
      n = data.count
    }
    guard n > 0 else { throw Failure(description: "ffmpeg produced no Y plane for \(url.lastPathComponent)") }
    let mean = sum / Double(n)
    return (mean, max(0, sumSq / Double(n) - mean * mean).squareRoot())
  }

  /// v1's HDR → SDR chain (trimlab/core/filters.py `HDR_ZSCALE`), the reference for the SDR conversion.
  static let v1ToneMap = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,"
    + "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

  /// The 8-bit Y plane (code values, no range conversion) of the frame at `t`, after `filter` when given.
  static func lumaPlane(_ url: URL, at t: Double, filter: String? = nil) async throws -> (y: [UInt8], width: Int) {
    let v = try await streams(url).first { ($0["codec_type"] as? String) == "video" }
    guard let width = v?["width"] as? Int else { throw Failure(description: "no width for \(url.lastPathComponent)") }
    let graph = (filter.map { $0 + "," } ?? "") + "extractplanes=y"
    let data = try await runData(
      ffmpegPath,
      ["-v", "error", "-ss", "\(t)", "-i", url.path, "-frames:v", "1", "-vf", graph, "-pix_fmt", "gray",
       "-f", "rawvideo", "-"])
    guard !data.isEmpty, data.count % width == 0 else {
      throw Failure(description: "ffmpeg Y plane of \(url.lastPathComponent): \(data.count) bytes")
    }
    return ([UInt8](data), width)
  }

  /// Cross-check: YAVG as reported by ffprobe's `signalstats` filter, scaled to 8 bits.
  static func signalstatsTagYAVG(_ url: URL, at t: Double) async throws -> Double {
    let scale = Double(1 << (try await bitDepth(url) - 8))
    let movie = "movie=\(escapeFilter(url.path)):seek_point=\(t),signalstats"
    return try await statValue(movie, tag: "lavfi.signalstats.YAVG") / scale
  }

  /// `nb_read_frames` of the first video stream: every frame decoded and counted.
  static func countedFrames(_ url: URL) async throws -> Int {
    let json = try await json(["-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames", url.path])
    let s = (json["streams"] as? [[String: Any]])?.first
    guard let n = (s?["nb_read_frames"] as? String).flatMap(Int.init) else {
      throw Failure(description: "no nb_read_frames for \(url.lastPathComponent)")
    }
    return n
  }

  /// signalstats YAVG (8-bit code values) of every video frame, with its PTS, in presentation order.
  static func frameYAVGs(_ url: URL) async throws -> [(pts: Double, yavg: Double)] {
    let json = try await json([
      "-f", "lavfi", "-i", "movie=\(escapeFilter(url.path)),signalstats",
      "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG",
    ])
    let raw = json["frames"] as? [[String: Any]] ?? []
    return raw.compactMap {
      guard let pts = Double($0["pts_time"] as? String ?? ""),
        let y = (($0["tags"] as? [String: Any])?["lavfi.signalstats.YAVG"] as? String).flatMap(Double.init)
      else { return nil }
      return (pts, y)
    }
  }

  /// Top-level box types, read directly from the file (no ffprobe).
  static func atomOrder(_ url: URL) throws -> [String] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    var offset: UInt64 = 0
    var types: [String] = []
    while offset + 8 <= size {
      try handle.seek(toOffset: offset)
      guard let head = try handle.read(upToCount: 8), head.count == 8 else { break }
      var length = UInt64(head[0]) << 24 | UInt64(head[1]) << 16 | UInt64(head[2]) << 8 | UInt64(head[3])
      types.append(String(decoding: head[4..<8], as: UTF8.self))
      if length == 1 {
        guard let ext = try handle.read(upToCount: 8), ext.count == 8 else { break }
        length = ext.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      } else if length == 0 {
        break  // box runs to end of file
      }
      guard length >= 8 else { break }
      offset += length
    }
    return types
  }

  // MARK: - Plumbing

  private static func bitDepth(_ url: URL) async throws -> Int {
    let v = try await streams(url).first { ($0["codec_type"] as? String) == "video" }
    let raw = (v?["bits_per_raw_sample"] as? String).flatMap(Int.init)
    if let raw, raw > 8 { return raw }
    let fmt = v?["pix_fmt"] as? String ?? ""
    return fmt.contains("10") ? 10 : fmt.contains("12") ? 12 : 8
  }

  private static func escapeFilter(_ path: String) -> String {
    // Single-quote the path for the filtergraph; escape embedded quotes and colons.
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func statValue(_ graph: String, tag: String) async throws -> Double {
    let out = try await run([
      "-v", "error", "-f", "lavfi", "-i", graph, "-read_intervals", "%+#1",
      "-show_entries", "frame_tags=\(tag)", "-of", "default=nw=1:nk=0",
    ])
    for line in out.split(separator: "\n") {
      if let r = line.range(of: "\(tag)="), let v = Double(line[r.upperBound...]) { return v }
    }
    throw Failure(description: "no \(tag) in ffprobe output: \(out)")
  }

  private static func json(_ args: [String]) async throws -> [String: Any] {
    let out = try await run(["-v", "error", "-of", "json"] + args)
    guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
      throw Failure(description: "ffprobe returned non-object JSON")
    }
    return obj
  }

  private static func run(_ args: [String]) async throws -> String {
    String(decoding: try await runData(path, args), as: UTF8.self)
  }

  private static func runData(_ tool: String, _ args: [String]) async throws -> Data {
    guard FileManager.default.isExecutableFile(atPath: tool) else {
      throw Failure(description: "ffprobe not found at \(binDir)")
    }
    // The child is awaited on its own thread (never a cooperative-pool thread).
    return try await OffPool.run { try runBlocking(tool, args) }
  }

  private static func runBlocking(_ tool: String, _ args: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Drain stderr off-thread so a full pipe cannot stall stdout.
    nonisolated(unsafe) var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      errData = err.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    group.wait()
    guard process.terminationStatus == 0 else {
      throw Failure(
        description: "\(tool) \(args.joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self))")
    }
    return data
  }
}
