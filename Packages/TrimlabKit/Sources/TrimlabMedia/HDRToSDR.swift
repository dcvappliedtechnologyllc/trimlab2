import CoreImage
import CoreVideo
import Foundation
import Metal

/// v1's HDR → SDR conversion (trimlab/core/filters.py `HDR_ZSCALE`: zscale to linear at 100 nits, BT.2020 →
/// BT.709, Hable with no desaturation, BT.709 transfer), which the owner approved. `scripts/make-hdr-lut.py` runs
/// that chain over a 65³ lattice of BT.2020 R'G'B' code values per transfer and stores the BT.709 R'G'B'
/// results in `Resources/*.lut`; this applies them with tetrahedral interpolation on the GPU. Tetrahedral, not
/// `CIColorCube`'s trilinear: Hable acts on max(R, G, B), whose crease runs along the grey axis, and trilinear
/// darkened neutral tones by up to 5 codes; tetrahedral uses only the grey-axis nodes for greys (0.06 codes).
/// Core Image's own tone map was far darker than v1 on neutral tones (HLG 0.5: 82 against 123).
enum HDRToSDR {
  enum Transfer: Int, Sendable { case hlg = 0, pq = 1 }

  /// The frame's HDR transfer, from its attachments; nil for anything else.
  static func transfer(of buffer: CVPixelBuffer) -> Transfer? {
    let tag = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
    if tag == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
    if tag == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
    return nil
  }

  /// An HLG or PQ frame converted to BT.709 R'G'B' as v1 converts it, as an image in `sdrSpace` (matched to
  /// the working space). nil when the frame is neither or there is no Metal device; the caller falls back.
  static func image(_ buffer: CVPixelBuffer, sdrSpace: CGColorSpace) -> CIImage? {
    guard let transfer = transfer(of: buffer), gpu != nil else { return nil }
    // No colour management on the way in: the kernel reads the HDR R'G'B' code values themselves.
    let encoded = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    guard
      let mapped = try? LUTKernel.apply(
        withExtent: encoded.extent, inputs: [encoded], arguments: [LUTKernel.transferKey: transfer.rawValue])
    else { return nil }
    return mapped.matchedToWorkingSpace(from: sdrSpace)
  }

  /// The one Metal device every Core Image context in this module renders on (`ReelCompositor.context`, the
  /// export thumbnail's context) and the LUT pipeline is built for, so the kernel's device check holds on a
  /// Mac with more than one GPU.
  static let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()

  /// The Metal pipeline and the LUT textures, built once. nil (logged) without a Metal device, or when the kernel
  /// or a LUT file fails to load. The resource bundle itself must exist: `Bundle.module` traps without it.
  static let gpu: GPU? = GPU()

  struct GPU: @unchecked Sendable {
    let device: any MTLDevice
    let pipeline: any MTLComputePipelineState
    let luts: [Transfer: any MTLTexture]

    init?() {
      guard let device = HDRToSDR.device else {
        MediaLog.note("HDR → SDR: no Metal device; Core Image's tone map is used")
        return nil
      }
      do {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "tetrahedral") else {
          MediaLog.note("HDR → SDR: no tetrahedral kernel in the compiled library; Core Image's tone map is used")
          return nil
        }
        pipeline = try device.makeComputePipelineState(function: function)
        var luts: [Transfer: any MTLTexture] = [:]
        for (transfer, name) in [(Transfer.hlg, "hlg_to_sdr_v1"), (.pq, "pq_to_sdr_v1")] {
          guard let texture = try Self.texture(name, device: device) else { return nil }
          luts[transfer] = texture
        }
        self.luts = luts
        self.device = device
      } catch {
        MediaLog.note("HDR → SDR: LUT setup failed (\(error)); Core Image's tone map is used")
        return nil
      }
    }

    struct BadLUT: Error { let name: String }

