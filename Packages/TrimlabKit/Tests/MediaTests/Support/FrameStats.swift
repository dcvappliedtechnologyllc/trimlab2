import CoreGraphics
import CoreVideo
import Foundation

/// Limited-range luma of an in-memory frame: Y' = 0.2126 R + 0.7152 G + 0.0722 B on 0...255
/// values (BT.709 weights), mapped to 16 + 219 * Y' / 255, averaged over all pixels.
/// Comparable with ffprobe's signalstats YAVG on 8-bit code values.
enum FrameStats {
  /// `buffer` must be `kCVPixelFormatType_32BGRA`.
  static func limitedLuma(_ buffer: CVPixelBuffer) -> Double? {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    return meanLuma(
      base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
  }

  /// Limited-range luma mean and standard deviation over `rows` × `cols` (top-left origin) of a BGRA buffer,
  /// sampling every `step`-th pixel in both directions.
  static func lumaStats(_ buffer: CVPixelBuffer, rows: Range<Int>, cols: Range<Int>, step: Int = 1)
    -> (mean: Double, stddev: Double)?
  {
    var sum = 0.0, sumSq = 0.0, n = 0
    let ok = forEachPixel(buffer, rows: rows, cols: cols, step: step) { r, g, b in
      let y = 16 + 219 * (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
      sum += y; sumSq += y * y; n += 1
    }
    guard ok, n > 0 else { return nil }
    let mean = sum / Double(n)
    return (mean, max(0, sumSq / Double(n) - mean * mean).squareRoot())
  }

  /// Detail measure: the largest limited-range luma step between horizontally adjacent pixels over `rows` ×
  /// `cols` of a BGRA buffer, every `step`-th row. A sharp edge gives a large step; a blurred one a small step.
  static func maxLumaStep(_ buffer: CVPixelBuffer, rows: Range<Int>, cols: Range<Int>, step: Int = 1) -> Double? {
    var best = 0.0
    var previous: Double?
    var column = 0
    let ok = forEachPixel(buffer, rows: rows, cols: cols, step: 1, rowStep: step) { r, g, b in
      let y = 16 + 219 * (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
      if column > 0, let p = previous { best = max(best, abs(y - p)) }
      previous = y
      column = (column + 1) % cols.count
    }
    return ok ? best : nil
  }

  /// Mean R, G, B (0...255) over `rows` × `cols` (top-left origin) of a BGRA buffer.
  static func meanRGB(_ buffer: CVPixelBuffer, rows: Range<Int>, cols: Range<Int>)
    -> (r: Double, g: Double, b: Double)?
  {
    var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
    let ok = forEachPixel(buffer, rows: rows, cols: cols, step: 1) { r, g, b in
      sr += r; sg += g; sb += b; n += 1
    }
    guard ok, n > 0 else { return nil }
    return (sr / n, sg / n, sb / n)
  }

  private static func forEachPixel(_ buffer: CVPixelBuffer, rows: Range<Int>, cols: Range<Int>, step: Int,
                                   rowStep: Int? = nil, _ body: (Double, Double, Double) -> Void) -> Bool {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return false }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer), rows.lowerBound >= 0, rows.upperBound <= h,
      cols.lowerBound >= 0, cols.upperBound <= w
    else { return false }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in stride(from: rows.lowerBound, to: rows.upperBound, by: rowStep ?? step) {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for x in stride(from: cols.lowerBound, to: cols.upperBound, by: step) {
        body(Double(row[x * 4 + 2]), Double(row[x * 4 + 1]), Double(row[x * 4]))
      }
    }
    return true
  }

  static func limitedLuma(_ image: CGImage) -> Double? {
    let w = image.width, h = image.height
    guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: space, bitmapInfo: info)
      else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    return pixels.withUnsafeBytes {
      meanLuma(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4)
    }
  }

  private static func meanLuma(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> Double {
    var sum = 0.0
    for y in 0..<height {
      let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for x in 0..<width {
        let b = Double(row[x * 4]), g = Double(row[x * 4 + 1]), r = Double(row[x * 4 + 2])
        sum += 16 + 219 * (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
      }
    }
    return sum / Double(width * height)
  }
}
