import AVFoundation
import CoreGraphics
import Foundation

public enum ExportEvent: Sendable {
  /// `progress` is the last appended video PTS ÷ total (0...1); `eta` in seconds, nil until a rate is known.
  case progress(Double, eta: Double?)
  case done(ExportResult)
}

/// `CGImage` isn't Sendable; it is immutable once made.
public struct ExportResult: @unchecked Sendable {
  public let url: URL
  public let bytes: Int64
  /// Grid frame 0 as written, for the Done sheet. nil (logged) when it couldn't be made; the export still stands.
  public let firstFrame: CGImage?
  public let usedSoftwareEncoder: Bool

  public init(url: URL, bytes: Int64, firstFrame: CGImage?, usedSoftwareEncoder: Bool) {
    self.url = url
    self.bytes = bytes
    self.firstFrame = firstFrame
    self.usedSoftwareEncoder = usedSoftwareEncoder
  }
}

/// §5.5 step 7. Each case reads as a plain sentence for the export sheet (§4.9 Error).
public enum ExportError: Error, Equatable, Sendable {
  case diskFull
  /// The file name of the clip that couldn't be read, when known.
  case sourceUnreadable(String?)
  case encoderFailed
  /// Nothing was written for this many seconds: the stall watchdog stopped the export rather than let it hang.
  case stalled(seconds: Int)
  /// The detail goes in the sheet's Details disclosure, not the sentence.
  case other(String)
  /// Replace: the finished file couldn't be put over `name`. `oldKept`: the file that was there still is. `keptAs`: the
  /// name the new export was kept under instead, if it could be.
  case notReplaced(name: String, oldKept: Bool, keptAs: String?)

  public var sentence: String {
    switch self {
    case .diskFull: "The disk is full."
    case .sourceUnreadable(let name?): "\(name) can't be read any more. Check that its drive is connected."
    case .sourceUnreadable(nil): "A clip can't be read any more. Check that its drive is connected."
    case .encoderFailed: "The video encoder stopped."
    case .stalled(let seconds):
      "The export made no progress for \(seconds) second\(seconds == 1 ? "" : "s"), so it was stopped."
    case .other: "Something went wrong while saving."
    case .notReplaced(let name, true, _): "\(name) couldn't be replaced. The old file is still there."
    case .notReplaced(let name, false, _): "\(name) couldn't be replaced."
    }
  }

  /// The technical detail behind `.other`, for the Details disclosure.
  public var detail: String? {
    switch self {
    case .other(let detail): detail
    case .notReplaced(_, _, let keptAs?): "The new export was kept as \(keptAs)."
    default: nil
    }
  }
}

/// The system error an `ExportError` was mapped from (AVFoundation's, VideoToolbox's, POSIX's), for the Details
/// disclosure (§4.9 Error: domain, code, description). An `ExportError` raised by trimlab itself has none.
public struct ExportCause: Equatable, Sendable {
  public let domain: String
  public let code: Int
  /// The error's own description, then each underlying error's as "domain code: description".
  public let description: String

  public init(domain: String, code: Int, description: String) {
    self.domain = domain
    self.code = code
    self.description = description
  }

  /// nil for an `ExportError` or a cancellation: those aren't system errors.
  public init?(_ error: any Error) {
    if error is ExportError || error is CancellationError { return nil }
    let ns = error as NSError
    var text = ns.localizedDescription
    var under = ns.userInfo[NSUnderlyingErrorKey] as? NSError
    while let u = under {
      text += " (\(u.domain) \(u.code): \(u.localizedDescription))"
      under = u.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    self.init(domain: ns.domain, code: ns.code, description: text)
  }
}

// MARK: - error mapping

extension ExportError {
  /// Maps any error from the pipeline. `readerSide`: the reader failed, so an unknown error means a source.
  init(_ error: any Error, readerSide: Bool = false) {
    if let e = error as? ExportError {
      self = e
      return
    }
    let ns = error as NSError
    if Self.isDiskFull(ns) {
      self = .diskFull
      return
    }
    // The writer's VideoToolbox failures arrive as AVError -11800 / -11821 over an OSStatus in -129xx, or in
    // VideoToolbox's own domain. The reader only decodes, so there the same codes mean a bad source.
    if !readerSide, Self.isVideoToolbox(ns) {
      self = .encoderFailed
      return
    }
    if ns.domain == AVFoundationErrorDomain {
      switch AVError.Code(rawValue: ns.code) {
      case .encoderNotFound?, .encoderTemporarilyUnavailable?:
        self = .encoderFailed
        return
      case .decoderNotFound?, .decoderTemporarilyUnavailable?, .fileFormatNotRecognized?, .fileFailedToParse?,
           .failedToLoadMediaData?, .noSourceTrack?, .undecodableMediaData?, .contentIsUnavailable?:
        self = .sourceUnreadable(nil)
        return
      default: break
      }
    }
    self = readerSide ? .sourceUnreadable(nil) : .other("The export failed: \(ns.localizedDescription)")
  }

  /// `e` or an error under it is a VideoToolbox status (-12999...-12900) or from VideoToolbox's domain.
  private static func isVideoToolbox(_ e: NSError) -> Bool {
    if e.domain == NSOSStatusErrorDomain, (-12999 ... -12900).contains(e.code) { return true }
    if e.domain.lowercased().contains("videotoolbox") { return true }
    if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isVideoToolbox(underlying) }
    return false
  }

  private static func isDiskFull(_ e: NSError) -> Bool {
    if e.domain == AVFoundationErrorDomain, e.code == AVError.Code.diskFull.rawValue { return true }
    if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOSPC) { return true }
    if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteOutOfSpaceError { return true }
    if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
    return false
  }
}
