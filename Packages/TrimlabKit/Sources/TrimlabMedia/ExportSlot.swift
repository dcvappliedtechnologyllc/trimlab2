import Foundation
import Synchronization

/// The one export a runner (`ExportRunner`, `QuickCut`) runs at a time: claimed by `start`, its working handle (an
/// `ExportJob`, a passthrough session) attached once it exists, marked cancelled by `cancel`, claimed for the final
/// rename by `claimRename` (after which cancel is a no-op), and freed by `release`. Every call names the export by the
/// token `start` handed it, so a late call from an export that already ended never touches the next one.
///
/// Ownership: all of it is behind one `Mutex`; the handle is only handed out, never used under the lock.
final class ExportSlot<Handle: Sendable>: Sendable {
  private struct Active {
    let token: UUID
    var task: Task<Void, Never>?
    var handle: Handle?
    var cancelled = false
    /// Set once the export has finished writing and the rename is about to happen; cancel is then a no-op.
    var completing = false
  }

  private let active = Mutex<Active?>(nil)

  init() {}

  /// Claims the slot and runs `body` with the export's token; false (and `body` never runs) when one is running.
  func start(_ body: @escaping @Sendable (UUID) async -> Void) -> Bool {
    let token = UUID()
    return active.withLock { current -> Bool in
      if current != nil { return false }
      current = Active(token: token)
      // The task can't read the slot before this lock is let go, so it always finds itself there.
      current?.task = Task { await body(token) }
      return true
    }
  }

  /// Attaches the export's working handle. Returns true when the export was cancelled before it got one (or has
  /// already gone): the caller stops it at once.
  func attach(_ handle: Handle, to token: UUID) -> Bool {
    active.withLock { a -> Bool in
      guard a?.token == token else { return true }
      a?.handle = handle
      return a?.cancelled ?? true
    }
  }

  /// The export's current handle, if it has one.
  func handle(_ token: UUID) -> Handle? {
    active.withLock { $0?.token == token ? $0?.handle : nil }
  }

  /// Whether `cancel` has been asked of this export. `ifGone` answers for an export no longer in the slot.
  func isCancelled(_ token: UUID, ifGone: Bool) -> Bool {
    active.withLock { a -> Bool in
      guard let a, a.token == token else { return ifGone }
      return a.cancelled
    }
  }

  /// The rename is about to happen: true (and cancel becomes a no-op) unless the export was cancelled first.
  func claimRename(_ token: UUID) -> Bool {
    active.withLock { a -> Bool in
      guard a?.token == token, a?.cancelled == false else { return false }
      a?.completing = true
      return true
    }
  }

  /// Frees the slot, so the next export may start as soon as this one's stream ends.
  func release(_ token: UUID) {
    active.withLock { if $0?.token == token { $0 = nil } }
  }

  /// What `cancel` achieved.
  enum CancelOutcome: Equatable, Sendable {
    /// The export was stopped and has ended (its partial deleted).
    case stopped
    /// Nothing was running, or the export was already renaming its finished file: it wasn't stopped.
    case notRunning
    /// Asked to stop, but still tidying up at the limit (it finishes on its own).
    case timedOut
  }

  /// Marks the running export cancelled, hands its handle to `abort`, then waits for its task to end, at most `limit`.
  /// Before the export has a handle (it is still being set up: loading assets, building the composition) there is
  /// nothing to abort, so the task itself is cancelled and those loads stop; once there is a handle, only `abort`
  /// ends the export, never a task cancel under its job. An export already renaming isn't cancelled, but is still
  /// waited for (and reports `.notRunning`).
  @discardableResult
  func cancel(upTo limit: Duration, abort: (Handle) -> Void) async -> CancelOutcome {
    let (handle, task, asked) = active.withLock { a -> (Handle?, Task<Void, Never>?, Bool) in
      guard a != nil, a?.completing == false else { return (nil, a?.task, false) }
      a?.cancelled = true
      return (a?.handle, a?.task, true)
    }
    if let handle { abort(handle) } else if asked { task?.cancel() }
    guard let task else { return .notRunning }
    let ended = await Self.wait(for: task, upTo: limit)
    return !asked ? .notRunning : ended ? .stopped : .timedOut
  }

  /// true if `task` ended within `limit`.
  static func wait(for task: Task<Void, Never>, upTo limit: Duration) async -> Bool {
    await withCheckedContinuation { c in
      let once = ResumeOnce(c)
      let timer = Task {
        // A cancelled sleep returns early: the task ended first, so this must not report a timeout.
        try? await Task.sleep(for: limit)
        if !Task.isCancelled { once.resume(false) }
      }
      Task {
        await task.value
        once.resume(true)
        timer.cancel()
      }
    }
  }
}

/// Resumes a continuation at most once, from whichever caller gets there first.
private final class ResumeOnce: Sendable {
  let continuation: Mutex<CheckedContinuation<Bool, Never>?>
  init(_ c: CheckedContinuation<Bool, Never>) { continuation = Mutex(c) }
  func resume(_ value: Bool) { continuation.withLock { $0.take() }?.resume(returning: value) }
}
