import XCTest

/// Task 42 acceptance bench (§10), not part of the default schemes: run with the `trimlab-bench` scheme and the
/// `TEST_RUNNER_TRIMLAB_BENCH_*` variables below. Drives the real app (`TRIMLAB_BENCH_APP`, default the scheme's own),
/// always with `-TLExportFolder`, so it leaves the user's prefs alone.
///
///   TRIMLAB_BENCH_CLIPS   clip paths, separated by `|`
///   TRIMLAB_BENCH_OUT     the export folder
///   TRIMLAB_BENCH_PLAY    seconds to keep a Reel playing (the footprint / stall / nettop test)
///   TRIMLAB_BENCH_PLAY_AFTER  for `testPlayIdle`: the app starts playing by itself this many seconds after launch
@MainActor
final class BenchTests: XCTestCase {
  private var app: XCUIApplication!
  private static let env = ProcessInfo.processInfo.environment

  override func setUpWithError() throws {
    continueAfterFailure = false
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dcv.trimlab2")
    try XCTSkipUnless(running.isEmpty, "trimlab 2 is running; the bench would force-quit it.")
  }

  override func tearDownWithError() throws { app?.terminate() }

  private func launch() throws {
    let clips = (Self.env["TRIMLAB_BENCH_CLIPS"] ?? "").split(separator: "|").map(String.init)
    let out = try XCTUnwrap(Self.env["TRIMLAB_BENCH_OUT"], "set TEST_RUNNER_TRIMLAB_BENCH_OUT")
    try XCTSkipIf(clips.isEmpty, "set TEST_RUNNER_TRIMLAB_BENCH_CLIPS")
    if let path = Self.env["TRIMLAB_BENCH_APP"] { app = XCUIApplication(url: URL(filePath: path)) } else { app = XCUIApplication() }
    app.launchArguments = ["-TLOpen"] + clips + ["-TLExportFolder", out]
    if let after = Self.env["TRIMLAB_BENCH_PLAY_AFTER"] { app.launchArguments += ["-TLPlayAfter", after] }
    app.launch()
    let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'strip.tile.'"))
    XCTAssertTrue(tiles.element(boundBy: clips.count - 1).waitForExistence(timeout: 60), "all \(clips.count) clips reach the strip")
  }

  /// Sheet confirm (High is the default quality; the log's `export: spec` line says what ran) → `done.saved`.
  func testExportTimed() throws {
    try launch()
    XCTAssertTrue(app.descendants(matching: .any)["export-button"].waitForExistence(timeout: 20))
    app.typeKey("e", modifierFlags: .command)
    let confirm = app.descendants(matching: .any)["export-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    wait(for: [expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: confirm)], timeout: 60)
    let start = ContinuousClock.now
    confirm.click()
    XCTAssertTrue(app.descendants(matching: .any)["done.saved"].waitForExistence(timeout: 120))
    let d = ContinuousClock.now - start
    let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    NSLog("BENCH export confirm -> done.saved: %.3f s", seconds)
    print("BENCH export confirm -> done.saved: \(seconds) s")
  }

  /// Opens the Reel, plays it with Space, drags a strip tile partway through, and keeps playing for
  /// `TRIMLAB_BENCH_PLAY` seconds so footprint, stall count and nettop can be read from outside.
  func testPlayAndDrag() throws {
    try launch()
    let play = Double(Self.env["TRIMLAB_BENCH_PLAY"] ?? "") ?? 90
    let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'strip.tile.'"))
    Thread.sleep(forTimeInterval: 5)  // let the sprites land
    app.typeKey(" ", modifierFlags: [])
    NSLog("BENCH playing")
    Thread.sleep(forTimeInterval: 12)
    // By window coordinates, so the drag asks the app for one element (the window), not a tile snapshot.
    let window = app.windows.firstMatch
    let a = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.777))
    let b = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.777))
    a.press(forDuration: 0.3, thenDragTo: b)
    NSLog("BENCH dragged")
    Thread.sleep(forTimeInterval: play)
    NSLog("BENCH done")
  }

  /// The stall count with no injected input (Task 42 acceptance 2, miss 6): the app is launched and brought front
  /// as above, starts playing by itself (`-TLPlayAfter`), and the test only waits.
  /// It fails unless the transport's play button reads Pause. The app's `isolated run: playing` log line is checked
  /// from outside: the sandboxed runner can't read ~/Library/Logs.
  func testPlayIdle() throws {
    let after = try XCTUnwrap(Double(Self.env["TRIMLAB_BENCH_PLAY_AFTER"] ?? ""),
                              "set TEST_RUNNER_TRIMLAB_BENCH_PLAY_AFTER to a number of seconds")
    try launch()
    let play = Double(Self.env["TRIMLAB_BENCH_PLAY"] ?? "") ?? 90
    let pause = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Pause'")).firstMatch
    XCTAssertTrue(pause.waitForExistence(timeout: after + 30), "the app didn't start playing (-TLPlayAfter)")
    NSLog("BENCH idle")
    Thread.sleep(forTimeInterval: play)
    NSLog("BENCH done")
  }
}
