import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import TrimlabEditor

/// Task 38: every screen state (the 14 approved mockup states plus loading, exporting, error, the ffmpeg card, the
/// key map and the Reel name being renamed), rendered with `ImageRenderer` at 1240 × 860 (`narrow` 960 × 860), @1x and @2x, into
/// `docs/screens/app/` for the side-by-side check against `docs/screens/mockup/` (regenerate it with `scripts/mockup-shots.swift`; it is not tracked) (SPEC §6.5 step 4, §11.2).
@MainActor @Suite struct ScreensTests {
  static let outDir = SourceScan.repoRoot / "docs/screens/app"

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  /// Every mockup state has a native screen, plus the six states the mockup doesn't cover.
  @Test func coversEveryState() {
    let ids = ScreenStates.all.map(\.id)
    #expect(ids == Self.ids)
    #expect(Set(ids).count == ids.count)
  }

  /// Writes `<state>@1x.png` and `<state>@2x.png` at exact pixel sizes. No render may be blank: none is 95 % or more
  /// one colour, except `empty`, which is v1's near-black stage by design (98.5 % `--bg-0` in the mockup) and must
  /// instead carry the "Drop clips." ink.
  /// Off by default: it holds the main actor for 20–30 s and rewrites tracked PNGs.
  /// `TRIMLAB_SCREENS=1 swift test --filter ScreensTests`.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIMLAB_SCREENS"] == "1", "set TRIMLAB_SCREENS=1"))
  func renderAll() async throws {
    try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
    for state in ScreenStates.all {
      for scale in [1, 2] as [CGFloat] {
        let view = try await state.make(scale)
        let renderer = ImageRenderer(content: view.frame(width: state.size.width, height: state.size.height)
          .environment(\.tlStillRender, true))
        renderer.scale = scale
        let image = try #require(renderer.cgImage, "\(state.id) did not render")
        #expect(image.width == Int(state.size.width * scale) && image.height == Int(state.size.height * scale),
                "\(state.id)@\(Int(scale))x is \(image.width)×\(image.height)")
        let share = try Self.topColourShare(image)
        if state.id == "empty" {
          #expect(share < 0.995 && share > 0.9, "empty: top colour \(share)")
        } else {
          #expect(share < 0.95, "\(state.id)@\(Int(scale))x is \(Int(share * 100)) % one colour")
        }
        try StripLayoutTests.save(try Self.opaque(image), Self.outDir / "\(state.id)@\(Int(scale))x.png")
        ScreenStates.releaseHeld()
      }
    }
    // Both PNGs of every state are on disk, and nothing else is.
    let expected = Set(Self.ids.flatMap { ["\($0)@1x.png", "\($0)@2x.png"] })
    let written = Set(try FileManager.default.contentsOfDirectory(atPath: Self.outDir.path).filter { $0.hasSuffix(".png") })
    #expect(written == expected)
  }

  static let ids = ["empty", "one-clip", "reel", "reorder", "finder-drop", "multi-select", "over-3min", "strip-zoomed",
                    "missing-clip", "landscape-fit", "landscape-fill", "sheet-reel", "done", "narrow",
                    "loading", "exporting", "error", "ffmpeg-card", "keymap", "rename"]

  /// Ungated smoke: one state renders at 1x, full size and not blank, through the same path (nothing written).
  @Test func oneStateRenders() async throws {
    let state = try #require(ScreenStates.all.first { $0.id == "one-clip" })
    let image = try Self.still(try await state.make(1), state.size)
    #expect(image.width == 1240 && image.height == 860)
    #expect(try Self.topColourShare(image) < 0.95)
  }

  /// The missing line never hides playback: playing, the stage shows the preview.
  @Test func missingLineOnlyWhilePaused() async throws {
    let h = try await ScreenStates.missingClip()
    #expect(StageView<Color>.missingLine(h.model) != nil)
    h.model.play()
    #expect(h.model.isPlaying)
    #expect(StageView<Color>.missingLine(h.model) == nil)
  }

  /// The ffmpeg card's two lines are the §4.1 sentence, byte for byte, split at its full stop.
  @Test func ffmpegLinesAreTheSentence() {
    #expect(FFmpegCard.lines.joined(separator: " ") == FFmpegCard.sentence)
    #expect(FFmpegCard.sentence == "trimlab needs ffmpeg to open .mkv and .avi files. Install it with Homebrew:")
  }

  /// While any clip loads, the total is muted: it counts the 1 s stand-ins.
  @Test func totalMutedWhileLoading() async throws {
    let loading = try await ScreenStates.loading()
    #expect(InspectorView.totalInk(loading.model) == Tokens.muted)
    ScreenStates.releaseHeld()
    let reel = try await ScreenStates.reel()
    #expect(InspectorView.totalInk(reel.model) == Tokens.brandInk)
  }

  /// The export sheet hangs from the header (it was centred down the stage: the inspector's full-height spacer made
  /// its row as tall as the window).
  @Test func sheetHangsFromHeader() async throws {
    let h = try await ScreenStates.sheet()
    let image = try Self.still(ScreenStates.root(h, scale: 1), ScreenStates.window)
    let px = try StageViewTests.pixels(image)
    #expect(StageViewTests.rgb(px, image, x: 470, y: 60) == [0x14, 0x16, 0x1A], "the sheet's --bg-1 just under the header")
  }

  /// A missing primary clip puts the addendum's line on the stage in place of the preview.
  @Test func missingPrimaryShowsStageLine() async throws {
    let h = try await ScreenStates.missingClip()
    #expect(StageView<Color>.missingLine(h.model) == "IMG_4826.MOV is missing. Locate it or remove it from the Reel.")
    #expect(StageView<Color>.accessibilityLabel(h.model) == StageView<Color>.missingLine(h.model))
    let other = try await ScreenStates.reel()
    #expect(StageView<Color>.missingLine(other.model) == nil)
  }

  /// Stills leave out what they can't draw: no SwiftUI can't-render placeholder (its yellow) anywhere in the sheet,
  /// whose file name field is AppKit-backed, or over the strip, the Finder drop target.
  @Test func noPlaceholderInStills() async throws {
    let h = try await ScreenStates.sheet()
    let image = try Self.still(ScreenStates.root(h, scale: 1), ScreenStates.window)
    let px = try StageViewTests.pixels(image)
    var yellow = 0
    for y in stride(from: 0, to: image.height, by: 2) {
      for x in stride(from: 0, to: image.width, by: 2) {
        let c = StageViewTests.rgb(px, image, x: x, y: y)
        if c[0] > 240 && c[1] > 190 && c[2] < 40 { yellow += 1 }
      }
    }
    #expect(yellow == 0, "placeholder yellow: \(yellow)")
  }

  static func still(_ view: AnyView, _ size: CGSize) throws -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
      .environment(\.tlStillRender, true))
    return try #require(renderer.cgImage)
  }

  /// The window is opaque: written without an alpha channel, the committed PNGs are about a quarter smaller.
  static func opaque(_ image: CGImage) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return try #require(ctx.makeImage())
  }

  /// The share of the most common RGB value.
  static func topColourShare(_ image: CGImage) throws -> Double {
    let px = try StageViewTests.pixels(image)
    var counts: [UInt32: Int] = [:]
    for i in stride(from: 0, to: px.count, by: 4) {
      counts[UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2]), default: 0] += 1
    }
    return Double(counts.values.max() ?? 0) / Double(image.width * image.height)
  }

  /// Critique: a probing clip's stand-in facts never read as real numbers.
  @Test func probingClipReadsAsDash() {
    #expect(InspectorView.waiting(.probing) && InspectorView.waiting(.preparing))
    #expect(!InspectorView.waiting(.ready) && !InspectorView.waiting(.missing) && !InspectorView.waiting(nil))
    #expect(InspectorView.dash == "\u{2013}")
  }
}
