import Foundation
import Testing
@testable import TrimlabModel

@Suite struct SourceResolverTests {
  static let folder = URL(fileURLWithPath: "/Users/me/Movies/Spa Tour", isDirectory: true)

  static func ref(relative: String?, absolute: String = "/Volumes/Card/DCIM/IMG_4821.MOV") -> SourceRef {
    SourceRef(relativePath: relative, absolutePath: absolute, size: 1, modified: Date(timeIntervalSinceReferenceDate: 0))
  }

  @Test func relativePathFirst() {
    let ref = Self.ref(relative: "IMG_4821.MOV")
    let relative = "/Users/me/Movies/Spa Tour/IMG_4821.MOV"
    let absolute = "/Volumes/Card/DCIM/IMG_4821.MOV"

    let both = SourceResolver.resolve(ref, projectFolder: Self.folder) { [relative, absolute].contains($0) }
    #expect(both?.path == relative)

    let onlyAbsolute = SourceResolver.resolve(ref, projectFolder: Self.folder) { $0 == absolute }
    #expect(onlyAbsolute?.path == absolute)

    let neither = SourceResolver.resolve(ref, projectFolder: Self.folder) { _ in false }
    #expect(neither == nil)
  }

  @Test func relativePathMayClimbOutOfTheProjectFolder() {
    let ref = Self.ref(relative: "../Clips/IMG_4821.MOV")
    let url = SourceResolver.resolve(ref, projectFolder: Self.folder) { $0 == "/Users/me/Movies/Clips/IMG_4821.MOV" }
    #expect(url?.path == "/Users/me/Movies/Clips/IMG_4821.MOV")
  }

  @Test func noProjectFolderUsesTheAbsolutePath() {
    let ref = Self.ref(relative: "IMG_4821.MOV")
    var asked: [String] = []
    let url = SourceResolver.resolve(ref, projectFolder: nil) { asked.append($0); return true }
    #expect(url?.path == "/Volumes/Card/DCIM/IMG_4821.MOV")
    #expect(asked == ["/Volumes/Card/DCIM/IMG_4821.MOV"])
  }

  @Test func noRelativePathUsesTheAbsolutePath() {
    for relative in [nil, ""] as [String?] {
      let url = SourceResolver.resolve(Self.ref(relative: relative), projectFolder: Self.folder) { _ in true }
      #expect(url?.path == "/Volumes/Card/DCIM/IMG_4821.MOV")
    }
  }

  @Test func emptyAbsolutePathIsNotAFile() {
    let url = SourceResolver.resolve(Self.ref(relative: nil, absolute: ""), projectFolder: Self.folder) { _ in true }
    #expect(url == nil)
  }

  // MARK: file-name fallback (ruling: a moved project folder still finds its clips)

  @Test func movedProjectFolderFindsClipByFileName() {
    // Golden-style clip: no relativePath, absolute path from the old location.
    let ref = Self.ref(relative: nil, absolute: "/Users/me/Movies/Spa Tour/IMG_4830.MOV")
    let moved = URL(fileURLWithPath: "/Volumes/Backup/Spa Tour", isDirectory: true)
    let url = SourceResolver.resolve(ref, projectFolder: moved) { $0 == "/Volumes/Backup/Spa Tour/IMG_4830.MOV" }
    #expect(url?.path == "/Volumes/Backup/Spa Tour/IMG_4830.MOV")
  }

  @Test func fileNameFallbackComesAfterRelativeAndAbsolute() {
    let ref = Self.ref(relative: "Clips/IMG_4821.MOV")
    let relative = "/Users/me/Movies/Spa Tour/Clips/IMG_4821.MOV"
    let absolute = "/Volumes/Card/DCIM/IMG_4821.MOV"
    let byName = "/Users/me/Movies/Spa Tour/IMG_4821.MOV"
    var asked: [String] = []
    let none = SourceResolver.resolve(ref, projectFolder: Self.folder) { asked.append($0); return false }
    #expect(none == nil)
    #expect(asked == [relative, absolute, byName])

    #expect(SourceResolver.resolve(ref, projectFolder: Self.folder) { [absolute, byName].contains($0) }?.path == absolute)
    #expect(SourceResolver.resolve(ref, projectFolder: Self.folder) { $0 == byName }?.path == byName)
  }

  @Test func noProjectFolderMeansNoFileNameFallback() {
    let ref = Self.ref(relative: nil)
    var asked: [String] = []
    _ = SourceResolver.resolve(ref, projectFolder: nil) { asked.append($0); return false }
    #expect(asked == ["/Volumes/Card/DCIM/IMG_4821.MOV"])
  }

  @Test func resolvingTouchesNothingButFileExists() {
    // A folder path that doesn't exist on disk must still resolve purely (no hidden directory checks).
    let folder = URL(filePath: "/nonexistent-\(UUID().uuidString)/Spa Tour", directoryHint: .isDirectory)
    let ref = Self.ref(relative: "IMG_4821.MOV")
    let url = SourceResolver.resolve(ref, projectFolder: folder) { $0.hasSuffix("/Spa Tour/IMG_4821.MOV") }
    #expect(url?.lastPathComponent == "IMG_4821.MOV")
    #expect(url?.hasDirectoryPath == false)
  }
}
