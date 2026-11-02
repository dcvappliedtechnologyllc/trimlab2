import AVFoundation
import CoreImage
import Foundation
import Synchronization
import Testing
@testable import TrimlabMedia
import TrimlabModel

/// §5.2 de-risk gate and the compositor's framing, rotation and crossfade behaviour. Serialized so the
/// throughput gate isn't timed against this suite's other reads; `.exclusiveMedia` keeps exports out of it too.
@Suite(.serialized, .exclusiveMedia) struct CompositorGateTests {
  // MARK: gate

  @Test("gate (a)") func hlgLumaWithin3PercentOfV1() async throws {
    let (plan, built) = try await Self.build([("hlg.mov", 0, 3, .cut, .fill)])
    #expect(!plan.hdrOut)
    let frame = try #require(try await Self.frame(built, at: 1.3))
    let luma = try #require(FrameStats.limitedLuma(frame))
    print("gate (a): hlg.mov luma at 1.3 s = \(String(format: "%.2f", luma)) (v1 126.6)")
    #expect(abs(luma - 126.6) / 126.6 <= 0.03, "luma \(luma)")
  }

  @Test("gate (b)") func compositedThroughput() async throws {
    let (reel, assets) = try await FixtureReel.eighteen()
    let plan = Planner.plan(reel)
    let built = try await CompositionBuilder.build(plan, assets: assets)
    let t0 = ContinuousClock.now
    var count = 0
    var sizesOK = true
    try await Self.read(built) { _, buffer in
      count += 1
      if CVPixelBufferGetWidth(buffer) != 1080 || CVPixelBufferGetHeight(buffer) != 1920 { sizesOK = false }
    }
    let wall = (ContinuousClock.now - t0) / .seconds(1)
    let fps = Double(count) / wall
    print("gate (b): \(count) composited 1080×1920 frames in \(String(format: "%.3f", wall)) s = "
      + "\(String(format: "%.1f", fps)) fps")
    #expect(sizesOK)
    let expected = Int((plan.total.seconds / plan.frameDuration.seconds).rounded(.up))
    #expect(count == expected, "read \(count) frames, expected \(expected)")
    // One wall-clock read, so it is gated like a single-sample max (see `Timing`); acceptance runs
    // `TRIMLAB_TIMING=1 swift test --no-parallel --filter 'PreviewEngineTests|CompositorGateTests|StripLayoutTests'`.
    if Timing.strict { #expect(fps >= 120) }
  }

  @Test("gate (c)") func gaplessFrameDeltas() async throws {
    let (reel, assets) = try await FixtureReel.eighteen()
    let plan = Planner.plan(reel)
    let built = try await CompositionBuilder.build(plan, assets: assets)
    var pts: [Double] = []
    try await Self.read(built) { t, _ in pts.append(t.seconds) }
    let fd = plan.frameDuration.seconds
    // vfr.mp4 runs at 10 fps from source 2.0 s on: that stretch of each vfr placement may show 100 ms deltas.
    let tails: [ClosedRange<Double>] = FixtureReel.vfrIndices.map { i in
      let p = plan.placements[i]
      return (p.reelSpan.start.seconds + 2.0 - p.sourceIn.seconds)...p.reelSpan.end.seconds
    }
    #expect(pts.first == 0)
    // 0.01 ms: a third of the 0.033 ms per-frame gap between 1/30 and 1001/30000, so a wrong grid can't pass.
    var maxDelta = 0.0
    var offGrid: [String] = []
    for (a, b) in zip(pts, pts.dropFirst()) {
      let d = b - a
      if abs(d - fd) < 0.00001 { maxDelta = max(maxDelta, abs(d - fd)); continue }
      let inTail = tails.contains { $0.lowerBound - 1e-6 <= a && b <= $0.upperBound + 1e-6 }
      if !inTail { offGrid.append(String(format: "%.2f ms at %.4f s", d * 1000, a)) }
    }
    #expect(offGrid.isEmpty, "off-grid deltas outside vfr.mp4's tail: \(offGrid)")
    print("gate (c): \(pts.count) frames, max on-grid delta error \(String(format: "%.5f", maxDelta * 1000)) ms, "
      + "\(offGrid.count) off-grid outside the vfr tail")
    for (k, p) in plan.placements.enumerated() {
      let s = p.reelSpan.start.seconds
      #expect(pts.contains { $0 >= s - 1e-6 && $0 - s < fd }, "no frame within one frame of placement \(k) at \(s)")
    }
    #expect(abs((pts.last ?? 0) + fd - plan.total.seconds) <= fd + 1e-6)
  }

  // MARK: framing, rotation, crossfade

  @Test func fillCoversAndCrops() async throws {
    let (_, built) = try await Self.build([("landscape.mp4", 0, 3, .cut, .fill)])
    let out = try #require(try await Self.frame(built, at: 1.0))
    let src = try #require(try await Self.sourceFrame("landscape.mp4", at: 1.0))
    let corner = try #require(FrameStats.lumaStats(out, rows: 0..<8, cols: 0..<8))
    #expect(corner.mean > 40, "corner is black")
    // Fill scales 3840×2160 by 1920/2160 and keeps the centre: output x ↦ source 1920 + (x − 540) × 2160/1920.
    // Patches either side of centre land in the yellow and blue bars.
    let s = 2160.0 / 1920.0
    for x in [440, 640] {
      let sx = Int(1920 + Double(x - 540) * s)
      let o = try #require(FrameStats.meanRGB(out, rows: 950..<970, cols: x - 8..<x + 8))
      let r = try #require(FrameStats.meanRGB(src, rows: 1070..<1090, cols: sx - 9..<sx + 9))
      for (a, b) in [(o.r, r.r), (o.g, r.g), (o.b, r.b)] { #expect(abs(a - b) < 12, "x \(x): \(o) vs \(r)") }
    }
  }

  @Test func fitHasBlurredBackground() async throws {
    let (_, built) = try await Self.build([("landscape.mp4", 0, 3, .cut, .fit)])
    let out = try #require(try await Self.frame(built, at: 1.0))
    let src = try #require(try await Self.sourceFrame("landscape.mp4", at: 1.0))
    let band = try #require(FrameStats.lumaStats(out, rows: 0..<200, cols: 0..<1080))
    #expect(band.mean > 16, "top band is black (\(band.mean))")
    // Low detail: testsrc2's flat bars dominate a whole-frame stddev, so detail is the sharpest neighbour step.
    // The source's bar edges step by well over 100; blurred at radius 30 they spread to a few code values.
    let bandStep = try #require(FrameStats.maxLumaStep(out, rows: 0..<200, cols: 0..<1080, step: 8))
    let sourceStep = try #require(FrameStats.maxLumaStep(src, rows: 0..<2160, cols: 0..<3840, step: 16))
    #expect(sourceStep > 100)
    #expect(bandStep < sourceStep / 3, "band step \(bandStep) vs source \(sourceStep)")
    // The sharp, scaled-to-fit frame sits in the middle (rows 656–1263) and keeps the source's edges.
    let middleStep = try #require(FrameStats.maxLumaStep(out, rows: 700..<1200, cols: 0..<1080, step: 8))
    #expect(middleStep > sourceStep / 2, "middle step \(middleStep)")
    print("fit: band YAVG \(band.mean), band step \(bandStep), middle step \(middleStep), source step \(sourceStep)")
  }

  @Test func rotationApplied() async throws {
    let (_, built) = try await Self.build([("rotated.mov", 0, 3, .cut, .fill)])
    let out = try #require(try await Self.frame(built, at: 1.0))
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try await Fixtures.url("rotated.mov")))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let expected = try await generator.image(at: CMTime(value: 1, timescale: 1)).image
    #expect(expected.width == 1080 && expected.height == 1920)
    let rendered = try #require(Self.cgImage(out))
    let a = try #require(Self.thumbnail(rendered))
    let b = try #require(Self.thumbnail(expected))
    let upright = Self.correlation(a, b)
    let flipped = Self.correlation(a, b.reversed())  // reversing the row-major pixels = a 180° turn
    // Rotated testsrc2 is mostly horizontal bars, which a left–right mirror keeps (plain correlation 0.99). Take
    // each row's mean out first so only the left–right structure (diagonal, checker box, dots) is compared.
    let aRows = Self.rowDetrended(a, width: 54), bRows = Self.rowDetrended(b, width: 54)
    let uprightDetail = Self.correlation(aRows, bRows)
    let mirrored = Self.correlation(aRows, Self.mirrored(bRows, width: 54))
    print("rotationApplied: correlation upright \(String(format: "%.3f", upright)), "
      + "180° \(String(format: "%.3f", flipped)); row-detrended upright \(String(format: "%.3f", uprightDetail)), "
      + "mirrored \(String(format: "%.3f", mirrored))")
    #expect(upright > 0.9)
    #expect(flipped < upright - 0.5)
    #expect(uprightDetail > 0.9)
    #expect(mirrored < uprightDetail - 0.5)
  }

