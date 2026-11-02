import CoreGraphics
import CoreImage
import Foundation
import TrimlabModel

/// §5.2 per-layer pipeline: orient → frame → effects. Builds a Core Image graph; nothing renders.
/// Colour-neutral: `src` carries its own colour space (`ReelCompositor.sourceImage`), and the conversion to the
/// output's happens when the compositor renders into its tagged destination.
public enum LayerRenderer {
  /// Fit's background blur, ≈ v1's `boxblur=40:2`.
  static let fitBlurRadius = 30.0
  static let fitBrightness = -0.12

  /// `src` is the stored (un-rotated) source frame; `transform` its track's `preferredTransform`. Returns an
  /// image covering exactly `(0, 0, size)`.
  public static func render(_ src: CIImage, transform: CGAffineTransform, framing: Framing, effects: [LayerEffect],
                            into size: CGSize) -> CIImage {
    let upright = src.transformed(by: orientation(transform, sourceExtent: src.extent))
    let bounds = CGRect(origin: .zero, size: size)
    let shown = upright.extent.size

    var image: CIImage
    switch framing {
    case .fill:
      image = upright.transformed(by: place(shown, in: size, cover: true)).cropped(to: bounds)
    case .fit:
      let background = upright.transformed(by: place(shown, in: size, cover: true))
        .clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: fitBlurRadius])
        .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: fitBrightness])
        .cropped(to: bounds)
      image = upright.transformed(by: place(shown, in: size, cover: false)).composited(over: background)
        .cropped(to: bounds)
    }

    for effect in effects { switch effect {} }
    return image
  }

  /// Maps the stored frame (Core Image's bottom-left origin, extent `sourceExtent`) to the upright frame with its
  /// origin at (0, 0). `preferredTransform` works in a top-left-origin space, so flip into it and back out.
  static func orientation(_ t: CGAffineTransform, sourceExtent e: CGRect) -> CGAffineTransform {
    let toTopLeft = CGAffineTransform(translationX: -e.minX, y: -e.minY)
      .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: e.height))
    let shown = CGRect(origin: .zero, size: e.size).applying(t)
    let fromTopLeft = CGAffineTransform(translationX: -shown.minX, y: -shown.minY)
      .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: shown.height))
    return toTopLeft.concatenating(t).concatenating(fromTopLeft)
  }

  /// Scales `shown` to cover (or fit inside) `size` and centres it.
  static func place(_ shown: CGSize, in size: CGSize, cover: Bool) -> CGAffineTransform {
    guard shown.width > 0, shown.height > 0 else { return .identity }
    let sx = size.width / shown.width, sy = size.height / shown.height
    let s = cover ? max(sx, sy) : min(sx, sy)
    return CGAffineTransform(scaleX: s, y: s)
      .concatenating(CGAffineTransform(translationX: (size.width - shown.width * s) / 2,
                                       y: (size.height - shown.height * s) / 2))
  }
}
