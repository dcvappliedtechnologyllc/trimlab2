import Foundation
import Synchronization
import TrimlabEditor
import TrimlabModel

/// Test double for the app's Mac services: scripted panel answers, every other call recorded.
final class StubPlatform: PlatformServices {
  struct State {
    var panelAnswer: [URL] = []
    var folderAnswer: URL?
    var revealed: [URL] = []
    var openedInQuickTime: [URL] = []
    var airDropped: [URL] = []
    var recents: [URL] = []
    /// Paths taken off Open Recent (`forgetRecent`), in order.
    var forgotten: [URL] = []
    /// What `modifierKeys()` reports: the keys "held" at the next press.
    var modifiers: Mods = []
    /// Every `copy` call's text, in order.
    var copied: [String] = []
  }
  let state = Mutex(State())
  let canAirDrop: Bool

  init(canAirDrop: Bool = true) { self.canAirDrop = canAirDrop }

  func openPanel(movies: Bool, projects: Bool) async -> [URL] { state.withLock { $0.panelAnswer } }
  func chooseFolder(start: URL?) async -> URL? { state.withLock { $0.folderAnswer } }
  func reveal(_ url: URL) { state.withLock { $0.revealed.append(url) } }
  func openInQuickTime(_ url: URL) { state.withLock { $0.openedInQuickTime.append(url) } }
  func airDrop(_ url: URL) { state.withLock { $0.airDropped.append(url) } }
  func noteRecent(_ url: URL) { state.withLock { $0.recents.append(url) } }
  func forgetRecent(_ url: URL) { state.withLock { $0.forgotten.append(url) } }
  func modifierKeys() -> Mods { state.withLock { $0.modifiers } }
  func canAirDrop(with url: URL) -> Bool { canAirDrop }
  func copy(_ text: String) { state.withLock { $0.copied.append(text) } }
  func hold(_ mods: Mods) { state.withLock { $0.modifiers = mods } }
}

/// A `Clock` that moves only when a test calls `advance(by:)`, so nothing in the tests really sleeps.
final class ManualClock: Clock {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
  }

  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }
  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
  }
  private let state = Mutex(State())

  var now: Instant { state.withLock { $0.now } }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
        let resumeNow: Bool = state.withLock { s in
          if deadline <= s.now { return true }
          s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
          return false
        }
        if resumeNow { c.resume() }
      }
    } onCancel: {
      let cancelled = state.withLock { s -> Sleeper? in
        guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return s.sleepers.remove(at: i)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Sleeps parked on the clock, not yet due: a deterministic "nothing can fire yet" check.
  var parkedSleepers: Int { state.withLock { $0.sleepers.count } }

  /// Returns once `n` sleeps are parked. A sleeper task may not have started yet when its deadline was read; this
  /// waits for it to get there (it must, since the clock only moves when a test moves it).
  func waitForParked(_ n: Int) async {
    while parkedSleepers < n { await Task.yield() }
  }

  func advance(by d: Duration) {
    let due = state.withLock { s -> [Sleeper] in
      s.now = s.now.advanced(by: d)
      let ready = s.sleepers.filter { $0.deadline <= s.now }
      s.sleepers.removeAll { $0.deadline <= s.now }
      return ready
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}
