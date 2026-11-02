import Foundation

/// Undo and redo for the whole Reel: snapshots of (Reel, Selection), capped at `limit`.
/// A gesture (a handle drag, a reorder drag, a held key) is one step: calls that share a
/// coalesce key are merged until `endGesture()`, and the first snapshot stands.
public struct History: Sendable {
  public static let limit = 200

  private var undoStack: [(Reel, Selection)] = []
  private var redoStack: [(Reel, Selection)] = []
  private var lastKey: String?

  public init() {}

  public var canUndo: Bool { !undoStack.isEmpty }
  public var canRedo: Bool { !redoStack.isEmpty }
  /// How many steps undo can take back.
  public var undoCount: Int { undoStack.count }

  /// Records the state from before an edit. A non-nil `coalesce` equal to the previous call's key
  /// (with no `endGesture()` between) is ignored, so a whole gesture undoes in one step.
  public mutating func record(_ before: Reel, _ sel: Selection, coalesce: String?) {
    if let key = coalesce, key == lastKey { return }
    lastKey = coalesce
    undoStack.append((before, sel))
    if undoStack.count > History.limit { undoStack.removeFirst(undoStack.count - History.limit) }
    redoStack.removeAll()
  }

  /// Ends the current gesture, so the next record starts a new step even with the same key.
  public mutating func endGesture() { lastKey = nil }

  public mutating func undo(current: (Reel, Selection)) -> (Reel, Selection)? {
    lastKey = nil
    guard let previous = undoStack.popLast() else { return nil }
    redoStack.append(current)
    return previous
  }

  public mutating func redo(current: (Reel, Selection)) -> (Reel, Selection)? {
    lastKey = nil
    guard let next = redoStack.popLast() else { return nil }
    undoStack.append(current)
    return next
  }

  /// Forgets everything, as when a Reel is opened.
  public mutating func reset() {
    undoStack.removeAll()
    redoStack.removeAll()
    lastKey = nil
  }
}
