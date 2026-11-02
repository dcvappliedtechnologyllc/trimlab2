import Foundation
import Synchronization
import Testing
@testable import TrimlabMedia

/// `ExportSlot.cancel` while the export is still being set up (review M-1).
@Suite struct ExportSlotTests {
  /// A body that waits for a cancel of its own task, then reports it.
  private final class Probe: Sendable {
    let token = Mutex<UUID?>(nil)
    let sawCancel = Mutex(false)
    let started = Mutex(false)
  }

  private func body(_ probe: Probe) -> @Sendable (UUID) async -> Void {
    { token in
      probe.token.withLock { $0 = token }
      probe.started.withLock { $0 = true }
      // Stands in for AVFoundation loads that only end when their task is cancelled.
      do { try await Task.sleep(for: .seconds(10)) } catch { probe.sawCancel.withLock { $0 = true } }
    }
  }

  private func waitStarted(_ probe: Probe) async throws {
    for _ in 0..<500 where !probe.started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    try #require(probe.started.withLock { $0 })
  }

  /// No handle yet: the setup task itself is cancelled, so a cancel during setup ends promptly as `.stopped`.
  @Test func cancelDuringSetupCancelsTheTask() async throws {
    let slot = ExportSlot<Int>()
    let probe = Probe()
    #expect(slot.start(body(probe)))
    try await waitStarted(probe)
    let t0 = ContinuousClock.now
    let outcome = await slot.cancel(upTo: .seconds(2), abort: { _ in })
    let wall = ContinuousClock.now - t0
    #expect(outcome == .stopped, "\(outcome) after \(wall)")
    #expect(wall < .seconds(1))
    #expect(probe.sawCancel.withLock { $0 })
  }

  /// Once the job exists, its own abort ends the export: the task is not cancelled under the job (read-gate design).
  @Test func cancelWithAHandleOnlyAborts() async throws {
    let slot = ExportSlot<Int>()
    let probe = Probe()
    #expect(slot.start(body(probe)))
    try await waitStarted(probe)
    let token = try #require(probe.token.withLock { $0 })
    #expect(!slot.attach(7, to: token))
    let aborted = Mutex<Int?>(nil)
    let outcome = await slot.cancel(upTo: .milliseconds(300), abort: { h in aborted.withLock { $0 = h } })
    #expect(aborted.withLock { $0 } == 7)
    #expect(outcome == .timedOut)
    #expect(!probe.sawCancel.withLock { $0 })
    slot.release(token)
  }
}
