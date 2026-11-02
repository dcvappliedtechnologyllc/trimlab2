import Foundation
import Testing

@Suite struct SourceScanTests {
  @Test("test_no_appkit_in_package") func noAppKitInPackage() throws {
    #expect(offenders(matching: appKitRegex, under: ["Packages/TrimlabKit/Sources"]) == [])
  }

  /// SPEC §3.1 layering: each module may import only what its layer allows.
  @Test("test_module_import_rules") func moduleImportRules() throws {
    let src = "Packages/TrimlabKit/Sources/"
    let rules: [(dir: String, banned: [String])] = [
      ("TrimlabModel", ["AVFoundation", "CoreImage", "SwiftUI", "AppKit", "UIKit"]),
      ("TrimlabMedia", ["SwiftUI", "AppKit", "UIKit"]),
      ("TrimlabEditor", ["AppKit", "UIKit"]),
    ]
    for rule in rules {
      #expect(try offenders(matching: importRegex(rule.banned), under: [src + rule.dir]) == [],
              "\(rule.dir) imports a banned framework")
    }
  }

  @Test("test_no_default_controls") func noDefaultControls() throws {
    let views = ["Packages/TrimlabKit/Sources/TrimlabEditor/Views", "App"]
    let forbidden = #/\b(Button|Toggle|Picker|Slider|Stepper|Menu|TextField|SecureField|List|Form|VideoPlayer|AVPlayerView)\s*[\(\{]|\.(help|alert|confirmationDialog|sheet|popover)\s*\(|scrollIndicators\(\s*\.(visible|automatic)/#
    #expect(offenders(matching: forbidden, under: views, excluding: "Design/Controls/") == [])
    #expect(scrollViewOffenders(under: views, excluding: "Design/Controls/") == [])
    #expect(SourceScan.swiftFiles(under: views[0]).count >= 3, "Views/ must not be scanned empty")
  }

  @Test func scansAreNotVacuous() {
    #expect(FileManager.default.fileExists(atPath: (SourceScan.repoRoot / "project.yml").path))
    #expect(SourceScan.swiftFiles(under: "Packages/TrimlabKit/Sources").count >= 3)
    #expect(SourceScan.swiftFiles(under: "App").contains { $0.lastPathComponent == "TrimlabApp.swift" })
  }

  @Test func scannerCatchesPlantedViolation() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Planted.swift")
    try "import AppKit\nstruct V { var b: some View { Toggle(\"x\", isOn: $on) } }\n"
      .write(to: file, atomically: true, encoding: .utf8)

    let appKit = offenders(matching: #/import (AppKit|UIKit)/#, under: [dir.path])
    #expect(appKit == ["\(file.path):1"])
    let controls = offenders(matching: #/\bToggle\s*[\(\{]/#, under: [dir.path])
    #expect(controls == ["\(file.path):2"])

    // The brace (or paren) on the next line, after a blank line, is still a hit, reported where the symbol is.
    let split = dir.appendingPathComponent("Split.swift")
    try "struct W {\n  var b: some View {\n    Button\n\n    {\n      go()\n    } label: { Text(\"x\") }\n  }\n}\n"
      .write(to: split, atomically: true, encoding: .utf8)
    let button = offenders(matching: #/\bButton\s*[\(\{]/#, under: [split.path])
    #expect(button == ["\(split.path):3"])
  }

  @Test func scannerRulesBehave() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("Design/Controls"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let button = #/\bButton\s*[\(\{]/#

    // excluding: skips matching paths
    let ctl = dir.appendingPathComponent("Design/Controls/TLButton.swift")
    try "Button(action) {}\n".write(to: ctl, atomically: true, encoding: .utf8)
    #expect(offenders(matching: button, under: [dir.path], excluding: "Design/Controls/") == [])
    #expect(offenders(matching: button, under: [dir.path]) == ["\(ctl.path):1"])

    // menu-bar marker: Button( inside a CommandGroup block is exempt, outside it is not
    let menus = dir.appendingPathComponent("Menus.swift")
    try """
    // menu-bar
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open") {}
      }
    }
    Button("Stray") {}

    """.write(to: menus, atomically: true, encoding: .utf8)
    #expect(offenders(matching: button, under: [dir.path], excluding: "Design/Controls/")
      == ["\(menus.path):7"])
    // without the marker nothing is exempt
    try "\n.commands {\n  CommandMenu(\"X\") {\n    Button(\"Open\") {}\n  }\n}\n"
      .write(to: menus, atomically: true, encoding: .utf8)
    #expect(offenders(matching: button, under: [dir.path], excluding: "Design/Controls/")
      == ["\(menus.path):4"])
  }

  @Test func missingDirectoryFailsUnlessExpected() throws {
    let gone = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-missing-\(UUID().uuidString)").path
    let any = #/x/#
    #expect(offenders(matching: any, under: [gone]) == ["missing directory: \(gone)"])
    #expect(scrollViewOffenders(under: [gone]) == ["missing directory: \(gone)"])
    #expect(offenders(matching: any, under: [gone], missingOK: [gone]) == [])
    #expect(scrollViewOffenders(under: [gone], missingOK: [gone]) == [])
  }

  @Test func importRulesCatchPlantedImports() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("P.swift")
    try """
    import Foundation
    import SwiftUI
    @_exported import AppKit
    import struct AppKit.NSRect
    @preconcurrency import AVFoundation
    import CoreImage.CIFilterBuiltins
    // import SwiftUI in a comment is fine
    let s = NSString(string: "ok"), r = NSRange(location: 0, length: 0)
    let v: NSView? = nil
    """.write(to: file, atomically: true, encoding: .utf8)
    let model = try offenders(matching: importRegex(["AVFoundation", "CoreImage", "SwiftUI", "AppKit"]), under: [dir.path])
    #expect(model == ["\(file.path):2", "\(file.path):3", "\(file.path):4", "\(file.path):5", "\(file.path):6"])
    let editor = try offenders(matching: importRegex(["AppKit"]), under: [dir.path])
    #expect(editor == ["\(file.path):3", "\(file.path):4"])
    // NSString/NSRange are Foundation: not flagged; NSView is.
    #expect(offenders(matching: appKitRegex, under: [dir.path])
      == ["\(file.path):3", "\(file.path):4", "\(file.path):9"])
  }

  @Test func scrollViewNeedsHiddenIndicators() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bare = dir.appendingPathComponent("Bare.swift")
    try "ScrollView {\n  Text(\"x\")\n}\n".write(to: bare, atomically: true, encoding: .utf8)
    let ok = dir.appendingPathComponent("Ok.swift")
    try "ScrollView {\n  Text(\"x\")\n}\n.scrollIndicators(.hidden)\n"
      .write(to: ok, atomically: true, encoding: .utf8)
    #expect(scrollViewOffenders(under: [dir.path]) == ["\(bare.path):1"])
  }
}

