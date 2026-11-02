import Foundation
import Synchronization
import Testing
import TrimlabMedia
import TrimlabModel
@testable import TrimlabEditor

/// Task 31: the `.trimlab` file — autosave, reopen, missing clips and Locate…, changed sources (§8.2).
@MainActor @Suite struct ProjectTests {
  // MARK: support

  /// A stored clip as the file holds it. `size` other than the stub's 1 000 makes the source look changed.
  static func stored(_ path: String, duration: RationalTime = RationalTime(10, 1), out: RationalTime? = nil,
                     size: Int64 = 1_000) -> ReelClip {
    let source = SourceRef(relativePath: nil, absolutePath: path, size: size,
                           modified: Date(timeIntervalSince1970: 1_000))
    var clip = ReelClip.make(source: source, facts: StubMedia.facts(duration), framing: .fill)
    if let out { clip.outTime = out }
    return clip
  }

  /// Puts a Reel of `clips` at `path` in the store and opens it.
  @discardableResult
  static func openStored(_ h: Harness, _ clips: [ReelClip], at path: String = "/shoot/shoot.trimlab") -> Reel {
    let reel = Reel(id: UUID(), name: "shoot", clips: clips)
    h.store.add(path, ProjectCodec.encode(reel))
    h.model.open(project: URL(filePath: path))
    return reel
  }

  /// Moves the clock on by `d`. `fires`: the debounce runs out on the way, so the save it fires is awaited. Short of
  /// the deadline nothing is awaited: the save's sleep is still parked on the manual clock and can't run.
  static func elapse(_ h: Harness, _ d: Duration, fires: Bool = true) async {
    h.clock.advance(by: d)
    if fires { await h.model.pendingAutosave?.value }
  }

  static func savedReel(_ h: Harness, _ path: String) throws -> Reel {
    try ProjectCodec.decode(try #require(h.store.data(path)))
  }

  static func trimlabFiles(_ h: Harness) -> [String] {
    h.store.files.withLock { Array($0.keys) }.filter { $0.hasSuffix(".trimlab") }
  }

  // MARK: autosave

  @Test func oneClipWritesNothing() async {
    let h = Harness()
    await h.importAll(["a.mov"])
    await Self.elapse(h, .seconds(2))
    #expect(Self.trimlabFiles(h).isEmpty)
    #expect(h.store.writeLog.isEmpty)
    #expect(h.model.projectURL == nil)
  }

  @Test func secondClipWritesProject() async throws {
    let h = Harness()
    await h.importAll(["a.mov"])
    await h.importAll(["b.mov"])
    await Self.elapse(h, .milliseconds(999), fires: false)
    #expect(h.store.writeLog.isEmpty)
    await Self.elapse(h, .milliseconds(1))
    #expect(h.store.writeLog == ["/shoot/shoot.trimlab"])
    let json = try JSONSerialization.jsonObject(with: try #require(h.store.data("/shoot/shoot.trimlab")))
    #expect((json as? [String: Any])?["schema"] as? Int == 1)
    #expect((json as? [String: Any])?["app"] as? String == "trimlab 2.0")
    let saved = try Self.savedReel(h, "/shoot/shoot.trimlab")
    #expect(saved.clips.map(\.source.relativePath) == ["a.mov", "b.mov"])
    #expect(h.model.projectURL?.path == "/shoot/shoot.trimlab")
    #expect(h.platform.state.withLock { $0.recents.map(\.path) } == ["/shoot/shoot.trimlab"])
  }

  @Test func firstWriteTakesTheNextFreeName() async {
    let h = Harness()
    h.store.add("/shoot/shoot.trimlab", ProjectCodec.encode(Reel.empty(name: "Other")))
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    #expect(h.store.writeLog == ["/shoot/shoot 2.trimlab"])
  }

  @Test func autosaveDebounces() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    #expect(h.store.writeLog.count == 1)
    for i in 1...5 {
      h.model.perform(.rename("Take \(i)"), coalesce: nil)
      await Self.elapse(h, .milliseconds(200), fires: false)
    }
    #expect(h.store.writeLog.count == 1)
    await Self.elapse(h, .milliseconds(799), fires: false)
    #expect(h.store.writeLog.count == 1)
    await Self.elapse(h, .milliseconds(1))
    #expect(h.store.writeLog.count == 2)
    #expect((try? Self.savedReel(h, "/shoot/shoot.trimlab"))?.name == "Take 5")
  }

  @Test func saveNowFlushesAtOnce() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.model.perform(.rename("Now"), coalesce: nil)
    await h.model.saveNow().value
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").name == "Now")
    let writes = h.store.writeLog.count
    await Self.elapse(h, .seconds(2))  // the pending debounce was flushed, not left to write again
    #expect(h.store.writeLog.count == writes)
  }

