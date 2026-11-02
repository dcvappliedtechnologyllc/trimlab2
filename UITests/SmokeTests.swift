import XCTest

/// Task 41: the real app, end to end. Two fixture clips open from the command line, ⌘E, Export, and "Saved." shows.
/// The app runs with `-TLExportFolder`, which also keeps the run out of the user's prefs, window frame and Open
/// Recent (`LaunchOverrides`); the clips are copied to a scratch folder so the project file lands there, not beside
/// the fixtures.
@MainActor
final class SmokeTests: XCTestCase {
  private var scratch: URL!
  private var app: XCUIApplication!

  /// The repo root, from this file's own path (`<root>/UITests/SmokeTests.swift`).
  private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  private static let fixtures = root.appending(path: "Packages/TrimlabKit/Tests/Fixtures", directoryHint: .isDirectory)

  override func setUpWithError() throws {
    continueAfterFailure = false
    // XCUIApplication.launch() force-quits any running copy of the app, so never start with one open.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dcv.trimlab2")
    try XCTSkipUnless(running.isEmpty, "trimlab 2 is running (pid \(running.first?.processIdentifier ?? 0)). Quit it first: the smoke test would force-quit it.")
    try Self.ensureFixtures()
    scratch = FileManager.default.temporaryDirectory
      .appending(path: "trimlab2-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    app?.terminate()
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  func testTwoClipsExportToSaved() throws {
    let fm = FileManager.default
    let clips = scratch.appending(path: "clips", directoryHint: .isDirectory)
    let out = scratch.appending(path: "out", directoryHint: .isDirectory)
    try fm.createDirectory(at: clips, withIntermediateDirectories: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    var paths: [String] = []
    for name in ["portrait_hevc.mov", "noaudio.mp4"] {
      let copy = clips.appending(path: name)
      try fm.copyItem(at: Self.fixtures.appending(path: name), to: copy)
      paths.append(copy.path)
    }

    app = XCUIApplication()
    app.launchArguments = ["-TLOpen"] + paths + ["-TLExportFolder", out.path]
    app.launch()

    let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'strip.tile.'"))
    XCTAssertTrue(tiles.element(boundBy: 1).waitForExistence(timeout: 30), "two clips should reach the strip")
    XCTAssertEqual(tiles.count, 2)

    // ⌘E, as the Export… button's hint says; the button itself is the proof the Reel is ready.
    XCTAssertTrue(app.descendants(matching: .any)["export-button"].waitForExistence(timeout: 10))
    app.typeKey("e", modifierFlags: .command)

    let confirm = app.descendants(matching: .any)["export-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10), "⌘E should open the export sheet")
    // Export refuses a click until the clips have loaded; the button says when it will take one.
    let ready = expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: confirm)
    wait(for: [ready], timeout: 30)
    confirm.click()

    XCTAssertTrue(app.descendants(matching: .any)["done.saved"].waitForExistence(timeout: 30), "export should end on Saved.")
    let files = try fm.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".mov") }
    XCTAssertEqual(files.count, 1, "one exported file in \(out.path); found \(files)")
    let size = try fm.attributesOfItem(atPath: out.appending(path: files[0]).path)[.size] as? Int ?? 0
    XCTAssertGreaterThan(size, 10_000)
  }

  /// Runs `scripts/make-fixtures.sh` when the fixtures it makes aren't there (a no-op when they are current). The
  /// runner is sandboxed and has a thin PATH, so if the script can't run here the test skips with the manual step.
  private static func ensureFixtures() throws {
    let needed = ["portrait_hevc.mov", "noaudio.mp4"]
    if needed.allSatisfy({ FileManager.default.fileExists(atPath: fixtures.appending(path: $0).path) }) { return }
    let hint = "Run scripts/make-fixtures.sh from a terminal, then re-run the smoke test."
    let p = Process()
    p.executableURL = URL(filePath: "/bin/zsh")
    p.arguments = [root.appending(path: "scripts/make-fixtures.sh").path]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    p.environment = env
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { throw XCTSkip("Could not start make-fixtures.sh (\(error)). \(hint)") }
    let deadline = Date().addingTimeInterval(180)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    if p.isRunning {
      p.terminate()
      throw XCTSkip("make-fixtures.sh took over 3 minutes. \(hint)")
    }
    guard p.terminationStatus == 0 else {
      let text = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
      throw XCTSkip("make-fixtures.sh failed (\(p.terminationStatus)): \(text.suffix(300)) \(hint)")
    }
  }
}
