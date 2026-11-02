import AVFoundation
import CoreMedia
import Foundation
import TrimlabModel

public enum ProbeError: Error, Equatable, Sendable {
  case unsupportedType, unplayable, noVideo

  public func sentence(fileName: String) -> String {
    switch self {
    case .unsupportedType: "Can't open \(fileName). trimlab opens video files."
    case .unplayable, .noVideo: "Can't open \(fileName). trimlab can't play this kind of file."
    }
  }
}

public enum Prober {
  public static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v", "mts", "mkv", "avi"]
  public static let remuxExtensions: Set<String> = ["mkv", "avi"]

  /// A clip's real nominal frame durations, including high-fps and slo-mo rates (100, 119.88, 120, 239.76, 240).
  /// The §5.1 set and its 60 fps cap apply only to the Planner's output rate, not to what a clip is.
  static let nominalFrameDurations: [RationalTime] = [
    RationalTime(1001, 24000), RationalTime(1, 24), RationalTime(1, 25), RationalTime(1001, 30000),
    RationalTime(1, 30), RationalTime(1, 50), RationalTime(1001, 60000), RationalTime(1, 60),
    RationalTime(1, 100), RationalTime(1001, 120000), RationalTime(1, 120),
    RationalTime(1001, 240000), RationalTime(1, 240),
  ]
  static let fallbackFrameDuration = RationalTime(1, 30)
  static let displaySides: ClosedRange<Int> = 2...16_384

  static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

  // MARK: facts

  public static func facts(for url: URL, playableURL: URL? = nil) async throws(ProbeError) -> ClipFacts {
    guard isSupported(url) else { throw .unsupportedType }
    let asset = AVURLAsset(url: playableURL ?? url,
                           options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    do {
      return try await load(asset, url: url)
    } catch let e as ProbeError {
      throw e
    } catch {
      MediaLog.note("probe failed for \(url.lastPathComponent): \(error.localizedDescription)")
      throw .unplayable
    }
  }

  private static func load(_ asset: AVURLAsset, url: URL) async throws -> ClipFacts {
    let rawDuration = try await asset.load(.duration)
    guard rawDuration.isValid, rawDuration.isNumeric, rawDuration.timescale > 0, rawDuration.value > 0 else {
      throw ProbeError.unplayable
    }
    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ProbeError.noVideo }
    let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

    let (minFrame, nominalRate, naturalSize, transform, descriptions, dataRate) = try await video.load(
      .minFrameDuration, .nominalFrameRate, .naturalSize, .preferredTransform, .formatDescriptions,
      .estimatedDataRate)

    let frameDuration = snappedFrameDuration(minFrame: minFrame, nominalRate: nominalRate, name: url.lastPathComponent)
    guard let duration = floored(rawDuration, onto: frameDuration), duration > .zero else {
      throw ProbeError.unplayable
    }

    let size = naturalSize.applying(transform)
    guard let width = side(size.width), let height = side(size.height) else { throw ProbeError.unplayable }

    return ClipFacts(
      duration: duration, frameDuration: frameDuration, displayWidth: width, displayHeight: height,
      rotation: rotation(of: transform), videoCodec: codec(of: descriptions.first),
      hasAudio: hasAudio, hdr: hdr(of: descriptions.first),
      bitrate: dataRate.isFinite && dataRate > 0 ? Int(min(dataRate, Float(Int32.max))) : 0,
      captureDate: await captureDate(of: asset), needsRemux: remuxExtensions.contains(url.pathExtension.lowercased()))
  }

  // MARK: pure helpers (internal for tests)

  /// The §5.1 frame duration nearest `minFrame` (within 2 %), else nearest the nominal rate, else 1/30 with a note.
  static func snappedFrameDuration(minFrame: CMTime, nominalRate: Float, name: String) -> RationalTime {
    if minFrame.isValid, minFrame.isNumeric, minFrame.value > 0, minFrame.timescale > 0,
       let hit = nearest(fps: Double(minFrame.timescale) / Double(minFrame.value)) { return hit }
    if nominalRate.isFinite, nominalRate > 0, let hit = nearest(fps: Double(nominalRate)) { return hit }
    MediaLog.note("frame rate of \(name) is not a nominal rate; using 1/30")
    return fallbackFrameDuration
  }

