import CoreGraphics
import Foundation
import ImageIO
import Observation
import Synchronization
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 28: the strip's geometry (§4.3.1) and its one-`Canvas` drawing.
@MainActor @Suite struct StripLayoutTests {
  static let fps = RationalTime(1001, 30000)
  static let row = Tokens.Layout.stripCap + Tokens.Layout.stripTile / 2  // the tile row's middle

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  // MARK: helpers

  /// A 9:16 clip kept for `len` from 0.
  static func clip(_ len: RationalTime, join: Join = .cut, name: String = "IMG_4821.MOV") -> ReelClip {
    let facts = ClipFacts(duration: len, frameDuration: fps, displayWidth: 1080, displayHeight: 1920, rotation: 0,
                          videoCodec: "hevc", hasAudio: true, hdr: .sdr, bitrate: 10_000_000, captureDate: nil,
                          needsRemux: false)
    var c = ReelClip.make(source: SourceRef(relativePath: nil, absolutePath: "/Spa Tour/\(name)", size: 1,
                                            modified: Date(timeIntervalSince1970: 0)),
                          facts: facts, framing: .fill)
    c.join = join
    return c
  }

  static func s(_ seconds: Int64, _ per: Int32 = 1) -> RationalTime { RationalTime(seconds, per) }

  static func layout(_ clips: [ReelClip], width: CGFloat, zoom: StripZoom = .fit,
                     format: ExportSpec.Format = .reel) -> StripLayout {
    let reel = Reel(id: UUID(), name: "T", clips: clips, export: ExportSpec(format: format))
    return StripLayout(plan: Planner.plan(reel), clips: clips, width: width, zoom: zoom, format: format)
  }

  // MARK: geometry

  @Test func fitFillsWidth() {
    let L = Self.layout([Self.clip(Self.s(2)), Self.clip(Self.s(3)), Self.clip(Self.s(5))], width: 1000)
    #expect(L.tiles.count == 3)
    #expect(L.tiles[0].rect.minX == 0)
    #expect(abs(L.tiles[2].rect.maxX - 1000) < 1e-6)
    #expect(abs(L.contentWidth - 1000) < 1e-6)
    #expect(abs(L.tiles[1].rect.minX - L.tiles[0].rect.maxX - 2) < 1e-9, "2 px gap at a cut")
    #expect(abs(L.tiles[2].rect.minX - L.tiles[1].rect.maxX - 2) < 1e-9)
    #expect(abs(L.pxPerSecond - 99.6) < 1e-9, "(1000 − 2 gaps) / 10 s")
    #expect(abs(L.tiles[2].rect.width - 498) < 1e-6)
    for t in L.tiles {
      #expect(t.rect.minY == Tokens.Layout.stripCap && t.rect.height == Tokens.Layout.stripTile)
    }
  }

