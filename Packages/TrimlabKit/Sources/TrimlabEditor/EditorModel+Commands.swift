import Foundation
import TrimlabModel

/// What the key monitor does with the event it was given.
public enum KeyOutcome: Hashable, Sendable {
  /// Not ours: the event goes on (to the menus, the focused control or the field).
  case pass
  /// Ours, handled or deliberately ignored: the event is swallowed.
  case swallow
  /// A text field has focus and wants this edit command: the monitor sends it to the field's responder.
  case sendToField(Command)
}

/// §4.7, §4.10. Every `Command` runs here, whether it came from a key (`handleKey`) or a menu item, so the two
/// can't differ. Pure Swift: the app target turns its key events into `KeyChord`s and calls in.
extension EditorModel {
  // MARK: context

  public var hasClips: Bool { reel?.clips.isEmpty == false }

  /// Menu items work only while no modal is on top (§4.10).
  public var menuEnabled: Bool { modals.top == nil }

  /// What `KeyMap.command(for:context:)` needs to know right now.
  public var keyContext: KeyContext {
    KeyContext(hasClip: hasClips, dragging: stripPressed != nil || activeDrag != nil || deckGrab != nil,
               inTextField: textFieldFocused, topModal: modals.top, passKeys: modals.passKeys)
  }

  // MARK: keys

  /// A key-down chord. Decides who owns it: the menus (⌘ chords), the field being typed in, the top modal, or the
  /// editor. `isRepeat` is the held-key flag; repeat runs only the commands `KeyMap.repeats` allows.
  public func handleKey(_ chord: KeyChord, isRepeat: Bool, inTextField: Bool, composing: Bool = false) -> KeyOutcome {
    handlingKey = true
    defer { handlingKey = false }
    textFieldFocused = inTextField
    if let outcome = handleRenameKey(chord, inTextField: inTextField, composing: composing) { return outcome }
    // What the table says with nothing in the way: tells a key we use but can't act on from one we don't use.
    let bound = KeyMap.command(for: chord, context: .editing)
    if chord.mods.contains(.command) {
      // ⌘ chords are the menus'. A field in focus gets its own undo, redo and select all.
      if inTextField, let bound, bound == .undo || bound == .redo || bound == .selectAll {
        return .sendToField(bound)
      }
      return .pass
    }
    // A focused segmented control (the caption's, or the export sheet's on top) moves its own selection with the
    // plain arrows.
    if chord.mods.isEmpty, chord.key == .left || chord.key == .right {
      if modals.top == nil, arrowsToControl { return .pass }
      if modals.top == .exportSheet, arrowControls.contains(where: { $0.hasPrefix(Self.sheetControlPrefix) }) {
        return .pass
      }
    }
    guard let cmd = KeyMap.command(for: chord, context: keyContext) else {
      if inTextField || bound == nil { return .pass }
      // Space presses the focused control inside a modal, as Return does (§4.10); with none focused it goes on.
      if modals.top != nil && chord.key == .space && chord.mods.isEmpty {
        guard modalFocusedControl != nil else { return .pass }
        if !isRepeat { activateFocusedControl() }
        return .swallow
      }
      return .swallow  // a key we use, with nothing to do now (no clip, a handle held, a modal): no beep
    }
    if modals.top == nil {
      switch cmd {
      case .focusNext, .activate: return .pass  // the system's focus and its default button
      case .escape where inTextField: return .pass  // the field's own Esc
      default: break
      }
    }
    // Return in a modal's text field is the field's own (its onSubmit), not the modal's focused control.
    if inTextField, cmd == .activate { return .pass }
    if isRepeat && !KeyMap.repeats(cmd) { return .swallow }
    // A fresh ⌥ press is a new gesture, whether or not the last key-up arrived.
    if !isRepeat, case .moveSelection = cmd { endGesture() }
    return command(cmd) ? .swallow : .pass
  }

  /// A key-up. Letting go of ← or → ends a held ⌥ move (only one that a ⌥ press started, so a plain ← tap during a
  /// mouse drag leaves that drag's gesture alone): the next press is a new undo step.
  public func handleKeyUp(_ chord: KeyChord) {
    guard session.moveKeyHeld, chord.key == .left || chord.key == .right else { return }
    endKeyGesture()
  }

  /// Ends a held ⌥ move: key-up, or the window or app losing key with the key still down.
  public func endKeyGesture() {
    guard session.moveKeyHeld else { return }
    session.moveKeyHeld = false
    endGesture()
  }

  // MARK: dispatch