// MARK: - Scanner

enum SourceScan {
  /// The repo root, derived from this file: <root>/Packages/TrimlabKit/Tests/EditorTests/SourceScanTests.swift
  static let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

  /// Every .swift file under `entry` (a repo-relative or absolute path), sorted. A file entry is returned as is.
  static func swiftFiles(under entry: String) -> [URL] {
    let base = entry.hasPrefix("/") ? URL(fileURLWithPath: entry) : repoRoot / entry
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue { return base.pathExtension == "swift" ? [base] : [] }
    // Relative walk, so reported paths keep the caller's spelling (no /var vs /private/var surprises).
    let relative = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
    return relative.filter { $0.hasSuffix(".swift") }.sorted().map { base / $0 }
  }

  /// A scan root that doesn't exist must fail loudly, not scan nothing. `missingOK` lists roots expected later.
  static func missingEntry(_ entry: String, _ missingOK: [String]) -> String? {
    let base = entry.hasPrefix("/") ? URL(fileURLWithPath: entry) : repoRoot / entry
    if FileManager.default.fileExists(atPath: base.path) || missingOK.contains(entry) { return nil }
    return "missing directory: \(entry)"
  }

  static func lines(of url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
  }
}

/// AppKit/UIKit leakage: any import form of the two frameworks (plain, `@_exported`, `import struct AppKit.X`),
/// or a named AppKit type. Approach: imports by pattern plus an explicit list of AppKit `NS*` types, so
/// Foundation's NSString, NSRange, NSNumber etc. are never flagged.
var appKitRegex: Regex<(Substring, Substring?, Substring?, Substring?, Substring?, Substring?, Substring?)> {
  #/^\s*(@\w+(\([^)]*\))?\s+)*import\s+((struct|class|enum|protocol|func|var|let|typealias)\s+)?(AppKit|UIKit)(?![A-Za-z0-9_])|\bNS(View|Image|Color|Workspace|Window|Application|Panel|OpenPanel|SavePanel|Event|Cursor|Font|Menu|MenuItem|Screen|Pasteboard|HostingView|ViewController|WindowController|BezierPath|Alert|Responder|Button|TextField|ImageView|ScrollView)\b/#
}

