import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 38: every screen state, each built from an `EditorModel` over the test stubs and the mockup's stills,
/// sprites and peaks (`design/mockup-assets/`), with the same numbers as `design/mockup.html` (`BASE`,
/// `makeClips`, `stateModel`). The stage shows a still `CGImage` because `ImageRenderer` can't capture an
/// `AVPlayerLayer`. Lives with the tests, not in TrimlabEditor, because `StubMedia` is test-only.
@MainActor enum ScreenStates {
  typealias Make = @MainActor (_ scale: CGFloat) async throws -> AnyView
  static let window = CGSize(width: 1240, height: 860)
  static let narrowWindow = CGSize(width: 960, height: 860)

  static let all: [(id: String, size: CGSize, make: Make)] = [
    ("empty", window, { s in root(Harness(), scale: s) }),
    ("one-clip", window, { s in root(try await oneClip(), scale: s) }),
    ("reel", window, { s in root(try await reel(), scale: s) }),
    ("reorder", window, { s in root(try await reorder(), scale: s) }),
    ("finder-drop", window, { s in root(try await finderDrop(), scale: s) }),
    ("multi-select", window, { s in root(try await multiSelect(), scale: s) }),
    ("over-3min", window, { s in root(try await reel(scale: 5, target: 192.4), scale: s) }),
    ("strip-zoomed", window, { s in root(try await stripZoomed(), scale: s) }),
    ("missing-clip", window, { s in root(try await missingClip(), scale: s) }),
    ("landscape-fit", window, { s in root(try await landscape(.fit), scale: s) }),
    ("landscape-fill", window, { s in root(try await landscape(.fill), scale: s) }),
    ("sheet-reel", window, { s in root(try await sheet(), scale: s, hover: "export-cut") }),
    ("done", window, { s in root(try await done(), scale: s) }),
    ("narrow", narrowWindow, { s in root(try await reel(window: narrowWindow), scale: s) }),
    ("loading", window, { s in root(try await loading(), scale: s) }),
    ("exporting", window, { s in root(try await exporting(), scale: s) }),
    ("error", window, { s in root(try await failed(), scale: s) }),
    ("ffmpeg-card", window, { s in root(try await ffmpegCard(), scale: s) }),
    ("keymap", window, { s in root(try await keyMap(), scale: s) }),
    ("rename", window, { s in root(try await renaming(), scale: s) }),
  ]

  // MARK: the mockup's numbers

  static let fps = RationalTime(1001, 30000)

  /// `BASE` in `design/mockup.html`: trimmed length (s), source length (s), and the special clips.
  struct Base {
    var len: Double
    var src: Double
    var join: Join = .cut
    var wide = false
  }

  static let base: [Base] = [
    Base(len: 2.4, src: 9.8), Base(len: 3.1, src: 12.1), Base(len: 1.8, src: 11.0),
    Base(len: 0, src: 23.6),
    Base(len: 2.2, src: 8.0), Base(len: 3.4, src: 12.4, wide: true), Base(len: 1.6, src: 11.0),
    Base(len: 2.9, src: 7.7, join: .crossfade(Limits.longFade)), Base(len: 2.4, src: 14.2), Base(len: 0.6, src: 10.0),
    Base(len: 2.2, src: 26.0), Base(len: 1.9, src: 7.7), Base(len: 3.3, src: 7.7, join: .crossfade(Limits.shortFade)),
    Base(len: 1.5, src: 6.0), Base(len: 2.8, src: 9.1), Base(len: 2.1, src: 13.4), Base(len: 1.2, src: 12.3),
    Base(len: 0, src: 7.7),
  ]

  /// Seconds on the 29.97 grid: the start of the frame that holds `s` (the mockup floors its frame numbers).
  static func grid(_ s: Double) -> RationalTime { fps * Int64((s * 30000 / 1001).rounded(.down)) }

  /// The start of the frame that reads `m:ss.ff`.
  static func tc(_ s: Int64, _ f: Int64) -> RationalTime { StageViewTests.tc(s, f) }

  static func facts(duration: Double, wide: Bool = false, hdr: HDRKind = .sdr) -> ClipFacts {
    ClipFacts(duration: grid(duration), frameDuration: fps, displayWidth: wide ? 1920 : 1080,
              displayHeight: wide ? 1080 : 1920, rotation: 0, videoCodec: "hevc", hasAudio: true, hdr: hdr,
              bitrate: 10_000_000, captureDate: nil, needsRemux: false)
  }

  static func name(_ i: Int) -> String { "IMG_\(4818 + i).MOV" }