  /// Runs `c`. Returns false when it had nothing to do and the key should go on (Esc with nothing to close, Tab or
  /// Return with no modal).
  @discardableResult
  public func command(_ c: Command) -> Bool {
    switch c {
    case .playPause: togglePlay()
    case .step(let n): step(n)
    case .jump(let s): jump(s)
    case .selectPrev: selectNeighbour(-1)
    case .selectNext: selectNeighbour(1)
    case .moveSelection(let d): moveSelection(d)
    case .shuttle(let d): shuttle(d)
    case .toIn: seekToPrimary(end: false)
    case .toLastKept: seekToPrimary(end: true)
    case .toReelStart: seek(reelTime: .zero)
    case .toReelEnd: if let plan { seek(reelTime: plan.total) }
    case .setIn: trimAtDeckPlayhead { .setIn($0, $1) }
    case .setOut: trimAtDeckPlayhead { .setOut($0, $1) }
    case .resetIn: if let id = selection.primary { perform(.resetIn(id), coalesce: nil) }
    case .resetOut: if let id = selection.primary { perform(.resetOut(id), coalesce: nil) }
    case .split: splitAtDeckPlayhead()
    case .toggleJoin: if let id = selection.primary { clickJoin(id) }
    case .toggleFraming: toggleFraming()
    case .deleteSelection: if !selection.all.isEmpty { perform(.delete(selection.all), coalesce: nil) }
    case .selectAll: selectAll()
    case .toggleRemoveAudio: toggleRemoveAudio()
    case .toggleLoop: toggleLoop()
    case .newReel: newReel()
    case .open: openFiles()
    case .export: requestExport()
    case .undo: undo()
    case .redo: redo()
    case .deckZoom(let d): deckZoomStep(d)
    case .stripZoom(let d): stripZoomStep(d)
    case .stripZoomFit: stripZoomFit()
    case .keyMap: showKeyMap()
    case .escape: return escape()
    case .focusNext(let backwards): return focusNext(backwards: backwards)
    case .activate: return activate()
    }
    return true
  }

  /// Esc: the top modal closes (focus returns to what opened it); else a strip press or drag is cancelled; else a
  /// multi-selection collapses to its primary.
  private func escape() -> Bool {
    if let top = modals.top {
      switch top {
      case .exportSheet: closeExportSheet()  // a running export's sheet stays: only Cancel stops it
      case .ffmpegCard: closeFFmpegCard()
      case .keyMap: closeKeyMap()
      }
      return true
    }
    if stripCancel() || deckCancel() { return true }
    guard selection.all.count > 1 else { return false }
    collapseSelection()
    return true
  }

  /// Tab / ⇧Tab cycle only inside the top modal (§4.10); with none, the system moves focus.
  private func focusNext(backwards: Bool) -> Bool {
    guard modals.top != nil else { return false }
    focusedControl = modals.next(after: focusedControl, backwards: backwards)
    return true
  }

  private func activate() -> Bool {
    guard modals.top != nil else { return false }
    activateFocusedControl()
    return true
  }

  // MARK: selection and seeking

  /// ↑ / ↓: the previous or next clip, selected with the playhead at its In. Nothing past either end.
  private func selectNeighbour(_ d: Int) {
    guard let reel, !reel.clips.isEmpty else { return }
    let current = selection.primary.flatMap(reel.index(of:))
    let target = current.map { $0 + d } ?? 0
    guard reel.clips.indices.contains(target) else { return }
    selectAndSeek(reel.clips[target].id, extend: false, toggle: false)
  }

  /// Home / End: the primary clip's In, or its last kept frame (Out is exclusive, so one frame short of it).
  private func seekToPrimary(end: Bool) {
    guard let plan, let id = selection.primary,
          let span = plan.placements.first(where: { $0.clipID == id })?.reelSpan
    else { return }
    seek(reelTime: end ? span.end - plan.frameDuration : span.start)
  }

  // MARK: edits

  /// The clip I, O and S act on and its source time at the deck playhead: in peek the peeked frame, otherwise the
  /// Reel playhead mapped into the primary clip.
  private func deckPlayhead() -> (clip: ReelClip, source: RationalTime)? {
    guard let reel else { return nil }
    if let peek, let clip = reel.clips.first(where: { $0.id == peek.clipID }) { return (clip, peek.sourceTime) }
    guard let plan, let id = selection.primary, let clip = reel.clips.first(where: { $0.id == id }),
          let placement = plan.placements.first(where: { $0.clipID == id })
    else { return nil }
    let t = placement.sourceIn + (playhead - placement.reelSpan.start)
    return (clip, min(max(t, clip.inTime), clip.outTime))
  }

  private func trimAtDeckPlayhead(_ edit: (UUID, RationalTime) -> ReelEdit) {
    guard let (clip, source) = deckPlayhead() else { return }
    perform(edit(clip.id, source), coalesce: nil)
  }

  /// S: A = [In, t), B = [t, Out) and B becomes the selection (§4.3.4).
  private func splitAtDeckPlayhead() {
    guard let (clip, source) = deckPlayhead(), perform(.split(clip.id, atSource: source), coalesce: nil),
          let i = reel?.index(of: clip.id), let second = reel?.clips[safe: i + 1]
    else { return }
    selectAndSeek(second.id, extend: false, toggle: false)  // B's In is the split point: the playhead stays
  }