    /// `TLUT`, UInt32 size N, then N³ × (R, G, B) UInt16 unorm, red fastest. Loaded as an RGBA16Unorm 3D texture.
    private static func texture(_ name: String, device: any MTLDevice) throws -> (any MTLTexture)? {
      guard let url = Bundle.module.url(forResource: name, withExtension: "lut") else { throw BadLUT(name: name) }
      let data = try Data(contentsOf: url)
      guard data.count >= 8, data.prefix(4) == Data("TLUT".utf8) else { throw BadLUT(name: name) }
      let n = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
      guard n >= 2, data.count == 8 + n * n * n * 6 else { throw BadLUT(name: name) }
      var rgba = [UInt16](repeating: .max, count: n * n * n * 4)
      data.withUnsafeBytes { raw in
        for i in 0..<(n * n * n) {
          for k in 0..<3 {
            rgba[i * 4 + k] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 8 + (i * 3 + k) * 2, as: UInt16.self))
          }
        }
      }
      let descriptor = MTLTextureDescriptor()
      descriptor.textureType = .type3D
      descriptor.pixelFormat = .rgba16Unorm
      descriptor.width = n
      descriptor.height = n
      descriptor.depth = n
      descriptor.usage = .shaderRead
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        MediaLog.note("HDR → SDR: could not create the \(n)³ texture for \(name); Core Image's tone map is used")
        return nil
      }
      rgba.withUnsafeBytes {
        texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: n * 8, bytesPerImage: n * n * 8)
      }
      return texture
    }

    /// Tetrahedral interpolation of the lattice at each pixel's R'G'B' (clamped to 0...1); alpha is kept.
    static let source = """
      #include <metal_stdlib>
      using namespace metal;
      kernel void tetrahedral(texture2d<half, access::read> src [[texture(0)]],
                              texture2d<half, access::write> dst [[texture(1)]],
                              texture3d<float, access::read> lut [[texture(2)]],
                              constant int2 &offset [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int2 at = clamp(int2(gid) + offset, int2(0), int2(src.get_width() - 1, src.get_height() - 1));
        float4 s = float4(src.read(uint2(at)));
        float n = float(lut.get_width() - 1);
        float3 x = clamp(s.rgb, 0.0, 1.0) * n;
        float3 b = min(floor(x), float3(n - 1.0));
        float3 f = x - b;
        uint3 i = uint3(b);
        float3 c000 = lut.read(i).rgb;
        float3 c111 = lut.read(i + uint3(1, 1, 1)).rgb;
        float3 out;
        if (f.r >= f.g) {
          if (f.g >= f.b) {
            out = (1 - f.r) * c000 + (f.r - f.g) * lut.read(i + uint3(1, 0, 0)).rgb
                + (f.g - f.b) * lut.read(i + uint3(1, 1, 0)).rgb + f.b * c111;
          } else if (f.r >= f.b) {
            out = (1 - f.r) * c000 + (f.r - f.b) * lut.read(i + uint3(1, 0, 0)).rgb
                + (f.b - f.g) * lut.read(i + uint3(1, 0, 1)).rgb + f.g * c111;
          } else {
            out = (1 - f.b) * c000 + (f.b - f.r) * lut.read(i + uint3(0, 0, 1)).rgb
                + (f.r - f.g) * lut.read(i + uint3(1, 0, 1)).rgb + f.g * c111;
          }
        } else {
          if (f.b >= f.g) {
            out = (1 - f.b) * c000 + (f.b - f.g) * lut.read(i + uint3(0, 0, 1)).rgb
                + (f.g - f.r) * lut.read(i + uint3(0, 1, 1)).rgb + f.r * c111;
          } else if (f.b >= f.r) {
            out = (1 - f.g) * c000 + (f.g - f.b) * lut.read(i + uint3(0, 1, 0)).rgb
                + (f.b - f.r) * lut.read(i + uint3(0, 1, 1)).rgb + f.r * c111;
          } else {
            out = (1 - f.g) * c000 + (f.g - f.r) * lut.read(i + uint3(0, 1, 0)).rgb
                + (f.r - f.b) * lut.read(i + uint3(1, 1, 0)).rgb + f.b * c111;
          }
        }
        dst.write(half4(half3(out), half(s.a)), gid);
      }
      """
  }

  /// Runs `GPU.pipeline` inside a Core Image graph.
  final class LUTKernel: CIImageProcessorKernel {
    static let transferKey = "transfer"
    struct Unavailable: Error {}

    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class func process(with inputs: [any CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: any CIImageProcessorOutput) throws {
      guard let gpu, let input = inputs?.first, let source = input.metalTexture,
        let target = output.metalTexture, let commands = output.metalCommandBuffer,
        let transfer = (arguments?[transferKey] as? Int).flatMap(Transfer.init(rawValue:)),
        let lut = gpu.luts[transfer], let encoder = commands.makeComputeCommandEncoder()
      else { throw Unavailable() }
      // Only a context on another device lands here (every context this module makes is on `HDRToSDR.device`).
      // Its render fails; the caller then renders that image with Core Image's own tone map (`ExportJob.image`).
      guard commands.device === gpu.device else {
        MediaLog.note("HDR → SDR: render on \(commands.device.name), LUT on \(gpu.device.name); "
          + "falling back to Core Image's tone map for this image")
        throw Unavailable()
      }
      // Core Image regions are y-up; textures are y-down from each region's top edge.
      var offset = SIMD2<Int32>(Int32(output.region.minX - input.region.minX),
                                Int32(input.region.maxY - output.region.maxY))
      encoder.setComputePipelineState(gpu.pipeline)
      encoder.setTexture(source, index: 0)
      encoder.setTexture(target, index: 1)
      encoder.setTexture(lut, index: 2)
      encoder.setBytes(&offset, length: MemoryLayout<SIMD2<Int32>>.size, index: 0)
      let w = gpu.pipeline.threadExecutionWidth
      let h = max(1, gpu.pipeline.maxTotalThreadsPerThreadgroup / w)
      encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
      encoder.endEncoding()
    }
  }
}
