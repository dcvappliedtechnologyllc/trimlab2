import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import TrimlabModel
import UniformTypeIdentifiers
@testable import TrimlabEditor

/// Task 27: the stage, transport and inspector (§4.2, §4.5, §6.4), rendered with `ImageRenderer` over stub media.
/// The stage's player is stood in for by the mockup's portrait still.
@MainActor @Suite struct StageViewTests {
  static let window = CGSize(width: 1240, height: 860)
  static let fps = RationalTime(1001, 30000)

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  // MARK: words

  @Test func metaLines() {
    var clip = Self.clip("IMG_4821.MOV", duration: RationalTime(236, 10), hdr: .hlg)
    #expect(InspectorView.meta(clip, state: .ready, missing: false)
      == ["1080×1920, HEVC, 29.97 fps", "23.6\u{00A0}s, HDR (HLG)"])
    clip.facts.videoCodec = "h264"
    clip.facts.frameDuration = RationalTime(1, 30)
    clip.facts.hdr = .sdr
    #expect(InspectorView.meta(clip, state: .ready, missing: false)
      == ["1080×1920, H.264, 30 fps", "23.6\u{00A0}s"])
    #expect(InspectorView.meta(clip, state: .probing, missing: false) == ["Loading…"])
    #expect(InspectorView.meta(clip, state: .ready, missing: true) == ["Missing"])
    #expect(InspectorView.clipName(clip) == "IMG_4821")
  }

  @Test func framesPerSecond() {
    #expect(Formatting.fps(RationalTime(1001, 30000)) == "29.97")
    #expect(Formatting.fps(RationalTime(1001, 24000)) == "23.98")
    #expect(Formatting.fps(RationalTime(1, 25)) == "25")
    #expect(Formatting.fps(RationalTime(1001, 60000)) == "59.94")
    #expect(Formatting.fps(RationalTime(1, 10)) == "10")
  }

  @Test func totalSplitsTheUnit() {
    #expect(InspectorView.totalParts(RationalTime(482, 10)) == ("48.2", "s"))
    #expect(InspectorView.totalParts(RationalTime(1924, 10)) == ("3:12.4", nil))
    #expect(Formatting.overLimitLine(RationalTime(124, 10))
      == "Instagram Reels can be up to 3 minutes. Trim 0:12.4 more.")
  }

  @Test func headerTitle() async throws {
    let one = try await Self.oneClip()
    #expect(RootView<Color>.title(one.model.reel) == "IMG_4821.MOV")
    let reel = try await Self.reel()
    #expect(RootView<Color>.title(reel.model.reel) == "Spa Tour")
    #expect(RootView<Color>.title(nil) == nil)
  }

  // MARK: screens

  /// The #reel layout at 1240 × 860: stage frame, inspector column, bottom block and the gold Export… button.
  @Test func reelScreenLayout() async throws {
    let h = try await Self.reel()
    let image = try Self.render(Self.root(h), scale: 1)
    let px = try Self.pixels(image)
    func at(_ x: Int, _ y: Int) -> [UInt8] { Self.rgb(px, image, x: x, y: y) }
    let bg0: [UInt8] = [0x0B, 0x0C, 0x0E], bg1: [UInt8] = [0x14, 0x16, 0x1A], line: [UInt8] = [0x2A, 0x2E, 0x36]
    #expect(at(100, 300) == bg0, "stage")
    #expect(at(1000, 470) == bg1, "inspector")
    #expect(at(940, 300) == line, "inspector hairline")
    #expect(at(600, 582) == line, "bottom hairline")
    #expect(at(600, 716) == bg1, "bottom block (the caption row; the strip fills 622–702)")
    #expect(at(1090, 538) == [0xC9, 0xA8, 0x6A], "Export… is gold")
    // The 9:16 Reel frame: 494 tall inside 16 px padding, so 277.9 wide, centred on the 940 px stage.
    #expect(at(470, 300) != bg0, "the still is on the stage")
    #expect(at(328, 300) == bg0 && at(612, 300) == bg0, "the frame is 9:16, centred")
    #expect(at(470, 69) == bg0 && at(470, 569) == bg0, "16 px top and bottom")
  }

  /// The over-3:00 total turns `--warn` and the line appears.
  @Test func overLimitWarns() async throws {
    let h = try await Self.reel(scale: 8)
    #expect(h.model.reel?.overLimit(missing: []) != nil)
    let image = try Self.render(Self.root(h), scale: 1)
    let px = try Self.pixels(image)
    var warn = 0
    for y in 260...400 { for x in 960...1220 where Self.rgb(px, image, x: x, y: y) == [0xF2, 0xC9, 0x4C] { warn += 1 } }
    #expect(warn > 200, "warn ink: \(warn)")
  }

  /// The 3:00 warning is a Reel-format rule (§4.3.6): an Original export over 3:00 shows no warn ink and no line.
  @Test func overLimitOnlyInReelFormat() async throws {
    let h = try await Self.reel(scale: 8)
    #expect(h.model.overLimit != nil)
    var spec = try #require(h.model.reel?.export)
    spec.format = .original
    #expect(h.model.perform(.setExport(spec), coalesce: nil, record: false))
    #expect(h.model.overLimit == nil)
    #expect(try Self.warnInk(h, rows: 200...560) == 0)
  }

  /// A one-clip Reel over 3:00 warns too, line included (ruling: no one-clip exception).
  @Test func oneClipOverLimitShowsLine() async throws {
    let h = Harness()
    h.media.script("long.MOV", .facts(Self.clip("long.MOV", duration: RationalTime(190, 1)).facts))
    await h.importAll(["long.MOV"], in: "/Spa Tour")
    #expect(h.model.overLimit != nil)
    #expect(try Self.warnInk(h, rows: 225...290) > 200, "the total is warn")
    #expect(try Self.warnInk(h, rows: 296...340) > 100, "the line under it is warn")
  }

  static func warnInk(_ h: Harness, rows: ClosedRange<Int>) throws -> Int {
    let image = try render(root(h), scale: 1)
    let px = try pixels(image)
    var warn = 0
    for y in rows { for x in 960...1220 where rgb(px, image, x: x, y: y) == [0xF2, 0xC9, 0x4C] { warn += 1 } }
    return warn
  }

  // MARK: states

  static func clip(_ name: String, duration: RationalTime, hdr: HDRKind = .sdr) -> ReelClip {
    let facts = ClipFacts(duration: duration, frameDuration: fps, displayWidth: 1080, displayHeight: 1920,
                          rotation: 0, videoCodec: "hevc", hasAudio: true, hdr: hdr, bitrate: 10_000_000,
                          captureDate: nil, needsRemux: false)
    return ReelClip.make(source: SourceRef(relativePath: nil, absolutePath: "/Spa Tour/\(name)", size: 1,
                                           modified: Date(timeIntervalSince1970: 0)),
                         facts: facts, framing: .fill)
  }

  /// The start of the frame that reads `m:ss.ff` at 29.97 (`s` whole seconds, then frame `f` of that second).
  static func tc(_ s: Int64, _ f: Int64) -> RationalTime {
    fps * (Int64((Double(s) * 30000 / 1001).rounded(.up)) + f)
  }

  /// The mockup's #one-clip: IMG_4821.MOV, 23.6 s HLG, In 0:01.21, Out 0:10.07, playhead 0:02.08.
  static func oneClip() async throws -> Harness {
    let h = Harness()
    h.media.script("IMG_4821.MOV", .facts(clip("IMG_4821.MOV", duration: RationalTime(236, 10), hdr: .hlg).facts))
    await h.importAll(["IMG_4821.MOV"], in: "/Spa Tour")
    let id = try #require(h.model.reel?.clips.first?.id)
    h.model.perform(.setIn(id, tc(1, 21)), coalesce: nil)
    h.model.perform(.setOut(id, tc(10, 7)), coalesce: nil)
    h.model.seek(reelTime: tc(2, 8))
    return h
  }

  /// The mockup's #reel: 18 clips of Spa Tour, clip 4 (IMG_4821) selected, Long into clip 8, Short into clip 13,
  /// 48.2 s. `scale` stretches every other clip (8 gives an over-3:00 Reel).
  static func reel(scale: Int64 = 1) async throws -> Harness {
    let lens: [Double] = [2.4, 3.1, 1.8, 0, 2.2, 3.4, 1.6, 2.9, 2.4, 0.6, 2.2, 1.9, 3.3, 1.5, 2.8, 2.1, 1.2, 2.6]
    let h = Harness()
    let names = (0..<18).map { "IMG_\(4818 + $0).MOV" }
    for (i, name) in names.enumerated() {
      let duration = i == 3 ? RationalTime(236, 10) : RationalTime(60 * scale, 1)
      h.media.script(name, .facts(clip(name, duration: duration, hdr: i == 3 ? .hlg : .sdr).facts))
      h.media.date(name, Date(timeIntervalSince1970: Double(1_000 + i)))
    }
    await h.importAll(names, in: "/Spa Tour")
    let ids = try #require(h.model.reel?.clips.map(\.id))
    for (i, id) in ids.enumerated() {
      if i == 3 {
        h.model.perform(.setIn(id, tc(1, 21)), coalesce: nil)
        h.model.perform(.setOut(id, tc(10, 7)), coalesce: nil)
      } else {
        h.model.perform(.setIn(id, RationalTime(1, 1)), coalesce: nil)
        let len = RationalTime(seconds: lens[i] * Double(i % 2 == 0 ? scale : 1), timescale: 30000)
        h.model.perform(.setOut(id, RationalTime(1, 1) + len), coalesce: nil)
      }
    }
    h.model.perform(.setJoin(ids[7], .crossfade(Limits.longFade)), coalesce: nil)
    h.model.perform(.setJoin(ids[12], .crossfade(Limits.shortFade)), coalesce: nil)
    h.model.select(ids[3], extend: false, toggle: false)
    await h.model.pendingPreview?.value
    let start = try #require(h.model.plan?.placements[3].reelSpan.start)
    h.model.seek(reelTime: start + tc(1, 0))
    return h
  }

  // MARK: rendering

  static var still: CGImage? {
    let url = SourceScan.repoRoot / "design/mockup-assets/still-portrait.jpg"
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  static func root(_ h: Harness, scale: CGFloat = 1) -> some View {
    let logo = Logo.render(pdf: ShellViewTests.logoPDF, height: 46, scale: scale)
    let still = Self.still
    return RootView(model: h.model, logo: logo) { _ in
      if let still {
        Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill)
      }
    }
  }

  static func render(_ view: some View, scale: CGFloat) throws -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: window.width, height: window.height))
    renderer.scale = scale
    return try #require(renderer.cgImage)
  }

  static func pixels(_ image: CGImage) throws -> [UInt8] {
    var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    _ = px.withUnsafeMutableBytes { buf in
      CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
        .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return px
  }

  static func rgb(_ px: [UInt8], _ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let i = (y * image.width + x) * 4
    return [px[i], px[i + 1], px[i + 2]]
  }
}
