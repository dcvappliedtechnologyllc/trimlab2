import Foundation
import Testing
@testable import TrimlabEditor

/// `ExportSweep`: the launch sweep of export temporaries a crash or force quit left behind (Task 23 / Task 36 carries).
/// Only exact matches older than a day go; everything else in the folder is never touched.
@Suite struct ExportSweepTests {
  @Test(arguments: [
    "IMG_4821.0a1b2c3d.partial.mp4",
    "IMG_4821.0a1b2c3d.partial.mov",
    "My Reel 2.ffffffff.partial.m4v",
    "a.b.c.12345678.partial.mp4",
    "IMG_4821.0a1b2c3d.replacing.mp4",
    "IMG_4821.0a1b2c3d.replacing.mov",
    "IMG_4821.0a1b2c3d.replacing.9e8d7c6b.partial.mp4",
    "IMG_4821.0a1b2c3d.replacing.9e8d7c6b.partial.mov",
    // The writer's network-use temporary beside a partial (`<partial>.sb-…`).
    "IMG_4821.0a1b2c3d.partial.mp4.sb-1a2b3c4d-Zy9xWv",
    "IMG_4821.0a1b2c3d.partial.mov.sb-abcdef12",
    "IMG_4821.0a1b2c3d.replacing.9e8d7c6b.partial.mp4.sb-1a2b3c4d-Zy9xWv",
  ])
  func orphanNamesMatch(_ name: String) {
    #expect(ExportSweep.isOrphan(name))
  }

  @Test(arguments: [
    "IMG_4821.mp4",
    "IMG_4821 2.mp4",
    "IMG_4821.partial.mp4",               // no tag
    "IMG_4821.0a1b2c3.partial.mp4",       // 7 hex
    "IMG_4821.0a1b2c3d4.partial.mp4",     // 9 hex
    "IMG_4821.0A1B2C3D.partial.mp4",      // upper case: trimlab writes lower
    "IMG_4821.0a1b2c3g.partial.mp4",      // not hex
    "IMG_4821.0a1b2c3d.partial",          // no extension
    "IMG_4821.0a1b2c3d.partial.",         // empty extension
    "IMG_4821.0a1b2c3d.partial.mp4.txt",  // something after the extension
    "IMG_4821.0a1b2c3d.partials.mp4",
    "IMG_4821.0a1b2c3d.Partial.mp4",
    "IMG_4821.0a1b2c3d-partial.mp4",
    "IMG_4821 0a1b2c3d.partial.mp4",
    ".0a1b2c3d.partial.mp4",              // no stem
    "0a1b2c3d.partial.mp4",               // no stem
    "IMG_4821.0a1b2c3d.replaced.mp4",
    "IMG_4821.0a1b2c3d.replacing",
    "IMG_4821.replacing.mp4",
    "IMG_4821.0a1b2c3d.replacing.mp4.bak",
    "IMG_4821.0a1b2c3d.replacing.9e8d7c6.partial.mp4",  // 7 hex on the partial
    "IMG_4821.0a1b2c3d.replacing.partial.mp4",
    "IMG_4821.0a1b2c3d.partial.mp4 copy",
    "IMG_4821.0a1b2c3d.partial.mp4/",
    "partial.mp4",
    "My Reel.trimlab",
    ".remux.0a1b2c3d.mov",
    "IMG_4821.0a1b2c3d.partial.mp4.sb-",             // empty suffix
    "IMG_4821.0a1b2c3d.partial.mp4.sb-ab/cd",       // not a name
    "IMG_4821.0a1b2c3d.partial.mp4.sb-ab.txt",      // something after the suffix
    "IMG_4821.0a1b2c3d.partial.mp4.sb_ab",
    "IMG_4821.0a1b2c3d.replacing.mp4.sb-ab12",      // only a partial has a writer temporary
    "IMG_4821.partial.mp4.sb-ab12",                 // no tag
    "IMG_4821.0a1b2c3d.partial.mp4.SB-ab12",
  ])
  func nearMissesDoNot(_ name: String) {
    #expect(!ExportSweep.isOrphan(name))
  }

