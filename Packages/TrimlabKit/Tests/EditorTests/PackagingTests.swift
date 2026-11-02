import Foundation
import Testing

@Suite struct PackagingTests {
  private func plist() throws -> [String: Any] {
    let data = try Data(contentsOf: SourceScan.repoRoot / "App/Info.plist")
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }

  @Test func infoPlistTypes() throws {
    let p = try plist()
    #expect(p["CFBundleIdentifier"] as? String == "com.dcv.trimlab2")
    #expect(p["CFBundleDisplayName"] as? String == "trimlab 2")
    #expect(p["CFBundleName"] as? String == "trimlab 2")
    #expect(p["LSMinimumSystemVersion"] as? String == "26.0")
    #expect(p["CFBundleIconFile"] as? String == "trimlab")

    let exported = try #require(p["UTExportedTypeDeclarations"] as? [[String: Any]])
    let reel = try #require(exported.first { $0["UTTypeIdentifier"] as? String == "com.dcv.trimlab.reel" })
    let conforms = reel["UTTypeConformsTo"] as? [String]
    #expect(conforms == ["public.data", "public.content"])
    #expect(conforms?.contains("public.json") == false)
    let tags = reel["UTTypeTagSpecification"] as? [String: Any]
    #expect(tags?["public.filename-extension"] as? [String] == ["trimlab"])

    let imported = try #require(p["UTImportedTypeDeclarations"] as? [[String: Any]])
    let mkv = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "org.matroska.mkv" })
    let mkvTags = mkv["UTTypeTagSpecification"] as? [String: Any]
    #expect(mkvTags?["public.filename-extension"] as? [String] == ["mkv"])

    let docs = try #require(p["CFBundleDocumentTypes"] as? [[String: Any]])
    let movies = try #require(docs.first { $0["CFBundleTypeName"] as? String == "Movies" })
    #expect(movies["CFBundleTypeRole"] as? String == "Viewer")
    #expect(movies["LSHandlerRank"] as? String == "Alternate")
    let movieTypes = movies["LSItemContentTypes"] as? [String] ?? []
    for t in ["public.movie", "com.apple.quicktime-movie", "public.mpeg-4", "com.apple.m4v-video",
              "public.avchd-mpeg-2-transport-stream", "public.avi", "org.matroska.mkv"] {
      #expect(movieTypes.contains(t), "missing \(t)")
    }
    let project = try #require(docs.first { ($0["LSItemContentTypes"] as? [String]) == ["com.dcv.trimlab.reel"] })
    #expect(project["CFBundleTypeRole"] as? String == "Editor")
    #expect(project["LSHandlerRank"] as? String == "Owner")
  }

  @Test func signingScriptIsTrimlabCopy() throws {
    let text = try String(contentsOf: SourceScan.repoRoot / "App/make-signing-identity.sh", encoding: .utf8)
    #expect(text.contains("NAME=\"trimlab dev\""))
    #expect(!text.lowercased().contains("camlab"))
  }

  @Test func buildScriptRefusesWhileRunning() throws {
    let text = try String(contentsOf: SourceScan.repoRoot / "App/build.sh", encoding: .utf8)
    #expect(text.contains("pgrep -f \"$REPO/dist/trimlab2.app/Contents/MacOS/trimlab2\""))
    #expect(text.contains("One-time fix: run ./App/make-signing-identity.sh"))
  }
}
