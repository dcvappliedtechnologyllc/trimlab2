import Testing

/// Suites that composite whole Reels run one at a time: the §5.2 throughput gate must not be timed against an
/// export, and `ReelCompositor.sourceFrameObserver` is process-wide, so another suite's frames would land in it.
/// `.serialized` only orders tests inside one suite; this orders the suites carrying `.exclusiveMedia`.
struct ExclusiveMediaTrait: SuiteTrait, TestScoping {
  var isRecursive: Bool { false }

  func provideScope(for test: Test, testCase: Test.Case?,
                    performing function: @Sendable () async throws -> Void) async throws {
    await MediaTurnstile.shared.enter()
    do {
      try await function()
    } catch {
      await MediaTurnstile.shared.leave()
      throw error
    }
    await MediaTurnstile.shared.leave()
  }
}

extension Trait where Self == ExclusiveMediaTrait {
  static var exclusiveMedia: Self { Self() }
}

/// A FIFO async lock: one holder, waiters resumed in arrival order.
actor MediaTurnstile {
  static let shared = MediaTurnstile()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func enter() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func leave() {
    if waiters.isEmpty {
      held = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
