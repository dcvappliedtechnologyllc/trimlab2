import Foundation
import ImageIO
import SwiftUI
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 37: the narrow layout, reduced motion, the Tab trap and focus return, the key map overlay and the ffmpeg card
/// (§4.1, §4.7, §4.10, §4.11, §6.0).
@MainActor @Suite struct PolishTests {
  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  private func key(_ k: Key, _ m: Mods = []) -> KeyChord { KeyChord(key: k, mods: m) }
  private func press(_ h: Harness, _ chord: KeyChord, inTextField: Bool = false) -> KeyOutcome {
    h.model.handleKey(chord, isRepeat: false, inTextField: inTextField)
  }

  // MARK: the brief's six

  @Test func narrowBelow1000() {
    #expect(RootLayout.mode(width: 999) == .narrow)
    #expect(RootLayout.mode(width: 900) == .narrow)
    #expect(RootLayout.mode(width: 1000) == .wide)
    #expect(RootLayout.mode(width: 1240) == .wide)
  }

  @Test func tabTrapInsideSheet() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.requestExport()
    #expect(h.model.modals.top == .exportSheet)
    let order = h.model.sheetControlIDs
    #expect(order.count > 3)
    var seen: [String] = []
    for _ in 0..<12 {
      #expect(press(h, key(.tab)) == .swallow)
      let id = try #require(h.model.focusedControl)
      #expect(id.hasPrefix(EditorModel.sheetControlPrefix), "Tab left the sheet for \(id)")
      #expect(!id.hasPrefix("caption."))
      seen.append(id)
    }
    #expect(Set(seen) == Set(order), "Tab reaches every sheet control and nothing else")
    #expect(Array(seen.prefix(order.count)) == order)
    for _ in 0..<12 {
      #expect(press(h, key(.tab, .shift)) == .swallow)
      #expect(order.contains(h.model.focusedControl ?? ""))
    }
    #expect(h.model.playhead == .zero, "the editor never saw a key")
  }

  @Test func focusReturnsToOpener() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    // `?` opens the key map with its Close focused (v1); `?` again closes it, focus back on the header's `?`.
    #expect(press(h, KeyChord.normalised(characters: "?", mods: [.shift])) == .swallow)
    #expect(h.model.modals.top == .keyMap)
    #expect(h.model.focusedControl == EditorModel.keyMapClose)
    #expect(press(h, KeyChord.normalised(characters: "?", mods: [.shift])) == .swallow)
    #expect(h.model.modals.top == nil)
    #expect(h.model.focusedControl == EditorModel.helpControl)
    // Esc too.
    h.model.command(.keyMap)
    #expect(press(h, key(.escape)) == .swallow)
    #expect(h.model.focusedControl == EditorModel.helpControl)
    // The export sheet gives focus back to Export….
    h.model.requestExport()
    _ = press(h, key(.tab))
    #expect(press(h, key(.escape)) == .swallow)
    #expect(h.model.modals.top == nil)
    #expect(h.model.focusedControl == EditorModel.sheetOpener)
  }

  @Test func keyMapListsEveryRow() {
    let lines = KeyMapOverlay.lines
    // Every chord of the one table, in its order, each on exactly one line.
    #expect(lines.flatMap(\.chords) == KeyMap.rows.map(\.0))
    // §4.7's 20 rows, then Tab / ⇧Tab and Return (§4.10).
    #expect(lines.count == 22)
    #expect(lines.allSatisfy { !$0.text.isEmpty && !$0.caps.isEmpty })
    #expect(lines.first?.caps == ["Space"])
    #expect(lines.first?.text == "Play / pause the Reel")
    let home = lines.first { $0.caps.first == "Home" }
    #expect(home?.caps == ["Home", "End", "⇧Home", "⇧End"])
    #expect(lines.contains { $0.caps == ["⌘Z", "⇧⌘Z"] })
    #expect(lines.contains { $0.caps == ["⌥⌘=", "⌥⌘−", "⌥⌘0"] })
    #expect(lines.contains { $0.caps == ["⌫", "⌦"] })
    // Two columns, the first no shorter than the second.
    let (left, right) = KeyMapOverlay.columns
    #expect(left.count + right.count == lines.count)
    #expect(left.count >= right.count && left.count - right.count <= 1)
  }

  @Test func ffmpegRecheckClosesCard() async throws {
    let h = Harness()
    h.media.state.withLock { $0.ffmpeg = false }
    await h.importAll(["a.mov", "show.mkv"])
    #expect(h.model.modals.top == .ffmpegCard)
    #expect(h.names == ["a.mov"])
    // Still no ffmpeg: the card stays.
    await h.model.recheckFFmpeg()?.value
    #expect(h.model.modals.top == .ffmpegCard)
    // Installed: the card closes and the refused file comes in.
    h.media.state.withLock { $0.ffmpeg = true }
    let resumed = try #require(h.model.recheckFFmpeg())
    #expect(h.model.modals.top == nil)
    await resumed.value
    #expect(h.names == ["a.mov", "show.mkv"])
    #expect(h.model.recheckFFmpeg() == nil, "nothing to recheck with the card closed")
  }

  @Test func reducedMotionDisablesTransitions() {
    #expect(Tokens.Motion.sheetSlide(reduce: true) == nil)
    #expect(Tokens.Motion.sheetSlide(reduce: true, opening: false) == nil)
    #expect(Tokens.Motion.sheetSlide(reduce: false) != nil)
    #expect(Tokens.Motion.sheetSlide(reduce: false) != Tokens.Motion.sheetSlide(reduce: false, opening: false))
    #expect(Tokens.Motion.knob(reduce: true) == nil)
    #expect(Tokens.Motion.knob(reduce: false) != nil)
    #expect(Tokens.Motion.hover(reduce: true) == nil)
    #expect(Tokens.Motion.saved(reduce: true) == nil)
  }

  // MARK: carries

  /// Space and Return press the focused control of the top modal (§4.10); Space in a field still types.
  @Test func spaceAndReturnPressFocusedControl() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.command(.keyMap)
    #expect(press(h, key(.space)) == .swallow)
    #expect(h.model.modals.top == nil, "Space pressed the key map's Close")
    h.model.command(.keyMap)
    #expect(press(h, key(.returnKey)) == .swallow)
    #expect(h.model.modals.top == nil, "Return pressed the key map's Close")

    h.model.requestExport()
    while h.model.focusedControl != "export-cancel" { _ = press(h, key(.tab)) }
    #expect(press(h, key(.space)) == .swallow)
    #expect(h.model.modals.top == nil, "Space pressed Cancel")
    #expect(h.model.focusedControl == EditorModel.sheetOpener)

    h.model.requestExport()
    #expect(press(h, key(.space), inTextField: true) == .pass, "Space types in the file name")
    #expect(h.model.modals.top == .exportSheet)
    #expect(press(h, key(.space)) == .pass, "with nothing focused Space goes on")
  }

  /// A press on the strip, deck or stage lets go of the focus a closed modal handed back, so the `?` doesn't keep
  /// its ring (or grab focus when it shows again); with a modal up the press changes nothing.
  @Test func pressReleasesHandedBackFocus() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.command(.keyMap)
    h.model.pointerPressed()
    #expect(h.model.focusedControl == EditorModel.keyMapClose)
    h.model.closeKeyMap()
    #expect(h.model.focusedControl == EditorModel.helpControl)
    h.model.pointerPressed()
    #expect(h.model.focusedControl == nil)
  }

  // MARK: review fixes

  /// New Reel (or opening one) forgets focus a closed modal handed back, so a reappearing `?` doesn't grab it.
  @Test func resetClearsHandedBackFocus() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.command(.keyMap)
    h.model.closeKeyMap()
    #expect(h.model.focusedControl == EditorModel.helpControl)
    h.model.newReel()
    #expect(h.model.focusedControl == nil)
  }

  /// Focus the model gives a control counts as keyboard focus even if a click had just focused it (ring, arrows);
  /// unless the model says no ring (a mouse close).
  @Test func linkedFocusDecidesItsRing() {
    let now = Date()
    let long = now.addingTimeInterval(-5)
    #expect(TLPointerFocus.keyboard(focused: true, linked: true, ring: true, focusedAt: now, pressedAt: now))
    #expect(!TLPointerFocus.keyboard(focused: true, linked: true, ring: false, focusedAt: now, pressedAt: long))
    #expect(!TLPointerFocus.keyboard(focused: true, linked: false, ring: true, focusedAt: now, pressedAt: now))
    #expect(TLPointerFocus.keyboard(focused: true, linked: false, ring: true, focusedAt: now, pressedAt: long))
    #expect(!TLPointerFocus.keyboard(focused: false, linked: true, ring: true, focusedAt: now, pressedAt: long))
  }

  /// The header's `?` (above the sheet's scrim) doesn't open the key map over the sheet or the card.
  @Test func keyMapWontOpenOverOtherModals() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.requestExport()
    h.model.command(.keyMap)
    #expect(h.model.modals.top == .exportSheet)
    #expect(!h.model.keyMapOpen)
    h.model.closeExportSheet()
    h.media.state.withLock { $0.ffmpeg = false }
    await h.importAll(["show.mkv"])
    #expect(h.model.modals.top == .ffmpegCard)
    h.model.command(.keyMap)
    #expect(!h.model.keyMapOpen)
  }

  /// Coordinator ruling: a modal closed with the mouse gives focus back to its opener without a ring; closed from
  /// the keyboard (Esc, Return) with one.
  @Test func pointerCloseHandsBackWithoutRing() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.requestExport()
    h.model.closeExportSheet()  // the Cancel button's click
    #expect(h.model.focusedControl == EditorModel.sheetOpener)
    #expect(!h.model.focusRing)
    h.model.requestExport()
    #expect(press(h, key(.escape)) == .swallow)
    #expect(h.model.focusedControl == EditorModel.sheetOpener)
    #expect(h.model.focusRing)
    h.model.command(.keyMap)  // the `?` click
    h.model.closeKeyMap()  // Close clicked
    #expect(h.model.focusedControl == EditorModel.helpControl)
    #expect(!h.model.focusRing)
    h.model.command(.keyMap)
    #expect(press(h, key(.returnKey)) == .swallow)  // Return on the focused Close
    #expect(h.model.focusedControl == EditorModel.helpControl)
    #expect(h.model.focusRing)
    #expect(KeyMapOverlay.lines.contains { $0.caps == ["Tab", "⇧Tab"] && $0.text == "Next / previous control" })
  }

  /// The HDR switch is a Tab stop, so Space and Return must flip it.
  @Test func activatingHDRSwitchFlipsIt() async throws {
    let h = Harness()
    var f = StubMedia.facts(RationalTime(10, 1), fps: RationalTime(1, 30))
    f.hdr = .hlg
    h.media.script("a.mov", .facts(f))
    await h.importAll(["a.mov", "b.mov"])
    h.model.requestExport()
    let before = try #require(h.model.exportForm?.spec.convertHDR)
    #expect(h.model.sheetControlIDs.contains("export-hdr"))
    h.model.focusedControl = "export-hdr"
    #expect(press(h, key(.returnKey)) == .swallow)
    #expect(h.model.exportForm?.spec.convertHDR == !before)
  }

  /// Task 36 carry: a sheet reopened while the last export is still tidying up says why Export is off.
  @Test func finishingLineWhileTidying() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.requestExport()
    #expect(h.model.exportBlockLine == nil)
    h.model.liveExport = UUID()
    #expect(!h.model.canExport)
    #expect(h.model.exportBlockLine == ExportForm.finishingLine)
    #expect(ExportForm.finishingLine == "Finishing the last export…")
    h.model.liveExport = nil
    #expect(h.model.exportBlockLine == nil)
  }

  /// Closing the card (Esc) drops the refused files: a later recheck brings nothing in.
  @Test func closingCardDropsPending() async throws {
    let h = Harness()
    h.media.state.withLock { $0.ffmpeg = false }
    await h.importAll(["show.mkv"])
    #expect(h.model.modals.top == .ffmpegCard)
    #expect(press(h, key(.escape)) == .swallow)
    #expect(h.model.modals.top == nil)
    h.media.state.withLock { $0.ffmpeg = true }
    #expect(h.model.recheckFFmpeg() == nil)
    #expect(h.names.isEmpty)
  }

  /// The card's Copy puts the command on the pasteboard; its controls are the Tab order.
  @Test func ffmpegCardCopies() async throws {
    let h = Harness()
    h.media.state.withLock { $0.ffmpeg = false }
    await h.importAll(["show.avi"])
    #expect(h.model.modals.tabOrder(for: .ffmpegCard) == [EditorModel.ffmpegCopy, EditorModel.ffmpegClose])
    _ = press(h, key(.tab))
    #expect(h.model.focusedControl == EditorModel.ffmpegCopy)
    #expect(press(h, key(.returnKey)) == .swallow)
    #expect(h.platform.state.withLock { $0.copied } == ["brew install ffmpeg-full"])
    #expect(FFmpegCard.command == "brew install ffmpeg-full")
    #expect(FFmpegCard.sentence
            == "trimlab needs ffmpeg to open .mkv and .avi files. Install it with Homebrew:")
    #expect(h.model.modals.top == .ffmpegCard, "Copy leaves the card open")
  }

  /// The overlays and the narrow row draw (ImageRenderer can't show focus, only that nothing traps).
  @Test func polishViewsRender() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    for (name, view, width) in [
      ("keymap", AnyView(KeyMapOverlay(model: h.model)), 1000.0),
      ("ffmpeg", AnyView(FFmpegCard(model: h.model)), 600.0),
      ("narrow", AnyView(InspectorView(model: h.model, narrow: true)), 960.0),
    ] {
      let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
        .background(Tokens.bg0))
      renderer.scale = 1
      let image = try #require(renderer.cgImage, "\(name) didn't render")
      #expect(image.width == Int(width), "\(name)")
      if name == "narrow" { #expect(image.height == 64) }
      if let dir = ProcessInfo.processInfo.environment["TRIMLAB_PANE_PNG_DIR"],
         let out = CGImageDestinationCreateWithURL(URL(filePath: "\(dir)/\(name).png") as CFURL, "public.png" as CFString,
                                                  1, nil) {
        CGImageDestinationAddImage(out, image, nil)
        CGImageDestinationFinalize(out)
      }
    }
  }
}
