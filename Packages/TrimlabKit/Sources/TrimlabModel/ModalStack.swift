/// Identifies an overlay or sheet on the modal stack.
public enum ModalID: Hashable, Sendable { case keyMap, exportSheet, ffmpegCard }

/// The open modals, in the order they were opened. The top is the most recently opened one (re-opening an
/// open modal moves it to the top). Tab is trapped inside the top modal's controls.
public struct ModalStack: Sendable {
  private struct Entry: Sendable {
    var id: ModalID
    var passKeys: Set<Command>
    var opener: String?
  }

  private var entries: [Entry] = []
  private var controls: [ModalID: [String]] = [:]

  public init() {}

  /// Opens `id`, or moves it to the top if already open (its original `opener` is kept, so Close returns
  /// focus to where the first open came from). `passKeys` are the commands that still reach the editor
  /// while this modal is on top.
  public mutating func open(_ id: ModalID, passKeys: Set<Command> = [], opener: String? = nil) {
    var opener = opener
    if let i = entries.firstIndex(where: { $0.id == id }) {
      opener = entries[i].opener ?? opener
      entries.remove(at: i)
    }
    entries.append(Entry(id: id, passKeys: passKeys, opener: opener))
  }

  /// Closes `id` and returns the id of the control that opened it (focus goes back there). A modal that
  /// is not open returns nil and changes nothing. Closing a modal under the top leaves the top as it was.
  @discardableResult
  public mutating func close(_ id: ModalID) -> String? {
    guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
    return entries.remove(at: i).opener
  }

  public var top: ModalID? { entries.last?.id }

  /// Whether `id` is open, on top or under another modal.
  public func contains(_ id: ModalID) -> Bool { entries.contains { $0.id == id } }

  /// The commands that pass through the top modal; empty when no modal is open.
  public var passKeys: Set<Command> { entries.last?.passKeys ?? [] }

  public mutating func register(_ controlIDs: [String], for id: ModalID) { controls[id] = controlIDs }

  public func tabOrder(for id: ModalID) -> [String] { controls[id] ?? [] }

  /// The control Tab (or Shift-Tab, `backwards`) moves to, cycling inside the top modal only. From nil or
  /// from a control outside the top modal it returns the first (backwards: last) control. Nil when no
  /// modal is open or the top has no controls.
  public func next(after current: String?, backwards: Bool) -> String? {
    guard let top, let order = controls[top], !order.isEmpty else { return nil }
    guard let current, let i = order.firstIndex(of: current) else {
      return backwards ? order.last : order.first
    }
    let n = order.count
    return order[backwards ? (i + n - 1) % n : (i + 1) % n]
  }
}