  /// The #reel Reel: 18 clips of Spa Tour, clip 4 (IMG_4821, 23.6 s HLG, In 0:01.21, Out 0:10.07) selected, Long
  /// into clip 8, Short into clip 13; the last clip absorbs the rounding so the total reads `target` (48.2 s).
  /// `scale` stretches every trimmed length (5 and 192.4 give #over-3min). The playhead sits 4.0 s into clip 4's
  /// source, as the mockup's `srcPlay`.
  static func reel(scale: Double = 1, target: Double = 48.2, window: CGSize = window) async throws -> Harness {
    let h = Harness()
    size(h, window)
    let ins = base.enumerated().map { i, b in i == 3 ? 1 + 21.0 / 29.97 : min(1.2, b.src * 0.1) }
    var outs = base.enumerated().map { i, b in i == 3 ? 10 + 7.0 / 29.97 : ins[i] + b.len * scale }
    // The last clip's length: what's left of `target` after the others and the fades.
    var rest = 0.0
    for i in 0..<17 {
      rest += outs[i] - ins[i]
      if case .crossfade(let f) = base[i].join, i > 0 {
        rest -= min(f.seconds, 0.5 * min(outs[i - 1] - ins[i - 1], outs[i] - ins[i]))
      }
    }
    outs[17] = ins[17] + (target - rest)
    for i in 0..<18 {
      let src = i == 3 ? base[i].src : max(base[i].src, outs[i] + 0.5)
      h.media.script(name(i), .facts(facts(duration: src, wide: base[i].wide, hdr: i == 3 ? .hlg : .sdr)))
      h.media.date(name(i), Date(timeIntervalSince1970: Double(1_000 + i)))
    }
    await h.importAll((0..<18).map(name), in: "/Spa Tour")
    let ids = try #require(h.model.reel?.clips.map(\.id))
    #expect(ids.count == 18)
    for (i, id) in ids.enumerated() {
      if i == 3 {
        h.model.perform(.setIn(id, tc(1, 21)), coalesce: nil)
        h.model.perform(.setOut(id, tc(10, 7)), coalesce: nil)
      } else {
        h.model.perform(.setIn(id, grid(ins[i])), coalesce: nil)
        h.model.perform(.setOut(id, grid(outs[i])), coalesce: nil)
      }
      if base[i].join != .cut { h.model.perform(.setJoin(id, base[i].join), coalesce: nil) }
    }
    h.model.select(ids[3], extend: false, toggle: false)
    try await dress(h)
    try seekSource(h, clip: 3, seconds: 4.0)
    return h
  }

  /// The strip and deck widths the window lays out (the bottom block's 20 px side padding; the deck spans it).
  static func size(_ h: Harness, _ window: CGSize) {
    h.model.stripResized(width: window.width - 2 * Tokens.Layout.deckPad)
    h.model.deckResized(width: window.width)
  }

  /// Releases the probes `loading()` holds.
  static func releaseHeld() {
    for (h, _) in loadingTasks { h.media.release() }
    loadingTasks = []
  }

  /// Parks the Reel playhead `seconds` into clip `i`'s source.
  static func seekSource(_ h: Harness, clip i: Int, seconds: Double) throws {
    let clip = try #require(h.model.reel?.clips[i])
    let start = try #require(h.model.plan?.placements.first { $0.clipID == clip.id }?.reelSpan.start)
    h.model.seek(reelTime: start + (grid(seconds) - clip.inTime))
  }

  /// The mockup's #one-clip: clip 4 alone, the playhead at 0:02.08.
  static func oneClip() async throws -> Harness {
    let h = Harness()
    size(h, window)
    h.media.script("IMG_4821.MOV", .facts(facts(duration: 23.6, hdr: .hlg)))
    await h.importAll(["IMG_4821.MOV"], in: "/Spa Tour")
    let id = try #require(h.model.reel?.clips.first?.id)
    h.model.perform(.setIn(id, tc(1, 21)), coalesce: nil)
    h.model.perform(.setOut(id, tc(10, 7)), coalesce: nil)
    try await dress(h, sprite: { _ in 3 })
    h.model.seek(reelTime: tc(2, 8))
    return h
  }

  /// Clip 4 dragged to the gap between clips 9 and 10 (the mockup's `drag: {from: [3], gap: 9}`).
  static func reorder() async throws -> Harness {
    let h = try await reel()
    let L = h.model.stripLayout()
    let grab = CGPoint(x: L.tiles[3].rect.minX + 8, y: L.tiles[3].rect.midY)  // the ghost hangs right of the caret, as drawn
    h.model.stripPress(at: grab)
    let gapX = (L.tiles[8].rect.maxX + L.tiles[9].rect.minX) / 2
    h.model.stripDrag(to: CGPoint(x: grab.x + 20, y: grab.y))
    h.model.stripDrag(to: CGPoint(x: gapX, y: grab.y))
    #expect(h.model.activeDrag?.caretGap == 9, "reorder caret at \(String(describing: h.model.activeDrag?.caretGap))")
    return h
  }