  @Test func newReelSavesFirst() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.newReel()
    await h.model.pendingSave?.value
    #expect(h.store.writeLog == ["/shoot/shoot.trimlab"])
    #expect(h.model.reel == nil)
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").clips.count == 2)
  }

  @Test func readOnlyFolderFallsBack() async throws {
    let h = Harness()
    h.store.readOnlyFolders.withLock { _ = $0.insert("/shoot") }
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    let fallback = Naming.fallbackFolder
    #expect(fallback.lastPathComponent == "trimlab 2")
    #expect(fallback.deletingLastPathComponent().lastPathComponent == "Movies")
    let path = fallback.appending(path: "shoot.trimlab").path
    #expect(h.store.writeLog == [path])
    #expect(h.store.madeFolders.withLock { $0 } == [fallback.path])
    #expect(h.noteTexts == ["Saved the Reel in Movies › trimlab 2: the clips' folder is read-only."])
    // Outside the clips' folder: absolute paths only.
    #expect(try Self.savedReel(h, path).clips.map(\.source.relativePath) == [nil, nil])
  }

  @Test func neverMovesOrDeletes() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    await h.importAll(["c.mov"], at: 0, in: "/elsewhere")  // the first clip now lives in another folder
    await Self.elapse(h, .seconds(1))
    let ids = Set(h.model.reel?.clips.map(\.id) ?? [])
    h.model.perform(.delete(ids), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    #expect(Set(h.store.writeLog) == ["/shoot/shoot.trimlab"])
    #expect(h.store.writeLog.count == 3)
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").clips.isEmpty)
    #expect(Self.trimlabFiles(h) == ["/shoot/shoot.trimlab"])
  }

  /// relativePath is measured again on every write, so it always says where the file is.
  @Test func everyWriteRebasesRelativePaths() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    await h.importAll(["c.mov"], in: "/shoot/day2")
    await h.importAll(["d.mov"], in: "/elsewhere")
    await Self.elapse(h, .seconds(1))
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").clips.map(\.source.relativePath)
      == ["a.mov", "b.mov", "day2/c.mov", nil])
  }

  // MARK: refused files

  @Test func refusedProjectIsNeverAutosaved() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    let mine = try #require(h.model.projectURL)
    let before = h.model.reel

    // A newer build's file: refused on open, and the open Reel is untouched.
    let newerData = ProjectCodec.encode(Reel.empty(name: "Newer")).replacing(Data("\"schema\" : 1".utf8), with: Data("\"schema\" : 99".utf8))
    h.store.add("/shoot/newer.trimlab", newerData)
    h.model.open(project: URL(filePath: "/shoot/newer.trimlab"))
    #expect(h.model.reel == before)
    #expect(h.model.projectURL == mine)

    // Edits to the current Reel write to its own file, never the refused one.
    h.model.perform(.rename("Still mine"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    await h.model.saveNow().value
    #expect(!h.store.writeLog.contains("/shoot/newer.trimlab"))
    #expect(h.store.data("/shoot/newer.trimlab") == newerData)

    // Its own file replaced behind its back by one it can't open: that file is left alone for good, and the Reel
    // goes on in the next free name beside it, with one plain note (review Minor 7 ruling).
    h.store.add(mine.path, newerData)
    h.model.perform(.rename("Again"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    let moved = "/shoot/shoot 2.trimlab"
    #expect(h.model.projectURL?.path == moved)
    #expect(h.noteTexts.last == "Saved as shoot 2.trimlab: trimlab can't open the shoot.trimlab that's there.")
    #expect(try Self.savedReel(h, moved).name == "Again")
    for i in 1...3 {
      h.model.perform(.rename("More \(i)"), coalesce: nil)
      await Self.elapse(h, .seconds(1))
    }
    await h.model.saveNow().value
    #expect(h.store.data(mine.path) == newerData)
    #expect(try Self.savedReel(h, moved).name == "More 3")
    #expect(h.noteTexts.filter { $0.hasPrefix("Saved as") }.count == 1)
    #expect(h.platform.state.withLock { $0.recents.map(\.path) } == [mine.path, moved])
  }

  @Test func anotherReelsFileIsNeverReplaced() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    let mine = try #require(h.model.projectURL)
    let other = ProjectCodec.encode(Reel.empty(name: "Other"))
    h.store.add(mine.path, other)
    h.model.perform(.rename("Mine"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    #expect(h.store.data(mine.path) == other)
    #expect(h.noteTexts.last == "Saved as shoot 2.trimlab: shoot.trimlab belongs to another Reel.")
    #expect(try Self.savedReel(h, "/shoot/shoot 2.trimlab").name == "Mine")
  }

  /// Review Minor 6: a folder that says it's writable but fails twice in a row sends the Reel to Movies.
  @Test func repeatedWriteFailureFallsBackToMovies() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    _ = h.store.failing.withLock { $0.insert("/shoot/shoot.trimlab") }
    h.model.perform(.rename("One"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    #expect(h.noteTexts == [ProjectWriteError.failed("").message])
    #expect(h.model.projectURL?.path == "/shoot/shoot.trimlab")
    h.model.perform(.rename("Two"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    let fallback = Naming.fallbackFolder.appending(path: "shoot.trimlab").path
    #expect(h.model.projectURL?.path == fallback)
    #expect(try Self.savedReel(h, fallback).name == "Two")
    #expect(h.noteTexts.last == "Saved the Reel in Movies › trimlab 2: the clips' folder is read-only.")
  }

  // MARK: placeholders (review C1)

  @Test func quitWhileProbingDoesNotPersistPlaceholders() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.media.hold()
    let late = h.model.importURLs([Harness.url("c.mov")], at: nil)
    #expect(await h.media.waitForProbes(3))
    await h.model.saveNow().value  // quit
    let data = try #require(h.store.data("/shoot/shoot.trimlab"))
    let saved = try ProjectCodec.decode(data)
    #expect(saved.clips.map { $0.extra[EditorModel.needsProbeKey] } == [nil, nil, .bool(true)])
    h.media.release()
    await late.value

    // Reopened elsewhere: the flagged clip is probed (its size is unchanged) and takes the whole source.
    let h2 = Harness()
    h2.media.script("c.mov", .facts(StubMedia.facts(RationalTime(8, 1))))
    h2.store.add("/shoot/shoot.trimlab", data)
    h2.model.open(project: URL(filePath: "/shoot/shoot.trimlab"))
    #expect(h2.model.loading[saved.clips[2].id] == .probing)
    h2.model.requestExport()
    #expect(h2.noteTexts == ["Wait for the clips to finish loading."])
    await h2.model.pendingReprobe?.value
    #expect(h2.media.probedNames == ["c.mov"])
    let c = try #require(h2.model.reel?.clips.last)
    #expect(c.facts.duration == RationalTime(8, 1))
    #expect(c.inTime == .zero && c.outTime == RationalTime(8, 1))
    #expect(c.extra[EditorModel.needsProbeKey] == nil)
    #expect(h2.model.loading[c.id] == .ready)
    await h2.model.saveNow().value
    #expect(try Self.savedReel(h2, "/shoot/shoot.trimlab").clips.allSatisfy { $0.extra.isEmpty })
  }

  @Test func failedSecondClipLeavesNoProjectFile() async {
    let h = Harness()
    h.media.script("b.mov", .error(ProbeError.unplayable))
    h.media.state.withLock { $0.holdNames = ["b.mov"] }  // a.mov lands, b.mov waits (by name: probes race to start)
    let task = h.model.importURLs([Harness.url("a.mov"), Harness.url("b.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    #expect(await h.media.waitForFinished(1))
    #expect(h.model.reel?.clips.count == 2)
    await h.model.saveNow().value  // quit now: only one clip is ready
    #expect(h.store.writeLog.isEmpty)
    h.media.release()
    await task.value
    await Self.elapse(h, .seconds(2))
    await h.model.saveNow().value
    #expect(h.model.reel?.clips.count == 1)
    #expect(h.store.writeLog.isEmpty)
    #expect(Self.trimlabFiles(h).isEmpty)
  }

  @Test func missingPlaceholderStaysFlagged() async throws {
    let h = Harness()
    var flagged = Self.stored("/card/a.mov", duration: RationalTime(1, 1))
    flagged.extra[EditorModel.needsProbeKey] = .bool(true)
    h.media.unresolvable(["a.mov"])
    Self.openStored(h, [flagged, Self.stored("/shoot/b.mov")])
    await h.model.pendingReprobe?.value
    #expect(h.model.missing == [flagged.id])
    h.model.perform(.rename("x"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").clips.map { $0.extra[EditorModel.needsProbeKey] }
      == [.bool(true), nil])
  }

  // MARK: relinks and undo (review I2)

  @Test func undoAfterLocateKeepsTheNewPath() async throws {
    let h = Harness()
    let clips = [Self.stored("/card/a.mov"), Self.stored("/shoot/b.mov")]
    h.media.unresolvable(["a.mov"])
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    h.model.perform(.rename("Before locate"), coalesce: nil)
    h.platform.state.withLock { $0.panelAnswer = [URL(filePath: "/found/a.mov")] }
    await h.model.locate(clips[0].id).value
    h.model.perform(.rename("After locate"), coalesce: nil)
    for step in ["undo", "undo", "redo", "redo"] {
      if step == "undo" { h.model.undo() } else { h.model.redo() }
      #expect(h.model.reel?.clips[0].source.absolutePath == "/found/a.mov", "after \(step)")
      #expect(h.model.url(for: clips[0].id)?.path == "/found/a.mov")
      #expect(h.model.missing.isEmpty)
      #expect(h.model.loading[clips[0].id] == .ready)
    }
    #expect(h.model.reel?.name == "After locate")
  }

  @Test func locatedFileShorterThanOut() async throws {
    let h = Harness()
    let clips = [Self.stored("/card/IMG_4821.MOV", out: RationalTime(8, 1)), Self.stored("/shoot/b.mov")]
    h.media.unresolvable(["IMG_4821.MOV"])
    h.media.script("IMG_4821.MOV", .facts(StubMedia.facts(RationalTime(6, 1))))
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    h.platform.state.withLock { $0.panelAnswer = [URL(filePath: "/found/IMG_4821.MOV")] }
    await h.model.locate(clips[0].id).value
    #expect(h.model.reel?.clips[0].outTime == RationalTime(6, 1))
    #expect(h.noteTexts == ["IMG_4821.MOV is shorter; its Out moved to the new end."])
  }

  @Test func locateMkvShowsPreparing() async throws {
    let h = Harness()
    let clips = [Self.stored("/card/show.mkv"), Self.stored("/shoot/b.mov")]
    h.media.unresolvable(["show.mkv"])
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    h.media.hold()
    h.platform.state.withLock { $0.panelAnswer = [URL(filePath: "/found/show.mkv")] }
    let task = h.model.locate(clips[0].id)
    #expect(await h.media.waitForProbes(1))
    #expect(h.model.loading[clips[0].id] == .preparing)
    h.media.release()
    await task.value
  }

  // MARK: reopen

  @Test func reopenDrawsStoredFactsAtOnce() async throws {
    let h = Harness()
    let clips = [Self.stored("/shoot/a.mov", duration: RationalTime(7, 1), size: 5),
                 Self.stored("/shoot/b.mov", duration: RationalTime(9, 1))]
    h.media.hold()
    let stored = Self.openStored(h, clips)
    #expect(h.model.reel?.clips.map(\.facts) == stored.clips.map(\.facts))
    #expect(h.model.reel?.clips.map(\.outTime) == stored.clips.map(\.outTime))
    #expect(h.model.url(for: clips[1].id)?.path == "/shoot/b.mov")
    #expect(h.model.loading[clips[1].id] == .ready)
    #expect(h.model.plan?.placements.count == 2)
    // Only the changed source (a.mov, another size) is probed again, in the background.
    #expect(await h.media.waitForProbes(1))
    #expect(h.model.loading[clips[0].id] == .probing)
    #expect(h.model.reel?.clips.map(\.facts) == stored.clips.map(\.facts))
    h.media.release()
    await h.model.pendingReprobe?.value
    #expect(h.media.probedNames == ["a.mov"])
    #expect(h.model.loading[clips[0].id] == .ready)
    #expect(h.model.reel?.clips[0].source.size == 1_000)  // the source's new size and date are kept
    #expect(h.platform.state.withLock { $0.recents.map(\.path) } == ["/shoot/shoot.trimlab"])
  }

  /// Review Focus 2.
  @Test func reopenWithDeletedSourceMarksMissingAndBlocksExport() async throws {
    let h = Harness()
    let clips = [Self.stored("/shoot/a.mov"), Self.stored("/shoot/IMG_4821.MOV"), Self.stored("/shoot/c.mov")]
    h.media.unresolvable(["IMG_4821.MOV"])
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    let gone = clips[1].id
    #expect(h.model.missing == [gone])
    #expect(h.model.loading[gone] == .missing)
    #expect(h.model.url(for: gone) == nil)
    #expect(h.model.plan?.placements.map(\.clipID) == [clips[0].id, clips[2].id])
    #expect(InspectorView.meta(clips[1], state: h.model.loading[gone], missing: true) == ["Missing"])

    h.model.requestExport()
    #expect(h.noteTexts == ["IMG_4821.MOV is missing. Locate it or remove it from the Reel."])
    #expect(h.model.modals.top == nil)

    // The project keeps the clip.
    h.model.perform(.rename("Kept"), coalesce: nil)
    await Self.elapse(h, .seconds(1))
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").clips.map(\.id) == clips.map(\.id))

    // Removed from the Reel, it no longer blocks.
    h.model.perform(.delete([gone]), coalesce: nil)
    h.model.requestExport()
    #expect(h.noteTexts.count == 1)
  }

  @Test func exportWaitsForLoadingClips() async {
    let h = Harness()
    h.media.hold()
    let task = h.model.importURLs([Harness.url("a.mov"), Harness.url("b.mov")], at: nil)
    #expect(await h.media.waitForProbes(2))
    h.model.requestExport()
    #expect(h.noteTexts == ["Wait for the clips to finish loading."])
    h.media.release()
    await task.value
    h.model.requestExport()
    #expect(h.noteTexts == ["Wait for the clips to finish loading."])
  }

  @Test func reprobeFailureMarksMissing() async throws {
    let h = Harness()
    let clips = [Self.stored("/shoot/a.mov", size: 5), Self.stored("/shoot/b.mov")]
    h.media.script("a.mov", .error(ProbeError.unplayable))
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    #expect(h.model.missing == [clips[0].id])
    #expect(h.model.loading[clips[0].id] == .missing)
    #expect(h.model.reel?.clips.map(\.id) == clips.map(\.id))  // kept, not deleted
  }

  @Test func locateRelinksByName() async throws {
    let h = Harness()
    let clips = [Self.stored("/card/a.mov"), Self.stored("/card/b.mov"), Self.stored("/card/c.mov"),
                 Self.stored("/shoot/d.mov")]
    h.media.unresolvable(["a.mov", "b.mov", "c.mov"])
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    #expect(h.model.missing == Set(clips[0...2].map(\.id)))
    h.store.add("/found/b.mov")
    h.store.add("/found/x.mov")
    h.platform.state.withLock { $0.panelAnswer = [URL(filePath: "/found/renamed.mov")] }

    await h.model.locate(clips[0].id).value
    #expect(h.model.missing == [clips[2].id])  // c.mov isn't in /found
    #expect(h.model.url(for: clips[0].id)?.path == "/found/renamed.mov")
    #expect(h.model.url(for: clips[1].id)?.path == "/found/b.mov")
    #expect(h.model.reel?.clips.map(\.source.absolutePath) == ["/found/renamed.mov", "/found/b.mov", "/card/c.mov",
                                                              "/shoot/d.mov"])
    #expect(Set(h.media.probedNames) == ["renamed.mov", "b.mov"])
    #expect(h.model.loading[clips[0].id] == .ready)
    #expect(h.model.loading[clips[1].id] == .ready)
    #expect(h.model.plan?.placements.count == 3)
  }

  @Test func locateCancelledChangesNothing() async {
    let h = Harness()
    let clips = [Self.stored("/card/a.mov"), Self.stored("/shoot/b.mov")]
    h.media.unresolvable(["a.mov"])
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    await h.model.locate(clips[0].id).value  // the panel answers nothing
    #expect(h.model.missing == [clips[0].id])
    #expect(h.media.probedNames.isEmpty)
  }

  @Test func changedSourceClampsOut() async throws {
    let h = Harness()
    let clips = [Self.stored("/shoot/IMG_4821.MOV", duration: RationalTime(10, 1), out: RationalTime(8, 1), size: 5),
                 Self.stored("/shoot/b.mov")]
    h.media.script("IMG_4821.MOV", .facts(StubMedia.facts(RationalTime(6, 1))))
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    let clip = try #require(h.model.reel?.clips.first)
    #expect(clip.outTime == RationalTime(6, 1))
    #expect(clip.facts.duration == RationalTime(6, 1))
    #expect(h.noteTexts == ["IMG_4821.MOV changed; its Out moved to the new end."])
    #expect(!h.model.history.canUndo)  // applied as `.relink`, not recorded
  }

  @Test func changedSourceWithinOutHasNoNote() async throws {
    let h = Harness()
    let clips = [Self.stored("/shoot/a.mov", duration: RationalTime(10, 1), out: RationalTime(5, 1), size: 5),
                 Self.stored("/shoot/b.mov")]
    h.media.script("a.mov", .facts(StubMedia.facts(RationalTime(6, 1))))
    Self.openStored(h, clips)
    let storedOut = h.model.reel?.clips.first?.outTime  // In and Out are snapped to frames on load
    await h.model.pendingReprobe?.value
    #expect(h.model.reel?.clips.first?.outTime == storedOut)
    #expect(h.model.reel?.clips.first?.facts.duration == RationalTime(6, 1))
    #expect(h.noteTexts.isEmpty)
  }

  @Test func newerSchemaRefusedLeavesReel() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    let before = h.model.reel
    let data = ProjectCodec.encode(Reel.empty(name: "N")).replacing(Data("\"schema\" : 1".utf8),
                                                                     with: Data("\"schema\" : 7".utf8))
    h.store.add("/shoot/n.trimlab", data)
    h.model.open(project: URL(filePath: "/shoot/n.trimlab"))
    #expect(h.model.reel == before)
    #expect(h.noteTexts == ["This Reel was made by a newer version of trimlab."])
    #expect(h.store.data("/shoot/n.trimlab") == data)
    await h.model.pendingSave?.value

    h.store.add("/shoot/bad.trimlab", Data("nope".utf8))
    h.model.open(project: URL(filePath: "/shoot/bad.trimlab"))
    #expect(h.model.reel == before)
    #expect(h.noteTexts.last == "This Reel file can't be read.")
    // Only the open Reel's own first save (made before each open was tried) is a recent project.
    #expect(h.platform.state.withLock { $0.recents.map(\.path) } == ["/shoot/shoot.trimlab"])
  }

  @Test func openSavesTheOpenReelFirst() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.store.add("/other/other.trimlab", ProjectCodec.encode(Reel(id: UUID(), name: "other",
                                                                 clips: [Self.stored("/other/x.mov")])))
    h.model.open(project: URL(filePath: "/other/other.trimlab"))
    await h.model.pendingSave?.value
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").clips.count == 2)
    #expect(h.model.projectURL?.path == "/other/other.trimlab")
  }

  @Test func historyStartsFreshOnOpen() async {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    h.model.perform(.rename("x"), coalesce: nil)
    #expect(h.model.history.canUndo)
    Self.openStored(h, [Self.stored("/other/x.mov"), Self.stored("/other/y.mov")], at: "/other/other.trimlab")
    #expect(!h.model.history.canUndo)
    #expect(!h.model.history.canRedo)
    h.model.undo()
    #expect(h.model.reel?.clips.map(\.source.absolutePath) == ["/other/x.mov", "/other/y.mov"])
  }

  // MARK: writes off the main actor (stage 2)

  /// Two saves queued behind a slow write land in order: the file ends holding the newer Reel.
  @Test func savesLandInOrder() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.store.holdWrites()
    h.model.perform(.rename("Older"), coalesce: nil)
    let older = h.model.saveNow()
    #expect(await h.store.waitForWriteStarted(1))
    h.model.perform(.rename("Newer"), coalesce: nil)
    let newer = h.model.saveNow()
    h.store.releaseWrites()
    await older.value
    await newer.value
    #expect(h.store.savedNames == ["shoot", "Older", "Newer"])
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").name == "Newer")
  }

  /// The store's write is slow; the main actor goes on meanwhile (the save returns at once and edits still run).
  @Test func slowWriteDoesNotBlockTheMainActor() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.store.holdWrites()
    h.model.perform(.rename("Slow"), coalesce: nil)
    let save = h.model.saveNow()
    #expect(await h.store.waitForWriteStarted(1))  // the write is in the store, held, off the main actor
    h.model.perform(.rename("Meanwhile"), coalesce: nil)  // runs on the main actor while the write is stuck
    #expect(h.model.reel?.name == "Meanwhile")
    #expect(h.store.savedNames == ["shoot"])
    h.store.releaseWrites()
    await save.value
    #expect(h.store.savedNames == ["shoot", "Slow"])
  }

  @Test func quitWaitsForTheWrite() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.store.holdWrites()
    h.model.perform(.rename("Last"), coalesce: nil)
    let quit = Task { await h.model.prepareForQuit() }
    #expect(await h.store.waitForWriteStarted(1))
    h.store.releaseWrites()
    await quit.value
    #expect(try Self.savedReel(h, "/shoot/shoot.trimlab").name == "Last")
  }

  /// M-7: quit cancels the running imports (their cancel handler is what stops an ffmpeg remux) and waits for them
  /// to end, inside the same budget.
  @Test func quitCancelsRunningImports() async throws {
    let h = Harness()
    h.media.hold()
    let batch = h.model.importURLs([Harness.url("a.mov", in: "/shoot"), Harness.url("b.mov", in: "/shoot")], at: nil)
    #expect(await h.media.waitForProbes(1))
    let running = Array(h.model.importTasks.values)
    #expect(!running.isEmpty)
    #expect(running.allSatisfy { !$0.isCancelled })
    let quit = Task { await h.model.prepareForQuit() }
    for _ in 0..<500 where !running.allSatisfy({ $0.isCancelled }) { try await Task.sleep(for: .milliseconds(10)) }
    let stopped = running.allSatisfy { $0.isCancelled }
    #expect(stopped, "quit left an import running")
    h.media.release()
    await quit.value
    await batch.value
  }

  /// M-7: an import that doesn't stop doesn't hold quit past `quitSaveLimit`.
  @Test func quitDoesNotWaitForeverForAnImport() async throws {
    let h = Harness()
    h.media.hold()
    let batch = h.model.importURLs([Harness.url("a.mov", in: "/shoot")], at: nil)
    #expect(await h.media.waitForProbes(1))
    let ended = Mutex(false)
    let quit = Task {
      await h.model.prepareForQuit()
      ended.withLock { $0 = true }
    }
    #expect(h.model.importTasks.values.allSatisfy { !$0.isCancelled })
    // The limit passes on the model's clock (advanced until the quit has set its timer).
    for _ in 0..<500 where !ended.withLock({ $0 }) {
      h.clock.advance(by: EditorModel.quitSaveLimit)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ended.withLock { $0 }, "quit is still waiting for the import")
    await quit.value  // returned on the limit, though the probe is still held
    h.media.release()
    await batch.value
  }

  /// A write that hangs doesn't hold quit past `quitSaveLimit`.
  @Test func quitGivesUpAfterTheLimit() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.store.holdWrites()
    h.model.perform(.rename("Stuck"), coalesce: nil)
    let quit = Task { await h.model.prepareForQuit() }
    #expect(await h.store.waitForWriteStarted(1))
    h.clock.advance(by: EditorModel.quitSaveLimit)
    await quit.value
    #expect(h.store.savedNames == ["shoot"])
    h.store.releaseWrites()
    await h.model.pendingSave?.value
  }

  /// Moved sources found on open are relinked in one apply: one re-plan for all of them.
  @Test func movedSourcesRelinkInOneApply() async throws {
    let h = Harness()
    let clips = ["a.mov", "b.mov", "c.mov"].map { Self.stored("/old/\($0)") }
    h.media.move(from: "/old", to: "/new")
    let before = h.model.replanCount
    Self.openStored(h, clips)
    await h.model.pendingReprobe?.value
    #expect(h.model.reel?.clips.map(\.source.absolutePath) == ["/new/a.mov", "/new/b.mov", "/new/c.mov"])
    #expect(clips.allSatisfy { h.model.url(for: $0.id)?.path.hasPrefix("/new/") == true })
    #expect(h.model.replanCount - before == 2)  // the reset's, then one for every relink together
    #expect(!h.model.history.canUndo)
  }

  // MARK: polish

  /// Two queued writes to the Reel's file, both refused: one redirect ("shoot 2"), one note.
  @Test func twoRefusedWritesRedirectOnce() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    let mine = try #require(h.model.projectURL)
    h.store.holdWrites()
    h.model.perform(.rename("First"), coalesce: nil)
    let first = h.model.saveNow()
    #expect(await h.store.waitForWriteStarted(2))
    h.model.perform(.rename("Second"), coalesce: nil)
    let second = h.model.saveNow()
    h.store.add(mine.path, Data("not a reel".utf8))  // replaced behind its back before either lands
    h.store.releaseWrites()
    await first.value
    await second.value
    await h.model.pendingSave?.value
    #expect(h.model.projectURL?.path == "/shoot/shoot 2.trimlab")
    #expect(Self.trimlabFiles(h).sorted() == ["/shoot/shoot 2.trimlab", "/shoot/shoot.trimlab"])
    #expect(h.noteTexts.filter { $0.hasPrefix("Saved as") }.count == 1)
    #expect(try Self.savedReel(h, "/shoot/shoot 2.trimlab").name == "Second")
  }

  /// The Reel's own file spelled another way still opens from the newest state, not the disk copy behind a queued write.
  @Test func ownFileReopenMatchesAnySpelling() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    h.model.perform(.rename("Fresh"), coalesce: nil)
    h.store.holdWrites()
    h.model.open(project: URL(filePath: "/shoot/day2/../shoot.trimlab"))
    #expect(h.model.reel?.name == "Fresh")
    #expect(h.noteTexts.isEmpty)
    #expect(!h.model.history.canUndo)  // it did open (history starts fresh), from the newest state
    h.store.releaseWrites()
    await h.model.pendingSave?.value
  }

  /// A clip re-probing because its source changed keeps its stored facts unflagged in a save made mid-probe, so the
  /// next open still sees the change and pulls Out back.
  @Test func changedSourceSurvivesSaveMidProbe() async throws {
    let h = Harness()
    let clips = [Self.stored("/shoot/IMG_4821.MOV", duration: RationalTime(10, 1), out: RationalTime(8, 1), size: 5),
                 Self.stored("/shoot/b.mov")]
    h.media.hold()
    Self.openStored(h, clips)
    #expect(await h.media.waitForProbes(1))
    await h.model.saveNow().value
    let data = try #require(h.store.data("/shoot/shoot.trimlab"))
    let saved = try ProjectCodec.decode(data)
    #expect(saved.clips.map { $0.extra[EditorModel.needsProbeKey] } == [nil, nil])
    h.media.release()
    await h.model.pendingReprobe?.value

    let h2 = Harness()
    h2.media.script("IMG_4821.MOV", .facts(StubMedia.facts(RationalTime(6, 1))))
    h2.store.add("/shoot/shoot.trimlab", data)
    h2.model.open(project: URL(filePath: "/shoot/shoot.trimlab"))
    await h2.model.pendingReprobe?.value
    #expect(h2.model.reel?.clips[0].outTime == RationalTime(6, 1))
    #expect(h2.noteTexts == ["IMG_4821.MOV changed; its Out moved to the new end."])
  }

  /// The closed Reel's last save, refused: a plain error note, no redirect.
  @Test func closedReelsRefusedSaveIsNoted() async throws {
    let h = Harness()
    await h.importAll(["a.mov", "b.mov"])
    await Self.elapse(h, .seconds(1))
    let mine = try #require(h.model.projectURL)
    h.store.add(mine.path, Data("not a reel".utf8))
    h.model.perform(.rename("Last words"), coalesce: nil)
    h.model.newReel()
    await h.model.pendingSave?.value
    #expect(h.model.reel == nil)
    #expect(h.noteTexts == [ProjectWriteError.wouldReplaceRefusedFile.message])
    #expect(h.model.notes.last?.kind == .error)
    #expect(Self.trimlabFiles(h) == [mine.path])
  }
}