  private func makeFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func file(_ dir: URL, _ name: String, age: TimeInterval) throws {
    let url = dir.appending(path: name)
    try Data("x".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
  }

  private func names(_ dir: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
  }

  @Test func sweepsOnlyOldExactMatches() throws {
    let dir = try makeFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let day: TimeInterval = 86_400
    try file(dir, "IMG_1.0a1b2c3d.partial.mp4", age: 2 * day)                     // goes
    try file(dir, "IMG_2.0a1b2c3d.replacing.mov", age: 2 * day)                   // goes
    try file(dir, "IMG_3.0a1b2c3d.replacing.9e8d7c6b.partial.mp4", age: 2 * day)  // goes
    try file(dir, "IMG_4.0a1b2c3d.partial.mp4", age: 3600)                        // too new: an export may be running
    try file(dir, "IMG_5.mp4", age: 30 * day)                                     // an export
    try file(dir, "IMG_3b.0a1b2c3d.partial.mp4.sb-1a2b3c4d-Zy9xWv", age: 2 * day)  // goes (writer temporary)
    try file(dir, "IMG_4b.0a1b2c3d.partial.mp4.sb-1a2b3c4d-Zy9xWv", age: 3600)     // too new
    try file(dir, "IMG_6.0A1B2C3D.partial.mp4", age: 30 * day)                    // near miss
    try file(dir, "IMG_7.0a1b2c3d.partial.mp4.txt", age: 30 * day)                // near miss
    // A folder with an orphan's name is not a file trimlab wrote.
    let folder = dir.appending(path: "IMG_8.0a1b2c3d.partial.mp4", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * day)], ofItemAtPath: folder.path)
    // Nor is a link pointing elsewhere, even if its own name matches.
    let target = dir.appending(path: "keep-target.mp4")
    try file(dir, "keep-target.mp4", age: 30 * day)
    try FileManager.default.createSymbolicLink(at: dir.appending(path: "IMG_9.0a1b2c3d.partial.mp4"),
                                               withDestinationURL: target)

    let removed = ExportSweep.sweep(folders: [dir], olderThan: day)
    #expect(removed == 4)
    #expect(names(dir) == [
      "IMG_4.0a1b2c3d.partial.mp4", "IMG_4b.0a1b2c3d.partial.mp4.sb-1a2b3c4d-Zy9xWv", "IMG_5.mp4", "IMG_6.0A1B2C3D.partial.mp4", "IMG_7.0a1b2c3d.partial.mp4.txt",
      "IMG_8.0a1b2c3d.partial.mp4", "keep-target.mp4", "IMG_9.0a1b2c3d.partial.mp4",
    ])
  }

  @Test func doesNotDescendIntoSubfolders() throws {
    let dir = try makeFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sub = dir.appending(path: "Older", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
    try file(sub, "IMG_1.0a1b2c3d.partial.mp4", age: 5 * 86_400)
    #expect(ExportSweep.sweep(folders: [dir], olderThan: 86_400) == 0)
    #expect(names(sub) == ["IMG_1.0a1b2c3d.partial.mp4"])
  }

  @Test func sameFolderTwiceAndMissingFoldersAreFine() throws {
    let dir = try makeFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    try file(dir, "IMG_1.0a1b2c3d.partial.mp4", age: 5 * 86_400)
    let gone = dir.appending(path: "not-there", directoryHint: .isDirectory)
    let again = URL(filePath: dir.path + "/", directoryHint: .isDirectory)
    #expect(ExportSweep.sweep(folders: [dir, again, gone], olderThan: 86_400) == 1)
  }

  /// The folders the launch sweep looks in: the last export's and the open Reel's, each once, never nil.
  @Test func foldersAreLastFolderAndTheReelsFolder() {
    #expect(ExportSweep.folders(lastFolder: nil, reelFolder: nil).isEmpty)
    #expect(ExportSweep.folders(lastFolder: "/a/b", reelFolder: nil).map(\.path) == ["/a/b"])
    #expect(ExportSweep.folders(lastFolder: "/a/b", reelFolder: URL(filePath: "/a/b/")).map(\.path) == ["/a/b"])
    #expect(ExportSweep.folders(lastFolder: "/a/b", reelFolder: URL(filePath: "/c")).map(\.path) == ["/a/b", "/c"])
    #expect(ExportSweep.folders(lastFolder: "", reelFolder: nil).isEmpty)
    #expect(ExportSweep.folders(lastFolder: "relative/path", reelFolder: nil).isEmpty)
  }
}
