import Foundation
import TrimlabMedia
import TrimlabModel

/// §6.1. The header's Reel name, renamed inline: one undo step (§4.8) that renames the `.trimlab` file beside it
/// (§8.2). The file is renamed through the write chain, off the main actor, and never over anything; undo and redo
/// move it back and forth by the same rules.
extension EditorModel {
  /// The header's name control: its focus id and accessibility identifier.
  public static let reelNameControl = "reel.name"
  /// The rename field's focus id: `beginRenameReel` gives it focus through the focus link (`TLFocusSync`), so it
  /// doesn't depend on SwiftUI focusing a view as it appears.
  public static let reelNameField = "reel.name.field"

  static func takenNote(_ name: String) -> String { "A Reel named “\(name)” is already in this folder." }

  /// A failed move is never a missing folder (that's `.gone`): it's one trimlab can't change (read-only, locked).
  static let renameFailedNote = "The Reel's file couldn't be renamed. Its folder may be read-only."

  /// How renaming the Reel's file went.
  enum FileRename: Equatable, Sendable {
    /// The Reel has no file yet: only the name changes, and the first save is named after it.
    case noFile
    /// The file is now at this URL (the same one when only the name in it changed).
    case moved(URL)
    /// Nothing was at the old name (moved or deleted outside trimlab): the next save writes this URL.
    case gone(URL)
    /// A file, folder or link already has the new name.
    case taken
    case failed(String)
  }

  /// Where the Reel's file is once a rename has landed, and the name it was moved for (nil if it didn't move).
  struct RenamedFile: Sendable {
    let url: URL?
    let movedFor: String?
  }

  /// Whether the header's name can be edited now: a Reel of two or more clips (a one-clip Reel shows its file name),
  /// with no export running and no modal open (edits record nothing then, §4.8).
  public var canRenameReel: Bool {
    guard let reel, reel.clips.count >= 2 else { return false }
    return !exportRunning && modals.top == nil
  }

  /// A click on the name, or Return or Space while it has keyboard focus: the name becomes a field holding it, and
  /// the field takes focus.
  public func beginRenameReel() {
    guard canRenameReel, let reel else { return }
    reelNameDraft = reel.name
    editingReelName = true
    focusedControl = Self.reelNameField
  }

  /// Each edit in the field, as it's typed.
  public func setReelNameDraft(_ text: String) {
    guard editingReelName else { return }
    reelNameDraft = text
  }

  /// Return in the field (the key monitor's, or the field's own `onSubmit`), focus leaving it, or a press on the
  /// strip, deck or stage: the draft is committed (`renameReel`). Once only: a second call, or one after Esc, does
  /// nothing. Focus goes back to the name with its ring after the keyboard's commit; after the pointer's, nothing
  /// keeps focus (as `pointerPressed`), so no ring shows.
  @discardableResult
  public func commitRenameReel(keyboard: Bool) -> Task<Void, Never> {
    guard editingReelName else { return Task {} }
    let renaming = renameReel(reelNameDraft)
    handBackFocus(keyboard: keyboard)
    return renaming
  }

  /// Esc in the field: the name stays as it was, and focus goes back to it (with its ring when it was the keyboard).
  public func cancelRenameReel(keyboard: Bool = true) {
    guard editingReelName else { return }
    editingReelName = false
    handBackFocus(keyboard: keyboard)
  }

  private func handBackFocus(keyboard: Bool) {
    if keyboard {
      setFocusedControl(Self.reelNameControl)
    } else if focusedControl == Self.reelNameField {
      focusedControl = nil  // focus that went to another control stays there
    }
  }

  /// Return and Esc while the rename field has focus are the rename's, whatever SwiftUI's field does with them
  /// (`handleKey` asks first). Not while an input method is composing (`composing`: marked text in the field):
  /// then they confirm or cancel the composition, and go on to the field.
  func handleRenameKey(_ chord: KeyChord, inTextField: Bool, composing: Bool) -> KeyOutcome? {
    guard editingReelName, inTextField, !composing, modals.top == nil, chord.mods.isEmpty else { return nil }
    switch chord.key {
    case .returnKey: commitRenameReel(keyboard: true)
    case .escape: cancelRenameReel(keyboard: true)
    default: return nil
    }
    return .swallow
  }