  private static func nearest(fps: Double) -> RationalTime? {
    guard fps.isFinite, fps > 0 else { return nil }
    let best = nominalFrameDurations.min { abs(1 / $0.seconds - fps) < abs(1 / $1.seconds - fps) }
    guard let best, abs(1 / best.seconds - fps) / (1 / best.seconds) <= 0.02 else { return nil }
    return best
  }

  /// `t` on `fd`'s timescale, rounded down so it never exceeds `t`. Nil for a non-numeric time or overflow.
  static func floored(_ t: CMTime, onto fd: RationalTime) -> RationalTime? {
    guard t.isValid, t.isNumeric, t.timescale > 0, t.value >= 0 else { return nil }
    let scaled = Int128(t.value) * Int128(fd.timescale) / Int128(t.timescale)  // truncation = floor for value >= 0
    guard scaled <= Int128(Int64.max) else { return nil }
    return RationalTime(Int64(scaled), fd.timescale)
  }

  private static func side(_ v: CGFloat) -> Int? {
    let a = abs(v).rounded()
    guard a.isFinite, a <= 1_000_000 else { return nil }
    return displaySides.contains(Int(a)) ? Int(a) : nil
  }

  /// Counter-clockwise degrees to turn the stored picture upright, ffprobe's `rotation` convention (the fixture
  /// oracle): the negated angle of `preferredTransform`, snapped to a quarter turn. A mirrored transform
  /// (negative determinant) is un-mirrored horizontally first, so a plain mirror is 0, not 180. This is display
  /// metadata only: the compositor orients from `preferredTransform` itself.
  static func rotation(of t: CGAffineTransform) -> Int {
    let mirrored = Double(t.a) * Double(t.d) - Double(t.b) * Double(t.c) < 0
    let (a, b) = mirrored ? (-Double(t.a), -Double(t.b)) : (Double(t.a), Double(t.b))
    let degrees = -atan2(b, a) * 180 / .pi
    guard degrees.isFinite else { return 0 }
    let quarter = Int((degrees / 90).rounded())
    return ((quarter % 4) + 4) % 4 * 90
  }

  private static func codec(of d: CMFormatDescription?) -> String {
    guard let d else { return "unknown" }
    return codecName(CMFormatDescriptionGetMediaSubType(d))
  }

  static func codecName(_ subType: FourCharCode) -> String {
    switch subType {
    case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, 0x6865_7631 /* hev1 */: return "hevc"
    case kCMVideoCodecType_H264, 0x6176_6333 /* avc3 */: return "h264"
    case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
         kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444,
         kCMVideoCodecType_AppleProRes4444XQ: return "prores"
    case kCMVideoCodecType_MPEG4Video: return "mpeg4"
    case kCMVideoCodecType_AV1: return "av1"
    case kCMVideoCodecType_VP9: return "vp9"
    case kCMVideoCodecType_JPEG: return "mjpeg"
    case let other:
      let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: other >> UInt32($0)) }
      let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
      return s.isEmpty ? "unknown" : s
    }
  }

  private static func hdr(of d: CMFormatDescription?) -> HDRKind {
    guard let d, let tf = CMFormatDescriptionGetExtension(
      d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return .sdr }
    if tf == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return .hlg }
    if tf == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
    return .sdr
  }

  private static func captureDate(of asset: AVURLAsset) async -> Date? {
    guard let item = try? await asset.load(.creationDate) else { return nil }
    return try? await item.load(.dateValue)
  }

  // MARK: source ref and import item

  public static func sourceRef(for url: URL, projectFolder: URL?) throws -> SourceRef {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    var relative: String?
    if let folder = projectFolder {
      let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
      let file = url.resolvingSymlinksInPath().standardizedFileURL.path
      let prefix = base.hasSuffix("/") ? base : base + "/"
      if file.hasPrefix(prefix) { relative = String(file.dropFirst(prefix.count)) }
    }
    return SourceRef(relativePath: relative, absolutePath: url.path, size: Int64(values.fileSize ?? 0),
                     modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0))
  }

  /// Dates only; ordering lives in `ImportOrder`.
  public static func importItem(for url: URL) async -> ImportItem {
    let asset = AVURLAsset(url: url)
    let capture = await captureDate(of: asset)
    let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    return ImportItem(url: url, captureDate: capture, fileCreated: created)
  }
}