  @Test func crossfadeMidFrameBlends() async throws {
    let (plan, built) = try await Self.build([
      ("dark.mp4", 0, 3, .cut, .fill), ("bright.mp4", 0, 3, .crossfade(Limits.longFade), .fill),
    ])
    let start = plan.placements[1].reelSpan.start.seconds
    let fade = plan.placements[1].fadeIn.seconds
    #expect(fade == 1)
    func luma(_ t: Double) async throws -> Double {
      let frame = try #require(try await Self.frame(built, at: t))
      return try #require(FrameStats.limitedLuma(frame))
    }
    let dark = try await luma(1.0), bright = try await luma(start + fade + 0.5)
    let mid = try await luma(start + fade / 2), quarter = try await luma(start + fade / 4)
    print("crossfade: dark \(dark) quarter \(quarter) mid \(mid) bright \(bright)")
    #expect(bright - dark > 80)
    #expect(dark < mid && mid < bright)
    // 25 % into the fade the outgoing (dark) clip still dominates; an inverted ramp would favour bright.
    #expect(abs(quarter - dark) < abs(quarter - bright))
    #expect(dark < quarter && quarter < mid)
  }

  @Test func hdrOutSelectsTenBitCompositor() async throws {
    var (reel, assets) = try await FixtureReel.make([("hlg.mov", 0, 3, .cut, .fill)])
    reel.export.convertHDR = false
    let plan = Planner.plan(reel)
    #expect(plan.hdrOut)
    let built = try await CompositionBuilder.build(plan, assets: assets)
    #expect(built.videoComposition.customVideoCompositorClass == ReelCompositorHDR.self)
    #expect(built.videoComposition.colorTransferFunction == AVVideoTransferFunction_ITU_R_2100_HLG)
    let frame = try #require(try await Self.frame(built, at: 1.3, pixelFormat: nil))
    #expect(CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

    let (sdrReel, sdrAssets) = try await FixtureReel.make([("noaudio.mp4", 0, 3, .cut, .fill)])
    let sdr = try await CompositionBuilder.build(Planner.plan(sdrReel), assets: sdrAssets)
    #expect(sdr.videoComposition.customVideoCompositorClass == ReelCompositorSDR.self)
    #expect(sdr.videoComposition.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
  }

