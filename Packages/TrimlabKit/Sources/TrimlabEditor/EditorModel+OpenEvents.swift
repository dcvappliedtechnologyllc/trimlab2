import Foundation

extension EditorModel {
  static let closePanelNote = "Close this panel first."

  /// Open events from Finder, the Dock, Open Recent and `-TLOpen` (Task 39). The last `.trimlab` opens, then the
  /// movies are appended to it (a Reel with clips already in it is replaced only by a project, never by movies).
  ///
  /// Policy while a modal is up or an export runs: refused, exactly as a drop is (`refuseImport`, §4.10), not
  /// held back. One rule for every way in; the export sheet says why, the key map and ffmpeg card refuse quietly.
  @discardableResult
  public func openExternally(_ urls: [URL]) -> Task<Void, Never> {
    let routed = OpenRouting.route(urls)
    guard !routed.projects.isEmpty || !routed.media.isEmpty else { return Task {} }
    if refuseImport() {
      // The export sheet and a running export already said why; the key map and ffmpeg card refuse quietly for a
      // drop, but a Finder open the user can't see happen gets a note.
      if modals.top != nil, !modals.contains(.exportSheet), !exportRunning { note(Self.closePanelNote) }
      return Task {}
    }
    if let project = routed.projects.last {
      // The Reel already open (double-click, Open Recent): left as it is, so undo and selection survive.
      if !Self.sameFile(project, projectURL) {
        // A project that can't be opened takes its movies with it: they would land in the old Reel.
        guard openProject(project, keepingBatch: nil) else { return Task {} }
      }
    }
    guard !routed.media.isEmpty else { return Task {} }
    return importURLs(routed.media, at: nil)
  }
}
