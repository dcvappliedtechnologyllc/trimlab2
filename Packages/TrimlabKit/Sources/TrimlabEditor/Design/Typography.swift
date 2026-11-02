import CoreText
import Foundation
import OSLog
import Synchronization
import SwiftUI

private let fontLog = Logger(subsystem: "com.dcv.trimlab2", category: "fonts")

/// Inter's static weights (the UI face).
public enum Weight: Sendable, CaseIterable {
  case regular, medium, semibold, bold

  var postScriptName: String {
    switch self {
    case .regular: "Inter-Regular"
    case .medium: "Inter-Medium"
    case .semibold: "Inter-SemiBold"
    case .bold: "Inter-Bold"
    }
  }
}

/// The two bundled faces (SPEC §6.1): Inter for all UI text, Bodoni Moda only for the wordmark and the
/// "Drop clips." / "Saved." moments. No system font is ever visible.
public enum TLFont: Sendable, Equatable {
  case inter(Weight)
  case bodoni(italic: Bool, weight: Int)

  /// Bodoni Moda's `opsz` axis range; the optical size follows the point size, clamped (v1: `font-optical-sizing: auto`).
  static let opticalSizeRange: ClosedRange<CGFloat> = 6...96
  /// Bodoni Moda's `wght` axis range.
  static let weightRange: ClosedRange<Int> = 400...900

  private static let weightTag = 0x7767_6874  // 'wght'
  private static let opticalSizeTag = 0x6F70_737A  // 'opsz'

  /// The PostScript name every resolved font of this face must report.
  var expectedPostScriptName: String {
    switch self {
    case .inter(let weight): weight.postScriptName
    case .bodoni(let italic, _): italic ? "BodoniModa-Italic" : "BodoniModa-Regular"
    }
  }

  /// True when `font` is this face and not a CoreText fallback to a system font.
  public func matches(_ font: CTFont) -> Bool {
    // A variable font with axes applied reports its instance name, e.g. "BodoniModa-Regular_Medium".
    let name = CTFontCopyPostScriptName(font) as String
    return name == expectedPostScriptName || name.hasPrefix(expectedPostScriptName + "_")
  }

  private static let reportedFaces = Mutex(Set<String>())

  public func ctFont(size: CGFloat) -> CTFont { ctFont(size: size, opticalSize: nil) }

  /// `opticalSize` pins Bodoni's `opsz` axis instead of following `size` (Inter ignores it). The CTC wordmark
  /// uses 11, the instance v1's static web font was cut from, so the lockup matches v1 at any size.
  public func ctFont(size: CGFloat, opticalSize: CGFloat?) -> CTFont {
    let font = makeCTFont(size: size, opticalSize: opticalSize)
    if !matches(font) {
      let name = expectedPostScriptName
      let first = Self.reportedFaces.withLock { $0.insert(name).inserted }
      if first {
        let got = CTFontCopyPostScriptName(font) as String
        fontLog.error("font \(name, privacy: .public) did not resolve (got \(got, privacy: .public)); a system font would show")
        assertionFailure("bundled font \(name) is not registered")
      }
    }
    return font
  }

  private func makeCTFont(size: CGFloat, opticalSize: CGFloat?) -> CTFont {
    switch self {
    case .inter(let weight):
      return CTFontCreateWithName(weight.postScriptName as CFString, size, nil)
    case .bodoni(_, let weight):
      let wght = min(max(weight, Self.weightRange.lowerBound), Self.weightRange.upperBound)
      let opsz = min(max(opticalSize ?? size, Self.opticalSizeRange.lowerBound), Self.opticalSizeRange.upperBound)
      let attributes: [CFString: Any] = [
        kCTFontNameAttribute: expectedPostScriptName,
        kCTFontVariationAttribute: [
          NSNumber(value: Self.weightTag): NSNumber(value: wght),
          NSNumber(value: Self.opticalSizeTag): NSNumber(value: Double(opsz)),
        ],
      ]
      return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    }
  }
}

public extension Font {
  static func tl(_ face: TLFont, _ size: CGFloat, opticalSize: CGFloat? = nil) -> Font {
    Font(face.ctFont(size: size, opticalSize: opticalSize))
  }
}

/// One font file (or path) that could not be registered.
public struct FontRegistrationFailure: Equatable, Sendable {
  public let path: String
  public let reason: String
}

/// Process-scope registration for tests and `ImageRenderer`. The app itself relies on `ATSApplicationFontsPath = Fonts`.
public enum FontRegistry {
  /// Registers one font file, or every `.ttf` directly inside a directory. Already-registered fonts are fine.
  /// Every other failure is logged and returned; an empty result means all fonts are registered.
  @discardableResult
  public static func registerBundled(from url: URL) -> [FontRegistrationFailure] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return [fail(url.path, "path does not exist")]
    }
    let files: [URL]
    if isDirectory.boolValue {
      do {
        files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension.lowercased() == "ttf" }
      } catch {
        return [fail(url.path, "cannot list directory: \(error.localizedDescription)")]
      }
      if files.isEmpty { return [fail(url.path, "directory has no .ttf files")] }
    } else {
      files = [url]
    }
    var failures: [FontRegistrationFailure] = []
    for file in files {
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
        let cfError = error?.takeRetainedValue()
        let code = cfError.map { CFErrorGetCode($0) } ?? 0
        if code == CFIndex(CTFontManagerError.alreadyRegistered.rawValue) { continue }
        let reason = cfError.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
        failures.append(fail(file.path, reason))
      }
    }
    return failures
  }

  private static func fail(_ path: String, _ reason: String) -> FontRegistrationFailure {
    fontLog.error("font registration failed for \(path, privacy: .public): \(reason, privacy: .public)")
    return FontRegistrationFailure(path: path, reason: reason)
  }
}