  /// ⌥← / ⌥→: the selected clips one place earlier or later. A held key is one gesture ("move.key"), ended on key up.
  private func moveSelection(_ d: Int) {
    guard let reel else { return }
    let at = reel.clips.indices.filter { selection.all.contains(reel.clips[$0].id) }
    guard let first = at.first, let last = at.last else { return }
    let gap = d < 0 ? first - 1 : last + 2
    guard gap >= 0, gap <= reel.clips.count else { return }
    let edit = ReelEdit.move(selection.all, toGap: gap)
    guard let next = try? apply(edit, to: reel), next.clips.map(\.id) != reel.clips.map(\.id) else { return }
    session.moveKeyHeld = true
    perform(edit, coalesce: "move.key")
  }

  /// F: the selection takes the opposite of the primary's framing. Nothing for a 9:16 primary or an Original export,
  /// where Fill and Fit look the same (§4.3.4).
  private func toggleFraming() {
    guard let reel, reel.export.format == .reel, let id = selection.primary,
          let clip = reel.clips.first(where: { $0.id == id }),
          clip.facts.displayWidth * 16 != clip.facts.displayHeight * 9
    else { return }
    perform(.setFraming(selection.all, clip.framing == .fill ? .fit : .fill), coalesce: nil)
  }

  // MARK: files, export, help

  /// ⌘O: the Open panel, then the same import as a drop (movies append; a `.trimlab` opens).
  @discardableResult
  public func openFiles() -> Task<Void, Never> {
    guard !refuseDuringExport() else { return Task {} }
    return Task {
      let urls = await platform.openPanel(movies: true, projects: true)
      guard !urls.isEmpty else { return }
      await importURLs(urls, at: nil).value
    }
  }

  /// ⌘E. Nothing to export without clips. A missing clip blocks it (§4.9), and so do clips still loading; otherwise
  /// the export sheet opens (`openExportSheet`). While a committed rename's file move is in flight, the sheet opens
  /// once it lands, so it shows the name the move ends with and the rename is recorded before anything is frozen.
  /// One wait at a time (a second ⌘E meanwhile adds nothing); it stands down if a modal opened or the Reel changed
  /// meanwhile, and New Reel or open cancels it.
  public func requestExport() {
    commitOpenRename()
    guard let reel, !reel.clips.isEmpty else { return }
    if let renaming = pendingRename {
      guard pendingExportRequest == nil else { return }
      let id = reel.id
      pendingExportRequest = Task {
        _ = await renaming.value
        guard !Task.isCancelled else { return }
        self.pendingExportRequest = nil
        guard self.modals.top == nil, self.reel?.id == id else { return }
        self.requestExport()
      }
      return
    }
    let gone = reel.clips.filter { missing.contains($0.id) }
    if let first = gone.first {
      note(ExportForm.missingLine(first: Self.fileName(first), others: gone.count - 1))
      return
    }
    guard loadingClipIDs.isEmpty else {
      note("Wait for the clips to finish loading.")
      return
    }
    openExportSheet()
  }

  // MARK: focus

  /// The header's `?`: the key map gives focus back to it.
  static let helpControl = "help"
  /// The key map's one control.
  static let keyMapClose = "keymap-close"

  /// A control that got keyboard focus some other way than Tab inside a modal (the system's Tab, a click into a field)
  /// says so, so the next Tab goes on from it.
  public func setFocusedControl(_ id: String?) {
    if focusedControl != id { focusedControl = id }
    focusRing = true  // reported by a control that has keyboard focus (or nil: nothing to draw)
  }

  /// The focused control, if it's one of the top modal's.
  var modalFocusedControl: String? {
    guard let top = modals.top, let id = focusedControl, modals.tabOrder(for: top).contains(id) else { return nil }
    return id
  }

  /// Space or Return inside a modal presses its focused control.
  public func activateFocusedControl() {
    guard let top = modals.top, let id = modalFocusedControl else { return }
    switch top {
    case .exportSheet: activateSheetControl(id)
    case .keyMap: if id == Self.keyMapClose { closeKeyMap() }
    case .ffmpegCard: activateFFmpegCardControl(id)
    }
  }

  // MARK: key map

  public var keyMapOpen: Bool { modals.contains(.keyMap) }

  /// `?` and the header's `?`: opens the key map over everything with its Close focused (v1), or closes it; `?`
  /// passes through it (`passKeys`), so it closes it again.
  public func showKeyMap() {
    commitOpenRename()
    if modals.top == .keyMap {
      closeKeyMap()
      return
    }
    // Not over the export sheet (or the card): the header's `?` stays clickable above the sheet's scrim.
    guard modals.top == nil else { return }
    modals.open(.keyMap, passKeys: [.keyMap], opener: Self.helpControl)
    modals.register([Self.keyMapClose], for: .keyMap)
    focusedControl = Self.keyMapClose
  }

  /// Close, Esc, `?` or a click outside the panel: focus goes back to the header's `?`.
  public func closeKeyMap() {
    guard keyMapOpen else { return }
    focusedControl = modals.close(.keyMap)
  }
}

extension Array {
  fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