  /// Every source reaches the compositor in its own colour, whatever the Reel's output: AVFoundation doesn't
  /// convert it (`canConformColorOfSourceFrames`), so Core Image converts every frame, the first included.
  @Test func sourceFramesArriveInTheirOwnColour() async throws {
    let seen = Mutex<[ReelCompositor.SourceTags]>([])
    ReelCompositor.sourceFrameObserver.withLock { $0 = { tags in seen.withLock { $0.append(tags) } } }
    defer { ReelCompositor.sourceFrameObserver.withLock { $0 = nil } }

    let (sdrPlan, sdr) = try await Self.build([("noaudio.mp4", 0, 1, .cut, .fill), ("hlg.mov", 0, 1, .cut, .fill)])
    #expect(!sdrPlan.hdrOut)
    try await Self.read(sdr) { _, _ in }
    let sdrTags = seen.withLock { tags in defer { tags = [] }; return tags }
    let bt709 = ReelCompositor.SourceTags(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2")
    let hlg = ReelCompositor.SourceTags(primaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", matrix: "ITU_R_2020")
    // One second of each clip at 30 fps.
    #expect(sdrTags.count { $0 == bt709 } >= 25, "\(sdrTags.count { $0 == bt709 }) BT.709 frames")
    #expect(sdrTags.count { $0 == hlg } >= 25, "\(sdrTags.count { $0 == hlg }) HLG frames")
    #expect(sdrTags.allSatisfy { $0 == bt709 || $0 == hlg }, "\(Set(sdrTags.map { "\($0)" }))")

    var (reel, assets) = try await FixtureReel.make([("hlg.mov", 0, 1, .cut, .fill), ("bright.mp4", 0, 1, .cut, .fill)])
    reel.export.convertHDR = false
    let hdrPlan = Planner.plan(reel)
    #expect(hdrPlan.hdrOut)
    let hdr = try await CompositionBuilder.build(hdrPlan, assets: assets)
    try await Self.read(hdr, pixelFormat: nil) { _, _ in }
    let hdrTags = seen.withLock { $0 }
    #expect(hdrTags.count { $0 == hlg } >= 25, "\(hdrTags.count { $0 == hlg }) HLG frames")
    #expect(hdrTags.count { $0 == bt709 } >= 25, "\(hdrTags.count { $0 == bt709 }) BT.709 frames")
    #expect(hdrTags.allSatisfy { $0 == bt709 || $0 == hlg }, "\(Set(hdrTags.map { "\($0)" }))")
  }

  @Test func buildEighteenUnder10ms() async throws {
    let (reel, assets) = try await FixtureReel.eighteen()
    _ = try await CompositionBuilder.build(Planner.plan(reel), assets: assets)  // warm the asset loads
    var times: [Double] = []
    for _ in 0..<10 {
      let t0 = ContinuousClock.now
      _ = try await CompositionBuilder.build(Planner.plan(reel), assets: assets)
      times.append((ContinuousClock.now - t0) / .milliseconds(1))
    }
    let median = times.sorted()[times.count / 2]
    print("plan + build, 18 clips: median \(String(format: "%.2f", median)) ms")
    // §10's 10 ms, asserted under TRIMLAB_TIMING=1 only (see `Timing`): in a parallel run this async build waits
    // on a saturated cooperative pool and its median has been seen anywhere from 1 to 165 ms.
    if Timing.strict { #expect(median < 10, "median \(median) ms") }
  }

  // MARK: helpers

  private static func build(_ specs: [FixtureReel.Spec]) async throws -> (CompositionPlan, BuiltComposition) {
    let (reel, assets) = try await FixtureReel.make(specs)
    let plan = Planner.plan(reel)
    return (plan, try await CompositionBuilder.build(plan, assets: assets))
  }

  /// Reads composited frames from `start` on until `body` returns false or the composition ends.
  @discardableResult
  private static func read(_ built: BuiltComposition, from start: Double? = nil,
                           pixelFormat: OSType? = kCVPixelFormatType_32BGRA,
                           _ body: (CMTime, CVPixelBuffer) throws -> Bool) async throws -> AVAssetReader.Status {
    let reader = try AVAssetReader(asset: built.composition)
    let settings = pixelFormat.map { [kCVPixelBufferPixelFormatTypeKey as String: $0] }
    let output = AVAssetReaderVideoCompositionOutput(
      videoTracks: built.composition.tracks.filter { $0.mediaType == .video }, videoSettings: settings)
    output.videoComposition = built.videoComposition
    output.alwaysCopiesSampleData = false
    reader.add(output)
    if let start {
      reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                     duration: .positiveInfinity)
    }
    #expect(reader.startReading(), "reader: \(String(describing: reader.error))")
    while let sample = await OffPool.nextSample(output) {
      guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
      if try !body(CMSampleBufferGetPresentationTimeStamp(sample), buffer) {
        reader.cancelReading()
        return reader.status
      }
    }
    #expect(reader.status == .completed, "reader: \(String(describing: reader.error))")
    return reader.status
  }

  private static func read(_ built: BuiltComposition, pixelFormat: OSType? = kCVPixelFormatType_32BGRA,
                           _ body: (CMTime, CVPixelBuffer) throws -> Void) async throws {
    try await read(built, from: nil, pixelFormat: pixelFormat) { t, b in try body(t, b); return true }
  }

  private static func frame(_ built: BuiltComposition, at t: Double,
                            pixelFormat: OSType? = kCVPixelFormatType_32BGRA) async throws -> CVPixelBuffer? {
    var found: CVPixelBuffer?
    try await read(built, from: t, pixelFormat: pixelFormat) { _, buffer in
      found = buffer
      return false
    }
    return found
  }

  /// The source's own decoded frame at `t` (BGRA, stored orientation).
  private static func sourceFrame(_ name: String, at t: Double) async throws -> CVPixelBuffer? {
    let asset = AVURLAsset(url: try await Fixtures.url(name))
    let reader = try AVAssetReader(asset: asset)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: .positiveInfinity)
    reader.startReading()
    defer { reader.cancelReading() }
    return await OffPool.nextSample(output).flatMap(CMSampleBufferGetImageBuffer)
  }

  private static func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
    let image = CIImage(cvPixelBuffer: buffer)
    return CIContext().createCGImage(image, from: image.extent)
  }

