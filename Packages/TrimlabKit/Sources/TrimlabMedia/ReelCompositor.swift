import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import Synchronization
import TrimlabModel

/// §5.2 custom compositor. AVFoundation instantiates the class named by `customVideoCompositorClass`, so the
/// output format is chosen by subclass (F18): `ReelCompositorSDR` renders BGRA BT.709, `ReelCompositorHDR`
/// renders 10-bit 4:2:0 BT.2100 HLG. All state is touched only on `queue`.
///
/// The compositor owns the SDR/HDR conversion: `canConformColorOfSourceFrames` tells AVFoundation to hand over
/// each source in its own colour, and the compositor converts it into the output space from the buffer's real tags
/// (an HLG clip in an SDR Reel is tone-mapped to BT.709 with v1's look, `HDRToSDR`; an SDR clip in an HDR-kept
/// Reel is mapped into HLG by Core Image).
/// AVFoundation's own conversion left the first frame of every converted clip unconverted (a one-frame flash).
public class ReelCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
  /// Overridden by `ReelCompositorHDR`.
  class var rendersHDR: Bool { false }

  /// One Metal context for every compositor instance (preview rebuilds create a new one per edit).
  static let context: CIContext = {
    let options: [CIContextOption: Any] = [
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      .workingFormat: CIFormat.RGBAh,
      .cacheIntermediates: false,
      .name: "com.dcv.trimlab2.compositor",
    ]
    if let device = HDRToSDR.device { return CIContext(mtlDevice: device, options: options) }
    MediaLog.note("compositor: no Metal device; Core Image falls back to its default renderer")
    return CIContext(options: options)
  }()

  /// Output tags, and the colour spaces CoreVideo derives from them. CoreVideo's BT.709 space is the one it
  /// attaches to decoded BT.709 sources, so an SDR source round-trips unchanged; `CGColorSpace.itur_709` would
  /// not (it lifts 0x30 grey to 0x41).
  private static var sdrTags: [CFString: CFString] {
    tags(kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2,
         kCVImageBufferYCbCrMatrix_ITU_R_709_2)
  }
  private static var hdrTags: [CFString: CFString] {
    tags(kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
         kCVImageBufferYCbCrMatrix_ITU_R_2020)
  }
  static let sdrSpace = space(sdrTags, fallback: CGColorSpace.itur_709)
  private static let hdrSpace = space(hdrTags, fallback: CGColorSpace.itur_2100_HLG)

  private static func tags(_ primaries: CFString, _ transfer: CFString, _ matrix: CFString) -> [CFString: CFString] {
    [kCVImageBufferColorPrimariesKey: primaries, kCVImageBufferTransferFunctionKey: transfer,
     kCVImageBufferYCbCrMatrixKey: matrix]
  }

  private static func space(_ tags: [CFString: CFString], fallback: CFString) -> CGColorSpace {
    CVImageBufferCreateColorSpaceFromAttachments(tags as CFDictionary)?.takeRetainedValue()
      ?? CGColorSpace(name: fallback)!
  }

  private let queue = DispatchQueue(label: "com.dcv.trimlab2.compositor", qos: .userInitiated)
  private var cancelling = false
  /// Requests started plus requests finished (any outcome): the export watchdog counts a change as progress, so
  /// an export whose frames are slow to compose (a busy GPU) isn't taken for a stalled one.
  let activity = Atomic<Int>(0)
  /// v4 hook: drawn over the composited layers, in order. Empty in v2.
  let overlays: [@Sendable (CIImage, CMTime) -> CIImage]

  /// AVFoundation creates compositors with `init()`.
  public override convenience init() { self.init(overlays: []) }

  init(overlays: [@Sendable (CIImage, CMTime) -> CIImage]) {
    self.overlays = overlays
    super.init()
  }

  /// A source frame's colour tags, as attached by the decoder.
  struct SourceTags: Hashable, Sendable {
    var primaries, transfer, matrix: String?
  }

  /// Test hook: called with every source frame's tags before it is drawn. nil in the app.
  static let sourceFrameObserver = Mutex<(@Sendable (SourceTags) -> Void)?>(nil)

  private var hdr: Bool { Self.rendersHDR }

  public var sourcePixelBufferAttributes: [String: any Sendable]? {
    [
      kCVPixelBufferPixelFormatTypeKey as String: [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_32BGRA,
      ],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
  }

  public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
    [
      kCVPixelBufferPixelFormatTypeKey as String:
        hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
  }

  public var supportsHDRSourceFrames: Bool { true }
  public var supportsWideColorSourceFrames: Bool { true }
  /// Sources in a `sourcePixelBufferAttributes` format arrive in their own colour; `compose` converts them.
  public var canConformColorOfSourceFrames: Bool { true }

  public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

  public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    activity.add(1, ordering: .relaxed)
    queue.async { [self] in
      defer { activity.add(1, ordering: .relaxed) }
      if cancelling {
        request.finishCancelledRequest()
        return
      }
      autoreleasepool {
        do {
          request.finish(withComposedVideoFrame: try compose(request))
        } catch {
          MediaLog.note("compositor: frame at \(request.compositionTime.seconds) s failed: \(error)")
          request.finish(with: error)
        }
      }
    }
  }

  public func cancelAllPendingVideoCompositionRequests() {
    queue.sync { cancelling = true }
    queue.async { [self] in cancelling = false }
  }

  // MARK: rendering

  enum Failure: Error { case wrongInstruction, noBuffer }

  private func compose(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
    guard let instruction = request.videoCompositionInstruction as? ReelInstruction else {
      throw Failure.wrongInstruction
    }
    guard let destination = request.renderContext.newPixelBuffer() else { throw Failure.noBuffer }
    let time = request.compositionTime
    let size = request.renderContext.size
    let bounds = CGRect(origin: .zero, size: size)

    var image = CIImage(color: .black).cropped(to: bounds)
    for layer in instruction.layers.reversed() {
      guard let frame = request.sourceFrame(byTrackID: layer.trackID) else { continue }
      if let observe = Self.sourceFrameObserver.withLock({ $0 }) { observe(Self.tags(of: frame)) }
      var drawn = LayerRenderer.render(
        Self.sourceImage(frame, hdrOut: hdr), transform: layer.transform, framing: layer.spec.framing,
        effects: layer.spec.effects, into: size)
      let opacity = instruction.opacity(of: layer, at: time)
      if opacity < 1 {
        drawn = drawn.applyingFilter("CIColorMatrix", parameters: [
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(opacity, 0))),
        ])
      }
      image = drawn.composited(over: image)
    }
    for overlay in overlays { image = overlay(image, time) }

    tagColour(destination)
    let target = CIRenderDestination(pixelBuffer: destination)
    target.colorSpace = hdr ? Self.hdrSpace : Self.sdrSpace
    // Wait for the GPU: the buffer goes straight to the reader or the display once `finish` is called.
    try Self.context.startTask(toRender: image, from: bounds, to: target, at: .zero).waitUntilCompleted()
    return destination
  }

  /// The source as Core Image sees it, colour space from its own attachments. For the BT.709 destination an
  /// HLG or PQ source is converted to SDR as v1 converted it (`HDRToSDR`, gate (a)); any other HDR source falls
  /// back to Core Image's tone map. Rendered into the HLG destination an SDR source is mapped into HLG.
  static func sourceImage(_ frame: CVPixelBuffer, hdrOut: Bool) -> CIImage {
    if hdrOut { return CIImage(cvPixelBuffer: frame) }
    return HDRToSDR.image(frame, sdrSpace: sdrSpace)
      ?? CIImage(cvPixelBuffer: frame, options: [.toneMapHDRtoSDR: true])
  }

  private func tagColour(_ buffer: CVPixelBuffer) {
    for (key, value) in hdr ? Self.hdrTags : Self.sdrTags {
      CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
  }

  static func tags(of buffer: CVPixelBuffer) -> SourceTags {
    func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
    return SourceTags(primaries: tag(kCVImageBufferColorPrimariesKey),
                      transfer: tag(kCVImageBufferTransferFunctionKey), matrix: tag(kCVImageBufferYCbCrMatrixKey))
  }
}

/// SDR out: BGRA, BT.709.
public final class ReelCompositorSDR: ReelCompositor, @unchecked Sendable {}

/// HDR kept: 10-bit 4:2:0 video range, BT.2100 HLG.
public final class ReelCompositorHDR: ReelCompositor, @unchecked Sendable {
  override class var rendersHDR: Bool { true }
}