  /// Finder clips over the strip at the gap between clips 11 and 12: the caret only.
  static func finderDrop() async throws -> Harness {
    let h = try await reel()
    let L = h.model.stripLayout()
    let x = (L.tiles[10].rect.maxX + L.tiles[11].rect.minX) / 2
    h.model.finderDragOver(at: CGPoint(x: x, y: L.tiles[10].rect.midY), count: 2)
    #expect(h.model.activeDrag?.caretGap == 11)
    return h
  }

  /// Clips 4–7 selected, clip 4 primary.
  static func multiSelect() async throws -> Harness {
    let h = try await reel()
    let ids = try #require(h.model.reel?.clips.map(\.id))
    h.model.select(ids[6], extend: false, toggle: false)
    h.model.select(ids[3], extend: true, toggle: false)
    #expect(h.model.selection.primary == ids[3] && h.model.selection.all.count == 4)
    try seekSource(h, clip: 3, seconds: 4.0)
    return h
  }

  /// 64 px/s, scrolled so the playhead sits 40 % in (the mockup's `SCROLL = phx − W·0.4`).
  static func stripZoomed() async throws -> Harness {
    let h = try await reel()
    h.model.stripZoom = .pxPerSecond(64)
    h.model.stripScrollX = 0
    let L = h.model.stripLayout()
    h.model.stripScrollX = max(0, L.x(for: h.model.playhead) - L.width * 0.4)
    return h
  }

