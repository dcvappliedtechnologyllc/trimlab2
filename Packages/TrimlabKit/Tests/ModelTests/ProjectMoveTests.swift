import Foundation
import Testing
@testable import TrimlabModel

/// Renaming the Reel renames its `.trimlab` file (§6.1): `ProjectFile.move` renames in place and never replaces
/// anything, on a real folder.
@Suite struct ProjectMoveTests {
  static func folder() throws -> URL { try ProjectCodecTests.tempFolder() }

  static func listing(_ folder: URL) throws -> [String] { try ProjectCodecTests.listing(folder) }

  @Test func movesTheFileAndKeepsItsBytes() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab"), to = folder.appendingPathComponent("Spa Tour.trimlab")
    let data = ProjectCodec.encode(Builders.reel([3, 4]))
    try data.write(to: from)
    try ProjectFile.move(from, to: to)
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
    #expect(try Data(contentsOf: to) == data)
  }

  /// Any file or folder at the new name refuses, and both stay as they were.
  @Test func refusesATakenName() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab")
    try Data("ours".utf8).write(to: from)
    let file = folder.appendingPathComponent("Taken.trimlab")
    try Data("theirs".utf8).write(to: file)
    #expect(throws: ProjectMoveError.taken) { try ProjectFile.move(from, to: file) }
    #expect(try Data(contentsOf: file) == Data("theirs".utf8))
    let dir = folder.appendingPathComponent("Dir.trimlab")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    #expect(throws: ProjectMoveError.taken) { try ProjectFile.move(from, to: dir) }
    // Case-insensitively taken too (APFS by default).
    #expect(throws: ProjectMoveError.taken) { try ProjectFile.move(from, to: folder.appendingPathComponent("TAKEN.trimlab")) }
    #expect(try Self.listing(folder) == ["Dir.trimlab", "Taken.trimlab", "shoot.trimlab"])
    #expect(try Data(contentsOf: from) == Data("ours".utf8))
  }

  /// A symlink at the new name is taken, even a dangling one.
  @Test func refusesASymlinkAtTheName() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab")
    try Data().write(to: from)
    let link = folder.appendingPathComponent("Link.trimlab")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nowhere/at/all")
    #expect(throws: ProjectMoveError.taken) { try ProjectFile.move(from, to: link) }
  }

  @Test func nothingToMove() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: ProjectMoveError.noFile) {
      try ProjectFile.move(folder.appendingPathComponent("gone.trimlab"), to: folder.appendingPathComponent("new.trimlab"))
    }
    #expect(try Self.listing(folder).isEmpty)
  }

  /// A change of case only is a rename of the same file, not a clash with itself.
  @Test func caseOnlyRename() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("spa tour.trimlab")
    try Data("x".utf8).write(to: from)
    try ProjectFile.move(from, to: folder.appendingPathComponent("Spa Tour.trimlab"))
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
  }

  /// The same name is a no-op.
  @Test func sameNameIsNoOp() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab")
    try Data("x".utf8).write(to: from)
    try ProjectFile.move(from, to: from)
    #expect(try Self.listing(folder) == ["shoot.trimlab"])
  }

  // MARK: volumes without RENAME_EXCL (exFAT, some shares), through the `exclusiveRename` seam

  static func unsupported(_: String, _: String) -> Int32 { ENOTSUP }

  /// `ENOTSUP` (or `EINVAL`): an `O_EXCL` placeholder claims the name, then a plain rename replaces only it.
  @Test func fallsBackWithoutExclusiveRename() throws {
    for code in [ENOTSUP, EINVAL] {
      let folder = try Self.folder()
      defer { try? FileManager.default.removeItem(at: folder) }
      let from = folder.appendingPathComponent("shoot.trimlab"), to = folder.appendingPathComponent("Spa Tour.trimlab")
      try Data("ours".utf8).write(to: from)
      try ProjectFile.move(from, to: to, reelID: nil, exclusiveRename: { _, _ in code })
      #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
      #expect(try Data(contentsOf: to) == Data("ours".utf8))
    }
  }

  @Test func fallbackRefusesATakenName() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab"), to = folder.appendingPathComponent("Taken.trimlab")
    try Data("ours".utf8).write(to: from)
    try Data("theirs".utf8).write(to: to)
    let link = folder.appendingPathComponent("Link.trimlab")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nowhere/at/all")
    #expect(throws: ProjectMoveError.taken) { try ProjectFile.move(from, to: to, reelID: nil, exclusiveRename: Self.unsupported) }
    #expect(throws: ProjectMoveError.taken) { try ProjectFile.move(from, to: link, reelID: nil, exclusiveRename: Self.unsupported) }
    #expect(try Data(contentsOf: to) == Data("theirs".utf8))
    #expect(try Self.listing(folder) == ["Link.trimlab", "Taken.trimlab", "shoot.trimlab"])
  }

  /// A rename that fails after the placeholder was made takes the placeholder away again.
  @Test func fallbackRemovesItsPlaceholderOnFailure() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("odd.trimlab")
    try FileManager.default.createDirectory(at: from, withIntermediateDirectories: false)  // rename(dir, file) fails
    #expect(throws: (any Error).self) {
      try ProjectFile.move(from, to: folder.appendingPathComponent("new.trimlab"), reelID: nil,
                           exclusiveRename: Self.unsupported)
    }
    #expect(try Self.listing(folder) == ["odd.trimlab"])
  }

  /// Any other errno is a plain failure, with nothing left behind.
  @Test func otherErrorsFail() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab")
    try Data().write(to: from)
    #expect(throws: (any Error).self) {
      try ProjectFile.move(from, to: folder.appendingPathComponent("new.trimlab"), reelID: nil,
                           exclusiveRename: { _, _ in EACCES })
    }
    #expect(try Self.listing(folder) == ["shoot.trimlab"])
  }

  // MARK: the Reel's own file only (rename-review M-1)

  @Test func refusesAnotherReelsFile() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let from = folder.appendingPathComponent("shoot.trimlab"), to = folder.appendingPathComponent("Spa Tour.trimlab")
    let theirs = Builders.reel([3, 4])
    try ProjectCodec.encode(theirs).write(to: from)
    #expect(throws: ProjectMoveError.anotherReel) { try ProjectFile.move(from, to: to, reelID: UUID()) }
    try Data("not a Reel".utf8).write(to: from)
    #expect(throws: ProjectMoveError.anotherReel) { try ProjectFile.move(from, to: to, reelID: theirs.id) }
    try ProjectCodec.encode(theirs).write(to: from)
    try ProjectFile.move(from, to: to, reelID: theirs.id)
    #expect(try Self.listing(folder) == ["Spa Tour.trimlab"])
  }
}
