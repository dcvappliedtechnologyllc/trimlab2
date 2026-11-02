import Foundation
import SwiftUI

/// Ties the Design controls' real keyboard focus to an owner's focus id: the model's `focusedControl`, which Tab
/// moves inside the top modal (`ModalStack.next`) and which a closing modal hands back to its opener (§4.10).
///
/// A control takes part when it's given an id (`tlFocusID`) under a link (`tlFocusLink`): when `current` becomes its
/// id it takes focus (and draws the 2 px gold ring); when it gets keyboard focus some other way (the system's Tab) it
/// reports its id through `set`, and lets it go (`set(nil)`) when it loses focus while the id is still its. A click that
/// focuses a control isn't keyboard focus: no ring, nothing reported.
public struct TLFocusLink {
  public var current: String?
  /// Whether the owner's focus should show its ring (false after a modal closed with the mouse handed focus back).
  public var ring: Bool
  public var set: @MainActor (String?) -> Void

  public init(current: String?, ring: Bool = true, set: @escaping @MainActor (String?) -> Void) {
    self.current = current
    self.ring = ring
    self.set = set
  }
}

extension EnvironmentValues {
  @Entry var tlFocusLink: TLFocusLink? = nil
  @Entry var tlControlID: String? = nil
}

extension View {
  /// The focus id of the Design control in this view (one control per id).
  public func tlFocusID(_ id: String) -> some View { environment(\.tlControlID, id) }

  /// Links the Design controls under this view to an owner's focus id.
  public func tlFocusLink(_ link: TLFocusLink) -> some View { environment(\.tlFocusLink, link) }
}

/// How a control tells keyboard focus from a click's: focus that arrives within this long of a press on the same
/// control came from the pointer.
enum TLPointerFocus {
  static let window: TimeInterval = 0.5

  static func isKeyboard(focused: Bool, focusedAt: Date, pressedAt: Date) -> Bool {
    focused && abs(focusedAt.timeIntervalSince(pressedAt)) > window
  }

  /// Keyboard focus for a control that may be linked: focus the owner gave it is the owner's to call (`ring`), even
  /// when a click had focused it first; otherwise the press/focus timing decides.
  static func keyboard(focused: Bool, linked: Bool, ring: Bool, focusedAt: Date, pressedAt: Date) -> Bool {
    guard focused else { return false }
    return linked ? ring : isKeyboard(focused: focused, focusedAt: focusedAt, pressedAt: pressedAt)
  }
}

extension TLFocusLink? {
  /// Whether this link's focus id is `id`.
  func holds(_ id: String?) -> Bool { id != nil && self?.current == id }
}

/// Keeps a control's `FocusState` and the link in step (see `TLFocusLink`). `keyboard` is whether the control has
/// keyboard focus right now.
struct TLFocusSync: ViewModifier {
  let focused: FocusState<Bool>.Binding
  let keyboard: Bool

  @Environment(\.tlFocusLink) private var link
  @Environment(\.tlControlID) private var id

  func body(content: Content) -> some View {
    content
      .onChange(of: link?.current, initial: true) { old, new in
        guard let id, link != nil else { return }
        if new == id {
          if !focused.wrappedValue { focused.wrappedValue = true }
        } else if old == id, focused.wrappedValue {
          focused.wrappedValue = false  // the owner moved focus on, or let it go
        }
      }
      .onChange(of: keyboard) { _, now in
        guard let id, let link else { return }
        if now, link.current != id { link.set(id) }
        // Focus went elsewhere (a click, the system's Tab): the owner's id lets go, so it isn't grabbed back later.
        if !now, link.current == id { link.set(nil) }
      }
  }
}

extension View {
  func tlFocusSync(_ focused: FocusState<Bool>.Binding, keyboard: Bool) -> some View {
    modifier(TLFocusSync(focused: focused, keyboard: keyboard))
  }
}