  /// Clip 9 (IMG_4826) missing and selected.
  static func missingClip() async throws -> Harness {
    let h = try await reel()
    let ids = try #require(h.model.reel?.clips.map(\.id))
    h.model.missing.insert(ids[8])
    h.model.replan()
    h.model.seek(reelTime: try #require(h.model.plan?.placements.first { $0.clipID == ids[9] }?.reelSpan.start))
    h.model.select(ids[8], extend: false, toggle: false)
    return h
  }

  /// Clip 6 (IMG_4823, 1920×1080) selected and peeked at 7.6 s of its source; `framing` Fit or Fill.
  static func landscape(_ framing: Framing) async throws -> Harness {
    let h = try await reel()
    let ids = try #require(h.model.reel?.clips.map(\.id))
    if framing != .fill { h.model.perform(.setFraming([ids[5]], framing), coalesce: nil) }
    h.model.select(ids[5], extend: false, toggle: false)
    await h.model.pendingPreview?.value
    h.model.peek(sourceTime: grid(7.6))
    #expect(await eventually { h.model.peekPlayer != nil }, "no peek player")
    return h
  }

  /// The export sheet over #reel; the pointer rests on Cut so Quick's tip shows (`tlStillHover`).
  static func sheet() async throws -> Harness {
    let h = try await reel()
    h.model.requestExport()
    #expect(h.model.exportSheetOpen)
    await settle()
    return h
  }

  /// The sheet's Done pane: Spa Tour.mp4, 84.1 MB, with the first frame.
  static func done() async throws -> Harness {
    let h = try await running()
    let dest = try #require(h.media.exports.first?.dest)
    h.media.send(.done(ExportResult(url: dest, bytes: 84_100_000, firstFrame: image("saved-thumb.jpg"),
                                    usedSoftwareEncoder: false)))
    h.media.finishExport()
    #expect(await eventually { if case .done = h.model.exportState { true } else { false } })
    return h
  }

  /// The sheet mid-export: 42 %, about a minute left.
  static func exporting() async throws -> Harness {
    let h = try await running()
    h.media.send(.progress(0.42, eta: 75))
    #expect(await eventually { h.model.exportPercentLine == "42%" })
    return h
  }

  /// The sheet's Error pane, Details open.
  static func failed() async throws -> Harness {
    let h = try await running()
    h.media.scriptLog((1...30).map { "export: segment \($0) written" })
    h.media.finishExport(throwing: ExportFailed(error: .diskFull, cause: nil))
    #expect(await eventually { if case .failed = h.model.exportState { true } else { false } })
    h.model.toggleExportDetails()
    return h
  }

  static func running() async throws -> Harness {
    let h = try await reel()
    h.model.requestExport()
    h.model.startExport()
    #expect(await h.media.waitForExports(1))
    return h
  }

  /// Six clips imported, four still probing (tiles and inspector waiting).
  static func loading() async throws -> Harness {
    let h = Harness()
    size(h, window)
    for i in 0..<6 {
      h.media.script(name(i), .facts(facts(duration: max(base[i].src, 6), wide: base[i].wide, hdr: i == 3 ? .hlg : .sdr)))
      h.media.date(name(i), Date(timeIntervalSince1970: Double(1_000 + i)))
    }
    h.media.state.withLock { $0.holdAfter = 2 }
    let task = h.model.importURLs((0..<6).map { Harness.url(name($0), in: "/Spa Tour") }, at: nil)
    #expect(await h.media.waitForProbes(6))
    #expect(await h.media.waitForFinished(2))
    await settle()
    let ids = try #require(h.model.reel?.clips.map(\.id))
    #expect(ids.count == 6)
    let probing = try #require(ids.first { h.model.loading[$0] == .probing }, "no clip is still probing")
    h.model.select(probing, extend: false, toggle: false)  // a clip still probing: the inspector waits
    try await dress(h, only: 2)
    loadingTasks.append((h, task))
    return h
  }

  /// Probes left held by `loading()`, released after the render.
  static var loadingTasks: [(Harness, Task<Void, Never>)] = []

  /// #reel with the header's Reel name open for renaming (§6.1): the field in its focused well.
  static func renaming() async throws -> Harness {
    let h = try await reel()
    h.model.beginRenameReel()
    #expect(h.model.editingReelName)
    return h
  }

  /// An .mkv dropped with no ffmpeg on the Mac.
  static func ffmpegCard() async throws -> Harness {
    let h = try await reel()
    h.model.openFFmpegCard(refusing: [URL(filePath: "/Spa Tour/IMG_4840.mkv")])
    #expect(h.model.ffmpegCardOpen)
    return h
  }

  /// `?` over #reel.
  static func keyMap() async throws -> Harness {
    let h = try await reel()
    h.model.showKeyMap()
    #expect(h.model.keyMapOpen)
    return h
  }

  // MARK: dressing

  /// The mockup's sprite per clip (`sprite` maps a clip's index to its sprite) and the mockup's peaks; also waits
  /// for the preview. `only` dresses just the first clips (the rest still loading).
  static func dress(_ h: Harness, sprite: (Int) -> Int = { $0 }, only: Int? = nil) async throws {
    let clips = h.model.reel?.clips ?? []
    let peaks = try peakValues()
    for (i, clip) in clips.enumerated() where only.map({ i < $0 }) ?? true {
      let url = SourceScan.repoRoot / String(format: "design/mockup-assets/sprite-%02d.jpg", sprite(i) + 1)
      let grid = try #require(image(url))
      let cw = grid.width / 8, ch = grid.height / 5
      let frames = try (0..<40).map { k in
        try #require(grid.cropping(to: CGRect(x: (k % 8) * cw, y: (k / 8) * ch, width: cw, height: ch)))
      }
      let d = clip.facts.duration
      h.model.stripSprites[clip.source] = StripSprite(frames: frames, times: (0..<40).map {
        RationalTime(d.value * Int64($0), d.timescale * 40)
      })
      // 50 peaks a second, read from the mockup's file at the clip's own offset (`c.spr * 37`).
      let n = Int((d.seconds * 50).rounded(.up))
      h.model.deckPeaks[clip.source] = (0..<n).map { Float16(peaks[($0 + sprite(i) * 37) % peaks.count]) }
    }
    await h.model.pendingPreview?.value
  }

  static func peakValues() throws -> [Double] {
    struct File: Decodable { let peaks: [Double] }
    let data = try Data(contentsOf: SourceScan.repoRoot / "design/mockup-assets/peaks.json")
    return try JSONDecoder().decode(File.self, from: data).peaks
  }

  static func image(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  static func image(_ asset: String) -> CGImage? { image(SourceScan.repoRoot / "design/mockup-assets/\(asset)") }

  // MARK: the window

  /// The window with the real DCV logo (`Logo.render` from the repo's PDF, as the app does from its bundle) and the
  /// mockup's stills on the stage: the landscape one for a peek, the portrait one for the Reel.
  static func root(_ h: Harness, scale: CGFloat, hover: String? = nil) -> AnyView {
    let logo = Logo.render(pdf: SourceScan.repoRoot / "Resources/Assets/dcv-logo-white.pdf",
                           height: HeaderView.logoHeight, scale: scale)
    let portrait = image("still-portrait.jpg"), landscape = image("still-landscape.jpg")
    let model = h.model
    return AnyView(RootView(model: model, logo: logo) { player in
      if let still = player === model.peekPlayer ? landscape : portrait {
        Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill)
      }
    }
    .environment(\.tlStillHover, hover))
  }

  // MARK: waiting

  static func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }

  /// Yields, then 1 ms naps, until `condition` holds; false after 5 s.
  static func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      if ContinuousClock.now > deadline { return false }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(1))
    }
    return true
  }
}