  /// 54×96 grey thumbnail, row-major from the top.
  private static func thumbnail(_ image: CGImage) -> [Double]? {
    let w = 54, h = 96
    var pixels = [UInt8](repeating: 0, count: w * h)
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return ok ? pixels.map(Double.init) : nil
  }

  /// Left–right mirror of a row-major `width`-wide image.
  private static func mirrored(_ pixels: [Double], width: Int) -> [Double] {
    stride(from: 0, to: pixels.count, by: width).flatMap { pixels[$0..<$0 + width].reversed() }
  }

  /// Each row of a row-major `width`-wide image minus that row's mean.
  private static func rowDetrended(_ pixels: [Double], width: Int) -> [Double] {
    stride(from: 0, to: pixels.count, by: width).flatMap { start -> [Double] in
      let row = pixels[start..<start + width]
      let mean = row.reduce(0, +) / Double(width)
      return row.map { $0 - mean }
    }
  }

  /// Pearson correlation of two equal-length samples.
  private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
    let n = Double(a.count)
    let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    var sab = 0.0, saa = 0.0, sbb = 0.0
    for (x, y) in zip(a, b) {
      sab += (x - ma) * (y - mb)
      saa += (x - ma) * (x - ma)
      sbb += (y - mb) * (y - mb)
    }
    return sab / (saa * sbb).squareRoot()
  }
}
