import CoreGraphics
import Foundation
import OSLog

private let logoLog = Logger(subsystem: "com.dcv.trimlab2", category: "logo")

/// The DCV logo as a vector PDF rasterised at the backing scale (SPEC §6.0 "vector PDF logo").
/// CoreGraphics only, so the package stays free of AppKit; the app passes its bundle URL, tests pass the repo's.
public enum Logo {
  /// Renders page 1 of `pdf` at `height` points tall (width follows the page's aspect) and `scale` pixels per point.
  /// Returns nil, and logs, when the file is missing or isn't a PDF.
  public static func render(pdf url: URL, height: CGFloat, scale: CGFloat) -> CGImage? {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
      logoLog.error("logo PDF did not load: \(url.path, privacy: .public)")
      return nil
    }
    let box = page.getBoxRect(.cropBox)
    guard box.width > 0, box.height > 0, height > 0, scale > 0 else { return nil }
    let ratio = height * scale / box.height
    let pixelWidth = Int((box.width * ratio).rounded()), pixelHeight = Int((box.height * ratio).rounded())
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: ratio, y: ratio)
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(page)
    return context.makeImage()
  }
}