/// `import <name>` for any of `names`, in any import form, ignoring commented lines.
func importRegex(_ names: [String]) throws -> Regex<AnyRegexOutput> {
  try Regex("^\\s*(@\\w+(\\([^)]*\\))?\\s+)*import\\s+((struct|class|enum|protocol|func|var|let|typealias)\\s+)?(\\Q" +
    names.joined(separator: "\\E|\\Q") + "\\E)(?![A-Za-z0-9_])")
}

func / (lhs: URL, rhs: String) -> URL { lhs.appending(path: rhs) }

/// "path:line" (1-based) for every line under `under` that matches. Paths containing `excluding` are skipped.
/// A file whose first line is `// menu-bar` is exempt inside `CommandGroup(`/`CommandMenu(` blocks only.
func offenders<Output>(
  matching regex: Regex<Output>, under: [String], excluding: String? = nil, missingOK: [String] = []
) -> [String] {
  var hits: [String] = []
  for entry in under {
    if let gap = SourceScan.missingEntry(entry, missingOK) { hits.append(gap); continue }
    for file in SourceScan.swiftFiles(under: entry) {
      if let excluding, file.path.contains(excluding) { continue }
      let lines = SourceScan.lines(of: file)
      let menuBar = lines.first?.trimmingCharacters(in: .whitespaces) == "// menu-bar"
      var depth = 0, inCommands = false
      for (i, line) in lines.enumerated() {
        if menuBar, !inCommands, line.contains("CommandGroup(") || line.contains("CommandMenu(") {
          inCommands = true; depth = 0
        }
        let exempt = inCommands
        if inCommands {
          depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
          if depth <= 0, line.contains("}") { inCommands = false }
        }
        // Match against this line plus the next two, so `Button` with its `{` or `(` on a later line is caught;
        // a hit counts for the line it starts on (later lines get their own turn).
        let window = lines[i..<min(i + 3, lines.count)].joined(separator: "\n")
        if !exempt, let hit = window.firstMatch(of: regex), hit.range.lowerBound < window.index(window.startIndex, offsetBy: line.count) {
          hits.append("\(file.path):\(i + 1)")
        }
      }
    }
  }
  return hits
}

/// "path:line" of each `ScrollView` in a file that never says `.scrollIndicators(.hidden)` (§6.0: no system scrollbars).
func scrollViewOffenders(under: [String], excluding: String? = nil, missingOK: [String] = []) -> [String] {
  var hits: [String] = []
  for entry in under {
    if let gap = SourceScan.missingEntry(entry, missingOK) { hits.append(gap); continue }
    for file in SourceScan.swiftFiles(under: entry) {
      if let excluding, file.path.contains(excluding) { continue }
      let lines = SourceScan.lines(of: file)
      if lines.contains(where: { $0.contains(".scrollIndicators(.hidden)") }) { continue }
      for (i, line) in lines.enumerated() where line.contains("ScrollView") {
        hits.append("\(file.path):\(i + 1)")
      }
    }
  }
  return hits
}