  @Test func minWidthTileDoesNotShiftOthers() {
    let clips = [Self.clip(Self.s(10)), Self.clip(Self.s(10)), Self.clip(Self.s(4, 10)), Self.clip(Self.s(10)),
                 Self.clip(Self.s(10))]
    let L = Self.layout(clips, width: 1000)
    #expect(abs(L.tiles[2].rect.width - 24) < 1e-9, "the tiny tile is exactly 24 px")
    #expect(abs(L.contentWidth - 1000) < 1e-6, "Fit still fills the width")
    for i in [0, 1, 3, 4] { #expect(abs(L.tiles[i].rect.width - 10 * L.pxPerSecond) < 1e-9) }
    // x ↔ time round-trips within a frame for samples in every tile.
    for tile in L.tiles {
      for k in 0..<5 {
        let t = tile.reelSpan.start + RationalTime(tile.reelSpan.duration.value * Int64(k), tile.reelSpan.duration.timescale * 5)
        let back = L.time(at: L.x(for: t))
        #expect(abs(back.seconds - t.seconds) < Self.fps.seconds, "\(t.seconds) → \(back.seconds)")
      }
    }
    // The time scale inside the normal tiles is px/s exactly; the tiny tile doesn't move time elsewhere.
    let start3 = L.tiles[3].reelSpan.start
    #expect(abs(L.x(for: start3 + Self.s(5)) - (L.tiles[3].rect.minX + 5 * L.pxPerSecond)) < 1e-6)
  }

  /// Fix round 1: Fit always fits; a long Reel lowers the minimum tile (to 4 px), then the gaps (1, then 0 px).
  @Test func fitNeverOverflowsSixtyClips() {
    let L = Self.layout((0..<60).map { _ in Self.clip(Self.s(3)) }, width: 1200)
    #expect(L.fits)
    #expect(abs(L.contentWidth - 1200) < 1e-6, "content \(L.contentWidth)")
    #expect(abs(L.tiles[0].rect.width * 60 + 59 * 2 - 1200) < 1e-6, "equal tiles, 2 px gaps")
    #expect(L.pxPerSecond > 0)
    // Each tile's time scale is its own: the round trip holds.
    let t = RationalTime(91, 1)
    #expect(abs(L.time(at: L.x(for: t)).seconds - t.seconds) < Self.fps.seconds)
  }

  @Test func fitNeverOverflowsAThousandClips() {
    let clips = (0..<1000).map { _ in Self.clip(Self.s(3)) }
    let L = Self.layout(clips, width: 1200)
    #expect(L.contentWidth <= 1200 + 1e-6, "content \(L.contentWidth)")
    #expect(L.tiles.allSatisfy { $0.rect.width >= 1 })
    #expect(L.pxPerSecond > 0, "a real px/s, never 0")
    for k in stride(from: 0, to: 3000, by: 37) {
      let t = RationalTime(Int64(k) * 10 + 7, 10)
      let back = L.time(at: L.x(for: t))
      #expect(abs(back.seconds - t.seconds) < Self.fps.seconds, "\(t.seconds) → \(back.seconds)")
    }
  }

  /// Squeezed tiles: a crossfade's overlap never covers more than half the shorter tile.
  @Test func squeezedCrossfadeOverlapIsCapped() {
    var clips = (0..<300).map { _ in Self.clip(Self.s(3)) }
    for i in stride(from: 1, to: 300, by: 2) { clips[i].join = .crossfade(Limits.longFade) }
    let L = Self.layout(clips, width: 1200)
    #expect(L.contentWidth <= 1200 + 1e-6)
    for i in L.tiles.indices.dropFirst() where L.tiles[i].overlapLeft > 0 {
      #expect(L.tiles[i].overlapLeft <= min(L.tiles[i].rect.width, L.tiles[i - 1].rect.width) / 2 + 1e-9)
    }
  }

  @Test func fitsOnlyInFit() {
    #expect(!Self.layout([Self.clip(Self.s(3))], width: 300, zoom: .pxPerSecond(50)).fits)
  }

  @Test func crossfadeTilesOverlap() {
    // Long (1 s) into a 1.2 s clip: effective 0.6 s (F7, exact).
    let clips = [Self.clip(Self.s(4)), Self.clip(Self.s(12, 10), join: .crossfade(Limits.longFade)),
                 Self.clip(Self.s(4), join: .crossfade(Limits.shortFade))]
    let L = Self.layout(clips, width: 800)
    let p = L.pxPerSecond
    #expect(abs(L.tiles[1].overlapLeft - 0.6 * p) < 1e-9)
    #expect(abs(L.tiles[0].rect.maxX - L.tiles[1].rect.minX - 0.6 * p) < 1e-9, "no gap, an overlap")
    #expect(abs(L.tiles[2].overlapLeft - 0.25 * p) < 1e-9)
    #expect(L.tiles[0].overlapLeft == 0)
    #expect(abs(L.contentWidth - 800) < 1e-6)
  }

  @Test func gapAtNearestBoundary() {
    let L = Self.layout((0..<5).map { _ in Self.clip(Self.s(2)) }, width: 1000)
    #expect(L.gap(at: L.tiles[2].rect.midX + 1) == 3)
    #expect(L.gap(at: L.tiles[2].rect.midX - 1) == 2)
    #expect(L.gap(at: -50) == 0)
    #expect(L.gap(at: 5000) == 5)
  }

  @Test func joinHitReturnsIncoming() {
    let clips = [Self.clip(Self.s(4)), Self.clip(Self.s(4)), Self.clip(Self.s(4), join: .crossfade(Limits.longFade))]
    let L = Self.layout(clips, width: 900)
    let cut = CGPoint(x: L.tiles[0].rect.maxX + 1, y: Self.row)
    #expect(L.joinHit(at: cut) == clips[1].id)
    let fade = CGPoint(x: L.tiles[2].rect.minX + L.tiles[2].overlapLeft / 2, y: Self.row)
    #expect(L.joinHit(at: fade) == clips[2].id)
    #expect(L.joinHit(at: CGPoint(x: L.tiles[0].rect.midX, y: Self.row)) == nil)
    #expect(L.joinHit(at: CGPoint(x: cut.x, y: 4)) == nil, "the cap row isn't a join")
    #expect(L.tile(at: CGPoint(x: L.tiles[1].rect.midX, y: Self.row)) == clips[1].id)
    #expect(L.tile(at: fade) == clips[2].id, "the incoming tile is on top in an overlap")
    #expect(L.tile(at: CGPoint(x: L.tiles[1].rect.midX, y: 75)) == nil)
  }

  @Test func limitXOnlyOverThreeMinutes() throws {
    let under = Self.layout([Self.clip(Self.s(90)), Self.clip(Self.s(899, 10))], width: 1000)
    #expect(under.limitX == nil)
    let over = Self.layout([Self.clip(Self.s(90)), Self.clip(Self.s(91))], width: 1000)
    let x = try #require(over.limitX)
    #expect(x == over.x(for: Limits.reelMax))
    #expect(x > over.tiles[1].rect.minX && x < over.tiles[1].rect.maxX)
  }

  /// Controller ruling: the 3:00 marker is Reel-format only, like `EditorModel.overLimit` (Task 27).
  @Test func limitXIsReelOnly() {
    let L = Self.layout([Self.clip(Self.s(90)), Self.clip(Self.s(91))], width: 1000, format: .original)
    #expect(L.limitX == nil)
  }

  /// Review Focus 4: a live handle drag draws from `draftReel`, so the marker follows a draft that crosses 3:00.
  @Test func limitMarkerFollowsDraftTrim() async throws {
    let h = Harness()
    h.media.script("a.MOV", .facts(StubMedia.facts(RationalTime(200, 1))))
    h.media.script("b.MOV", .facts(StubMedia.facts(RationalTime(200, 1))))
    await h.importAll(["a.MOV", "b.MOV"])
    let ids = try #require(h.model.reel?.clips.map(\.id))
    h.model.perform(.setOut(ids[0], RationalTime(90, 1)), coalesce: nil)
    h.model.perform(.setOut(ids[1], RationalTime(89, 1)), coalesce: nil)
    let committed = try #require(h.model.reel)
    #expect(ReelStripView.layout(h.model, width: 1000).limitX == nil)

    var draft = committed
    draft.clips[1].outTime = RationalTime(95, 1)
    h.model.draftReel = draft
    let live = ReelStripView.layout(h.model, width: 1000)
    #expect(live.limitX != nil, "the draft runs to 3:05")
    #expect(h.model.reel == committed, "a draft is never committed")
    // The committed Reel's own layout is still under 3:00.
    let plain = StripLayout(plan: try #require(h.model.plan), clips: committed.clips, width: 1000, zoom: .fit)
    #expect(plain.limitX == nil)
    h.model.draftReel = nil
    #expect(ReelStripView.layout(h.model, width: 1000).limitX == nil)
    // Nor recorded: one undo takes back the last real edit, not the draft.
    h.model.undo()
    #expect(h.model.reel?.clips[1].outTime == RationalTime(200, 1))
  }

  @Test func zoomMax200() {
    let L = Self.layout([Self.clip(Self.s(2)), Self.clip(Self.s(3))], width: 300, zoom: .pxPerSecond(500))
    #expect(L.pxPerSecond == 200)
    #expect(L.tiles[1].rect.width == 600)
    #expect(L.contentWidth == 1002)
    let mid = Self.layout([Self.clip(Self.s(2))], width: 300, zoom: .pxPerSecond(64))
    #expect(mid.pxPerSecond == 64)
  }

  @Test func scrollShiftsTiles() {
    let clips = [Self.clip(Self.s(10))]
    let L = StripLayout(plan: Planner.plan(Reel(id: UUID(), name: "T", clips: clips)),
                        clips: clips, width: 300, zoom: .pxPerSecond(100), scrollX: 250)
    #expect(L.tiles[0].rect.minX == -250)
    #expect(L.time(at: 0) == Self.s(5, 2))
  }

  // MARK: model

  /// Waits (up to 5 s, polling every 2 ms) until the frames the model asked for by itself (`watchStripSources`, on
  /// the next main-actor turn after a change) have been made or have failed: the watcher has seen the current
  /// sources, no worker runs and nothing is queued, three polls in a row (a watcher turn may still be pending).
  static func stripIdle(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) async {
    let m = h.model
    var quiet = 0
    for _ in 0..<2_500 {
      let idle = m.stripSourcesAsked == m.stripSpriteSources && m.spriteWorker == nil && m.session.stripQueue.isEmpty
      quiet = idle ? quiet + 1 : 0
      if quiet >= 3 { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("the strip never went idle", sourceLocation: sourceLocation)
  }

  /// Opens a stored Reel of `names` in /shoot: every tile is ready in the same turn, so the model's one ask sees them
  /// all (an import readies them a probe at a time).
  static func openReel(_ h: Harness, _ names: [String], placeholder: Set<String> = []) {
    let clips = names.map { name in
      var clip = ProjectTests.stored("/shoot/\(name)")
      if placeholder.contains(name) { clip.extra[EditorModel.needsProbeKey] = .bool(true) }
      return clip
    }
    ProjectTests.openStored(h, clips)
  }

  /// Sprites come through `media.sprite(clip, at: url(for:))`; missing and loading tiles ask for none. A failed
  /// sprite gets one retry on the next request, then no more.
  @Test func spritesOnlyForReadyClips() async throws {
    let h = Harness()
    h.media.unresolvable(["b.MOV"])  // missing
    h.media.hold()  // c was saved while loading: it is probed again and stays probing until the release
    Self.openReel(h, ["a.MOV", "b.MOV", "c.MOV"], placeholder: ["c.MOV"])
    let ids = try #require(h.model.reel?.clips.map(\.id))
    try #require(h.model.missing == [ids[1]] && h.model.loading[ids[2]] == .probing)
    await Self.stripIdle(h)
    for _ in 0..<3 {
      h.model.requestStripSprites()
      await h.model.spriteWorker?.value
    }
    #expect(h.media.spriteRequests == ["/shoot/a.MOV", "/shoot/a.MOV"], "one retry, then no more")
    #expect(h.model.spritePending.isEmpty)
    h.media.release()
    await h.model.pendingReprobe?.value
    await Self.stripIdle(h)
    #expect(h.media.spriteRequests == ["/shoot/a.MOV", "/shoot/a.MOV", "/shoot/c.MOV"], "c asks once it's in")
  }

  /// Up to 3 sprites are made at once; a queued sprite whose clip has left the Reel is dropped.
  @Test func spritesThreeAtOnceAndDropLeavers() async throws {
    let h = Harness()
    let names = (0..<7).map { "s\($0).MOV" }
    h.media.spriteDelay(.milliseconds(30))
    Self.openReel(h, names)
    let ids = try #require(h.model.reel?.clips.map(\.id))
    h.model.requestStripSprites()
    h.model.perform(.delete([ids[6]]), coalesce: nil)  // before any worker reaches it
    await Self.stripIdle(h)
    #expect(h.media.maxSpriteInFlight == 3)
    #expect(Set(h.media.spriteRequests) == Set(names.prefix(6).map { "/shoot/\($0)" }))
    #expect(h.model.spritePending.isEmpty)
  }

  /// §4.1 / §10 (M-5): every tile's poster is asked for before any sprite, so a cold strip shows a frame per tile
  /// in well under a second while the 40-frame sprites (about 1 s each) follow.
  @Test func postersBeforeSprites() async throws {
    let h = Harness()
    h.media.postersWork(true)
    let names = (0..<7).map { "p\($0).MOV" }
    Self.openReel(h, names)
    await Self.stripIdle(h)
    let asked = h.media.thumbRequests
    let firstSprite = try #require(asked.firstIndex { $0.hasPrefix("sprite ") })
    #expect(Set(asked[..<firstSprite]) == Set(names.map { "poster /shoot/\($0)" }), "\(asked)")
    #expect(asked.filter { $0.hasPrefix("poster ") }.count == names.count, "one poster per file")
  }

  /// A tile with a poster and no sprite yet draws the poster and doesn't shimmer; a failed poster leaves the shimmer
  /// to the sprite as before.
  @Test func posterStandsInUntilTheSprite() async throws {
    let h = Harness()
    h.media.postersWork(true)
    h.media.spriteDelay(.seconds(30))  // the sprites never land during the test
    await h.importAll(["a.MOV", "b.MOV"])
    for _ in 0..<200 where h.model.stripPosters.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    let ids = try #require(h.model.reel?.clips.map(\.id))
    let content = ReelStripView.content(h.model, width: 1000)
    #expect(Set(content.sprites.keys) == Set(ids), "both tiles draw their poster")
    #expect(content.state.loading.isEmpty, "a tile with a poster doesn't shimmer")
    #expect(h.model.spritePending.count == 2, "the sprites are still on their way")
    h.model.spriteWorker?.cancel()
  }

  /// M-5: on a zoomed, scrolled strip the tiles on screen get their posters and sprites before the ones off it.
  @Test func visibleTilesFirst() async throws {
    let h = Harness()
    h.media.postersWork(true)
    let names = (0..<12).map { "v\($0).MOV" }
    Self.openReel(h, names)  // the model asks on its next turn; opening resets the zoom, so it is set after
    h.model.stripResized(width: 300)
    h.model.stripZoom = .pxPerSecond(400)
    h.model.stripScrollX = 1_000_000  // to the end (the layout clamps it): the last tiles are the ones on screen
    let L = h.model.stripLayout()
    let reel = try #require(h.model.reel)
    let onScreen = Set(L.tiles.filter { $0.rect.maxX >= 0 && $0.rect.minX <= 300 }
      .compactMap { t in reel.clips.first { $0.id == t.id } }.map(\.source.absolutePath))
    try #require(!onScreen.isEmpty && onScreen.count < names.count)
    await Self.stripIdle(h)
    let asked = h.media.thumbRequests
    let posters = asked.filter { $0.hasPrefix("poster ") }.map { String($0.dropFirst(7)) }
    let sprites = asked.filter { $0.hasPrefix("sprite ") }.map { String($0.dropFirst(7)) }
    #expect(Set(posters.prefix(onScreen.count)) == onScreen, "\(posters)")
    #expect(Set(sprites.prefix(onScreen.count)) == onScreen, "\(sprites)")
  }

  /// Task 42 acceptance 2, miss 1: with the window covered SwiftUI stops running the strip view's `.task(id:)`, so the
  /// tiles whose probes landed after that never asked for frames. The model asks by itself as tiles become ready:
  /// here no view exists at all, and every tile still gets its poster and sprite asked for.
  @Test func everyTileAsksWithoutTheView() async throws {
    let h = Harness()
    h.media.postersWork(true)
    let names = (0..<18).map { "w\($0).MOV" }
    await h.importAll(names)
    let all = Set(names.map { "/shoot/\($0)" })
    for _ in 0..<400 where Set(h.media.spriteRequests) != all { try await Task.sleep(for: .milliseconds(5)) }
    let asked = h.media.thumbRequests
    #expect(Set(asked.filter { $0.hasPrefix("poster ") }.map { String($0.dropFirst(7)) }) == all, "\(asked)")
    #expect(Set(asked.filter { $0.hasPrefix("sprite ") }.map { String($0.dropFirst(7)) }) == all, "\(asked)")
    #expect(h.model.stripPosters.count == 18, "every tile draws its poster")
  }

  /// The field pattern: the first wave's frames are already being made (or done) when the rest of the batch's
  /// probes land. Those later tiles are asked for too, with no view to re-ask.
  @Test func tilesThatSettleLaterStillAsk() async throws {
    let h = Harness()
    h.media.postersWork(true)
    h.media.state.withLock { $0.holdAfter = 4 }  // four answer, the other fourteen wait
    let names = (0..<18).map { "l\($0).MOV" }
    let batch = h.model.importURLs(names.map { Harness.url($0) }, at: nil)
    let first = Set(names.prefix(4).map { "/shoot/\($0)" })
    for _ in 0..<400 where !first.isSubset(of: Set(h.media.spriteRequests)) { try await Task.sleep(for: .milliseconds(5)) }
    try #require(first.isSubset(of: Set(h.media.spriteRequests)), "the first wave asks while the rest are held")
    for _ in 0..<400 where h.model.spriteWorker != nil { try await Task.sleep(for: .milliseconds(5)) }
    h.media.release()
    await batch.value
    let all = Set(names.map { "/shoot/\($0)" })
    for _ in 0..<400 where Set(h.media.spriteRequests) != all { try await Task.sleep(for: .milliseconds(5)) }
    #expect(Set(h.media.spriteRequests) == all, "\(h.media.spriteRequests)")
    #expect(h.model.stripPosters.count == 18)
  }

  /// The watcher asks only when the sources change, but a reset forgets what it asked for: reopening the same Reel
  /// (same sources, frames cleared) asks for them all again.
  @Test func reopeningTheSameReelAsksAgain() async throws {
    let h = Harness()
    h.media.postersWork(true)
    let names = ["r0.MOV", "r1.MOV", "r2.MOV"]
    Self.openReel(h, names)
    await Self.stripIdle(h)
    try #require(h.model.stripPosters.count == 3)
    Self.openReel(h, names)
    await Self.stripIdle(h)
    #expect(h.media.thumbRequests.filter { $0.hasPrefix("poster ") }.count == 6, "\(h.media.thumbRequests)")
    #expect(h.model.stripPosters.count == 3)
  }

  /// Playback ticks move only the playhead: what the strip builds from the clips doesn't read it.
  @Test func playheadDoesNotRebuildTheStrip() async throws {
    let h = Harness()
    await h.importAll(["a.MOV", "b.MOV"])
    let fired = Mutex(false)
    withObservationTracking {
      _ = ReelStripView.content(h.model, width: 1000)
      _ = h.model.stripSpriteSources
    } onChange: { fired.withLock { $0 = true } }
    h.model.playhead = RationalTime(3, 1)
    #expect(!fired.withLock { $0 }, "the playhead rebuilt the strip's layout or labels")
    let id = try #require(h.model.reel?.clips.last?.id)
    h.model.select(id, extend: false, toggle: false)
    #expect(fired.withLock { $0 }, "the tracking is live: a selection change does rebuild")
  }

  @Test func voiceOverLabel() {
    let c = Self.clip(RationalTime(32, 10), name: "IMG_4821.MOV")
    #expect(StripCanvas.label(index: 3, count: 18, clip: c, missing: false) == "Clip 4 of 18, IMG_4821, 3.2 seconds")
    #expect(StripCanvas.label(index: 0, count: 1, clip: c, missing: true) == "Clip 1 of 1, IMG_4821, 3.2 seconds, missing")
  }

  // MARK: drawing

  /// Selected = gold outline, missing = `--bg-2`, past 3:00 = dimmed, the marker is `--warn`, the playhead ivory.
  @Test func canvasDrawsStates() throws {
    let clips = (0..<4).map { Self.clip(Self.s(60), name: "IMG_\($0).MOV") }
    let L = Self.layout(clips, width: 800)
    let state = StripState(primary: clips[0].id, selected: [clips[0].id], missing: [clips[1].id],
                           playhead: Self.s(30))
    let image = try Self.render(StripCanvas(layout: L, sprites: [:], state: state), width: 800, scale: 1)
    let px = try StageViewTests.pixels(image)
    func at(_ x: CGFloat, _ y: CGFloat) -> [UInt8] { StageViewTests.rgb(px, image, x: Int(x), y: Int(y)) }
    #expect(at(L.tiles[0].rect.minX + 0.5, Self.row) == [0xC9, 0xA8, 0x6A], "gold outline")
    #expect(at(L.tiles[1].rect.minX + 4, Tokens.Layout.stripCap + 4) == [0x1C, 0x1F, 0x25], "missing is bg-2")
    let lx = try #require(L.limitX)
    #expect(at(lx.rounded(), 2) == [0xF2, 0xC9, 0x4C], "3:00 line in the cap row")
    #expect(at(lx.rounded(), Self.row) == [0xF2, 0xC9, 0x4C], "and over the tiles")
    let dim = at(L.tiles[3].rect.midX, Tokens.Layout.stripCap + 4)
    #expect(dim.allSatisfy { $0 < 0x1C } && dim != [0, 0, 0], "past 3:00 is dimmed: \(dim)")
    #expect(at(L.x(for: Self.s(30)).rounded(), Self.row + 10) == [0xF2, 0xED, 0xE4], "ivory playhead")
  }

  /// §10: a 30-tile strip draws in under 2 ms (median of ImageRenderer renders, debug build).
  @Test func stripDrawUnder2ms() throws {
    var clips: [ReelClip] = []
    for i in 0..<30 {
      let len: RationalTime = i % 3 == 0 ? Self.s(5, 10) : Self.s(Int64(1 + i % 4))
      let join: Join = i % 7 == 3 ? .crossfade(Limits.shortFade) : .cut
      clips.append(Self.clip(len, join: join, name: "IMG_\(i).MOV"))
    }
    let sheet = try #require(Self.syntheticSprite())
    var sprites: [UUID: StripSprite] = [:]
    for c in clips { sprites[c.id] = sheet }
    let L = Self.layout(clips, width: 1200)
    let state = StripState(primary: clips[4].id, selected: [clips[4].id, clips[5].id], playhead: Self.s(7))
    // A fresh renderer per frame (one caches its image), the playhead moving as in playback or a drag.
    func frame(_ k: Int) -> Double {
      var st = state
      st.playhead = Self.s(Int64(k), 10)
      let renderer = ImageRenderer(content: StripCanvas(layout: L, sprites: sprites, state: st)
        .frame(width: 1200, height: Tokens.Layout.strip))
      renderer.scale = 2
      let t0 = DispatchTime.now().uptimeNanoseconds
      let image = renderer.cgImage
      let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
      if k == 0, let image, let px = try? StageViewTests.pixels(image) {
        let tile = L.tiles[1].rect  // the frames really are drawn: the synthetic sprite's green 0.5
        #expect(StageViewTests.rgb(px, image, x: Int(tile.midX * 2), y: Int(tile.midY * 2))[1] == 128)
      }
      #expect(image != nil)
      return ms
    }
    for k in 0..<5 { _ = frame(k) }
    let times = (0..<31).map { frame(5 + $0) }
    let median = times.sorted()[times.count / 2]
    print("stripDrawUnder2ms: median \(String(format: "%.3f", median)) ms over 31 renders")
    // §10's 2 ms under TRIMLAB_TIMING=1 (see `Timing`); looser in a parallel run, which loads the machine.
    let limit = Timing.strict ? 2.0 : 8.0
    #expect(median < limit, "median \(median) ms (limit \(limit))")
  }

  // MARK: shots

  /// Gives every clip the mockup's sprite for its place (an 8 × 5 grid of 40 cells), times `i × duration / 40`.
  static func withSprites(_ h: Harness) throws -> Harness {
    for (i, clip) in (h.model.reel?.clips ?? []).enumerated() {
      let url = SourceScan.repoRoot / String(format: "design/mockup-assets/sprite-%02d.jpg", i + 1)
      let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
      let grid = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
      let cw = grid.width / 8, ch = grid.height / 5
      let frames = try (0..<40).map { k in
        try #require(grid.cropping(to: CGRect(x: (k % 8) * cw, y: (k / 8) * ch, width: cw, height: ch)))
      }
      let d = clip.facts.duration
      let times = (0..<40).map { RationalTime(d.value * Int64($0), d.timescale * 40) }
      h.model.stripSprites[clip.source] = StripSprite(frames: frames, times: times)
    }
    return h
  }

  static func save(_ image: CGImage, _ url: URL) throws {
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
  }

  // MARK: rendering helpers

  static func render(_ view: some View, width: CGFloat, scale: CGFloat) throws -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: width, height: Tokens.Layout.strip).background(Tokens.bg1))
    renderer.scale = scale
    return try #require(renderer.cgImage)
  }

  /// A 40-frame stand-in sprite: 72 × 128 cells, shaded per frame.
  static func syntheticSprite() -> StripSprite? {
    let w = 72, h = 128
    var frames: [CGImage] = []
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    for i in 0..<40 {
      guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
      ctx.setFillColor(CGColor(srgbRed: CGFloat(i) / 40, green: 0.5, blue: 0.6, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      guard let im = ctx.makeImage() else { return nil }
      frames.append(im)
    }
    return StripSprite(frames: frames, times: (0..<40).map { RationalTime(Int64($0), 4) })
  }
}
