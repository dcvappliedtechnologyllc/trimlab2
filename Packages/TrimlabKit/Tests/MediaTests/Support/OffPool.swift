import AVFoundation
import Foundation

/// Runs a blocking body on its own thread so it never occupies a Swift-concurrency cooperative-pool
/// thread. Test helpers that wait on child processes or `AVAssetReader` loops go through here;
/// a pool thread stuck in a synchronous wait starves the very work it waits for.
enum OffPool {
  static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let thread = Thread {
        continuation.resume(with: Result { try body() })
      }
      thread.stackSize = 4 << 20
      thread.start()
    }
  }

  /// One blocking `copyNextSampleBuffer()` on a GCD thread. Callers keep their own loop (and their
  /// `#expect`s, which need the test's task context) on the async side.
  static func nextSample(_ output: AVAssetReaderOutput) async -> CMSampleBuffer? {
    let box = UncheckedBox(output)
    let sample: UncheckedBox<CMSampleBuffer?> = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: UncheckedBox(box.value.copyNextSampleBuffer()))
      }
    }
    return sample.value
  }

  static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      let thread = Thread { continuation.resume(returning: body()) }
      thread.stackSize = 4 << 20
      thread.start()
    }
  }
}

/// Hands a non-Sendable value across the thread hop. Safe only where the caller awaits the hop
/// and touches the value from one thread at a time (as the reader helpers here do).
struct UncheckedBox<T>: @unchecked Sendable {
  let value: T
  init(_ value: T) { self.value = value }
}