  /// ⌘E, `?`, New Reel, open, quit and window close: a name still being typed is committed first (as clicking away
  /// would), so it isn't dropped or left in a field the next screen hides.
  public func commitOpenRename() {
    if editingReelName { commitRenameReel(keyboard: false) }
  }

  /// `modals` or `reel` changed: a field that can no longer be committed (a modal came up some other way, the Reel
  /// dropped to one clip or closed) ends, the name as it was; a rename that landed under a modal takes effect once
  /// the last modal closes.
  func renameStateChanged() {
    if editingReelName, !canRenameReel {
      editingReelName = false
      if focusedControl == Self.reelNameField { focusedControl = nil }
    }
    if modals.top == nil, !heldRenameLands.isEmpty {
      let lands = heldRenameLands
      heldRenameLands = []
      for land in lands { land() }
    }
  }

  /// The name `typed` gives the Reel: trimmed, a typed ".trimlab" (any case) dropped as the file's own extension,
  /// and made safe as the export file name is (`Naming.sanitized`, no "/" or ":", a typed video extension dropped,
  /// 220 bytes at most); nil when nothing is left.
  static func reelName(from typed: String) -> String? {
    var trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = ".trimlab"
    if trimmed.lowercased().hasSuffix(ext) {
      trimmed = String(trimmed.dropLast(ext.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return Naming.safeStem(trimmed)  // nil for nothing, or nothing left once made safe ("...", "///")
  }

  /// Return in the field, or focus leaving it: the Reel takes the name. An empty name, or the same one, does
  /// nothing. With a file, `<name>.trimlab` beside it must be free: the file is renamed first, and only then does the
  /// name change (one undo step); a name that's taken leaves everything as it was, with a quiet note. The returned
  /// task ends once that has landed.
  @discardableResult
  public func renameReel(_ typed: String) -> Task<Void, Never> {
    editingReelName = false
    guard canRenameReel, let reel, let name = Self.reelName(from: typed), name != reel.name else { return Task {} }
    guard projectURL != nil || pendingRename != nil else {
      applyRename(name)
      return Task {}
    }
    let renaming = renameProjectFile(to: name) { outcome in self.landRename(name, outcome) }
    return Task { _ = await renaming.value }
  }

  /// Undo or redo brought back another name: the file follows by the same rules. A name taken meanwhile leaves the
  /// file where it is (the Reel keeps the name undo gave it), and the log says so.
  func followRenamed(_ name: String) {
    guard projectURL != nil || pendingRename != nil else { return }
    renameProjectFile(to: name) { outcome in
      switch outcome {
      case .noFile, .moved: break
      case .gone(let url):
        MediaLog.note("project: rename to \(url.lastPathComponent) found no file to move; the next save writes it")
      case .taken:
        MediaLog.note("project: kept \(self.projectURL?.path ?? "?"): \(name).trimlab is taken, so undo/redo left it")
      case .failed(let detail): MediaLog.note("project: undo/redo rename failed: \(detail)")
      }
    }
  }

  /// The name, as one undo step. No export can be running: none runs when a rename is committed
  /// (`canRenameReel`), and ⌘E waits for a move in flight (`requestExport`). Nor is a modal open: a move that lands
  /// under one (the key map) is held until it closes (`landRename`).
  private func applyRename(_ name: String) {
    session.renamed = true
    try? applyEdit(.rename(name), coalesce: nil, record: true)
  }

  /// A committed rename's move has landed (the file side, `projectURL` and Open Recent, is done already). The name
  /// change, or the note, waits while a modal is open: nothing is recorded under one (§4.8).
  private func landRename(_ name: String, _ outcome: FileRename) {
    guard modals.top == nil else {
      heldRenameLands.append { [weak self] in self?.landRename(name, outcome) }
      return
    }
    switch outcome {
    case .noFile, .moved:
      applyRename(name)
    case .gone(let url):
      MediaLog.note("project: rename to \(url.lastPathComponent) found no file to move; the next save writes it")
      applyRename(name)
    case .taken:
      note(Self.takenNote(name))
    case .failed(let detail):
      MediaLog.note("project: rename failed: \(detail)")
      note(Self.renameFailedNote, .error)
    }
  }

  /// The file side of a move that landed, whether or not its Reel is still open: the open Reel's `projectURL`
  /// follows the file, and Open Recent swaps the old path for the new one (a file the next save will write, for
  /// `.gone`).
  private func followFile(from: URL?, _ outcome: FileRename, open: Bool) {
    let url: URL
    switch outcome {
    case .moved(let to), .gone(let to): url = to
    case .noFile, .taken, .failed: return
    }
    if open { projectURL = url }
    guard from != url else { return }
    if let from { platform.forgetRecent(from) }
    platform.noteRecent(url)
  }

  /// Queues the rename of the Reel's file to `<name>.trimlab` in its folder, after every rename and write queued
  /// before it. Which file is decided when the move runs (`moveProjectFile`), so a rename committed just before New
  /// Reel or open still happens. `land` runs on the main actor once it's done, if the Reel is still open, and before
  /// any save that waited for it (`saveNow`). The task ends with where the file is then.
  @discardableResult
  private func renameProjectFile(to name: String, land: @escaping @MainActor (FileRename) -> Void)
    -> Task<RenamedFile, Never> {
    let previous = pendingRename
    renameGeneration += 1
    let generation = renameGeneration
    let reelID = reel?.id
    let current = projectURL
    let task = Task { () -> RenamedFile in
      var file = current
      if let previous { file = await previous.value.url ?? (self.reel?.id == reelID ? self.projectURL : nil) }
      let (from, outcome) = await self.moveProjectFile(file, reelID: reelID, to: name)
      let open = self.reel?.id == reelID
      self.followFile(from: from, outcome, open: open)
      if open { land(outcome) }
      if self.renameGeneration == generation { self.pendingRename = nil }
      switch outcome {
      case .moved(let url): return RenamedFile(url: url, movedFor: name)
      case .gone(let url): return RenamedFile(url: url, movedFor: name)
      case .taken, .failed: return RenamedFile(url: from, movedFor: nil)
      case .noFile: return RenamedFile(url: nil, movedFor: nil)
      }
    }
    pendingRename = task
    return task
  }

  /// The move itself, as a link in the write chain: it starts once every write queued before it has landed, and
  /// a write queued after it waits for it. Saves asked for meanwhile wait for `pendingRename` instead (`saveNow`),
  /// so none goes to the old name. Which file it moves is decided only then: the open Reel's `projectURL` as it is
  /// by now (a refused save may have sent it elsewhere), or `file` for a Reel closed meanwhile; and the store moves
  /// it only if it holds this Reel (`reelID`).
  private func moveProjectFile(_ file: URL?, reelID: UUID?, to name: String) async -> (from: URL?, FileRename) {
    guard let reelID else { return (nil, .noFile) }
    let previous = writeChain
    let store = self.store
    let move = Task { () -> (URL?, FileRename) in
      _ = await previous?.value
      guard let from = self.reel?.id == reelID ? (self.projectURL ?? file) : file else { return (nil, .noFile) }
      let to = from.deletingLastPathComponent().appending(path: "\(name).trimlab", directoryHint: .notDirectory)
      // A file a save was refused at is someone else's (`neverAutosave`), even if it has gone since.
      let refused = self.neverAutosave.contains { $0.path.lowercased() == to.path.lowercased() }
      if refused, from.path.lowercased() != to.path.lowercased() { return (from, .taken) }
      if self.neverAutosave.contains(from) { return (from, .gone(to)) }  // not this Reel's file any more
      return (from, await Self.move(from, to: to, reelID: reelID, store: store))
    }
    writeChain = Task { _ = await move.value; return nil }
    return await move.value
  }

  /// Off the main actor: the rename on the disk (`ProjectStore.move`). A file that isn't this Reel's is left alone,
  /// as if this Reel's had gone: the next save writes the new name.
  @concurrent
  nonisolated static func move(_ from: URL, to: URL, reelID: UUID, store: any ProjectStore) async -> FileRename {
    do throws(ProjectMoveError) {
      try store.move(from, to: to, reelID: reelID)
      return .moved(to)
    } catch {
      switch error {
      case .taken: return .taken
      case .noFile, .anotherReel: return .gone(to)
      case .failed(let detail): return .failed(detail)
      }
    }
  }
}
