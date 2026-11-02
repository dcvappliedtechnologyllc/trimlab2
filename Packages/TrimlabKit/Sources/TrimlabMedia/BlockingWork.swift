import Foundation
import Synchronization

/// Runs synchronous, blocking work (AVAssetReader sample loops, child-process waits) on its own thread
/// so it never occupies a Swift-concurrency cooperative-pool thread. A pool thread parked in a
/// synchronous wait starves the work it is waiting for.
enum BlockingWork {
  /// Set when the awaiting task is cancelled; the body polls it and throws `CancellationError`.
  final class Cancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func check() throws { if isCancelled { throw CancellationError() } }
  }

  static func run<T: Sendable>(_ body: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
    let cancellation = Cancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
          continuation.resume(with: Result { try body(cancellation) })
        }
        thread.stackSize = 4 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}
