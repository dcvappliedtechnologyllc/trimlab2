import Foundation
import Testing
import TrimlabModel
@testable import TrimlabEditor

/// Task 39: Finder / Dock open events (§8.1, §4.1).
@MainActor @Suite struct OpenRoutingTests {
  private func u(_ name: String) -> URL { Harness.url(name) }

  @Test func routesProjectsAndMedia() {
    let routed = OpenRouting.route([u("a.mov"), u("B.TRIMLAB"), u("c.mp4"), URL(filePath: "/shoot/folder", directoryHint: .isDirectory)])
    #expect(routed.projects == [u("B.TRIMLAB")])
    #expect(routed.media.map(\.lastPathComponent) == ["a.mov", "c.mp4", "folder"])
    let empty = OpenRouting.route([])
    #expect(empty.projects.isEmpty && empty.media.isEmpty)
  }

  @Test func exportFolderOverrideFromArguments() {
    #expect(OpenRouting.exportFolderOverride(arguments: ["app", "-TLOpen", "/a.mov", "-TLExportFolder", "/tmp/out"]) == "/tmp/out")
    #expect(OpenRouting.exportFolderOverride(arguments: ["app", "-TLOpen", "/a.mov"]) == nil)
    #expect(OpenRouting.exportFolderOverride(arguments: ["app", "-TLExportFolder"]) == nil)
    #expect(OpenRouting.exportFolderOverride(arguments: ["app", "-TLExportFolder", "-TLOpen", "/a.mov"]) == nil)
    // The folder is not read as a clip: `-TLOpen` stops at the next flag.
    #expect(OpenRouting.launchURLs(arguments: ["app", "-TLOpen", "/a.mov", "-TLExportFolder", "/tmp/out"]).map(\.path) == ["/a.mov"])
  }

  @Test func projectThenMedia() async {
    let h = Harness()
    h.store.add("/shoot/b.trimlab", ProjectCodec.encode(Reel.empty(name: "B")))
    h.store.add("/shoot/a.trimlab", ProjectCodec.encode(Reel.empty(name: "A")))
    // [b.trimlab, x.mov, a.trimlab]: the last project opens, then x.mov is appended to it.
    await h.model.openExternally([u("b.trimlab"), u("x.mov"), u("a.trimlab")]).value
    #expect(h.model.reel?.name == "A")
    #expect(h.names == ["x.mov"])
  }

  @Test func queuedBeforeModelIsDelivered() {
    let queue = OpenBacklog()
    queue.enqueue([u("a.mov")])
    queue.enqueue([u("b.mov"), u("c.trimlab")])
    var got: [[URL]] = []
    queue.attach { got.append($0) }
    // One batch, in order: "last project, then media" applies across the whole backlog.
    #expect(got.map { $0.map(\.lastPathComponent) } == [["a.mov", "b.mov", "c.trimlab"]])
    queue.enqueue([u("d.mov")])  // after attach: delivered at once, once
    queue.attach { got.append($0) }  // a second attach never replays
    #expect(got.count == 2 && got.last?.first?.lastPathComponent == "d.mov")
  }

  @Test func refusedWhileAModalIsUp() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    h.model.modals.open(.keyMap, opener: "help")
    await h.model.openExternally([u("b.mov")]).value
    #expect(h.names == ["a.mov"])
  }

  @Test func launchArgumentFeedsTheQueue() {
    let urls = OpenRouting.launchURLs(arguments: ["trimlab", "-NSDocumentRevisionsDebugMode", "YES", "-TLOpen", "/x/a.mov", "/x/b.trimlab", "-Other", "/x/no.mov"])
    #expect(urls.map(\.path) == ["/x/a.mov", "/x/b.trimlab"])
    #expect(OpenRouting.launchURLs(arguments: ["trimlab"]).isEmpty)
  }

  @Test func pendingDuplicatesAreDropped() {
    let queue = OpenBacklog()
    queue.enqueue(OpenRouting.launchURLs(arguments: ["-TLOpen", "/shoot/a.mov"]))
    queue.enqueue([u("a.mov"), u("b.mov")])  // the same path arriving as an open event during launch
    var got: [[URL]] = []
    queue.attach { got.append($0) }
    #expect(got.map { $0.map(\.lastPathComponent) } == [["a.mov", "b.mov"]])
  }

  @Test func modalGetsANote() async {
    let h = Harness()
    h.model.modals.open(.keyMap, opener: "help")
    await h.model.openExternally([u("b.mov")]).value
    #expect(h.noteTexts == ["Close this panel first."])
  }

  @Test func reopeningTheOpenReelKeepsItAndAppends() async throws {
    let h = Harness()
    h.store.add("/shoot/a.trimlab", ProjectCodec.encode(Reel.empty(name: "A")))
    await h.model.openExternally([u("a.trimlab")]).value
    await h.importAll(["one.mov"])
    _ = try #require(h.model.reel?.clips.first?.id)
    let recents = h.platform.state.withLock { $0.recents.count }
    // The open Reel is not reloaded (a reload resets undo and selection, and notes the file as recent again).
    await h.model.openExternally([u("a.trimlab"), u("x.mov")]).value
    #expect(h.names == ["one.mov", "x.mov"])
    #expect(h.platform.state.withLock { $0.recents.count } == recents)
  }

  @Test func failedProjectTakesItsMediaWithIt() async {
    let h = Harness()
    h.store.add("/shoot/bad.trimlab", Data("not json".utf8))
    await h.importAll(["one.mov"])
    await h.model.openExternally([u("bad.trimlab"), u("x.mov")]).value
    #expect(h.names == ["one.mov"])
  }
}
