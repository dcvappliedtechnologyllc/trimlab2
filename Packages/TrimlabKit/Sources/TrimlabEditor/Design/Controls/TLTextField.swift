import SwiftUI

/// v1's sheet field (§6.3): 30 px, radius 7, `--bg-0` with a 1 px `--line` edge that turns `--brand-gold` while it
/// has focus (the field's own focus mark, so no ring), Inter 13/500 `--text` with tabular digits, 10 px inside.
///
/// Each edit goes to the owner as it's typed (so the sheet's checks follow the name), and again on Return
/// (`onSubmit`), which reaches the field because the key monitor passes Return to a focused text field
/// (`EditorModel.handleKey`); Esc goes to the modal. While focused the field keeps what she typed, even when the
/// owner reads an empty name as its default.
public struct TLTextField: View {
  let label: String
  let value: String
  let onCommit: (String) -> Void
  let onSubmit: () -> Void

  @State private var draft = ""
  @FocusState private var focused: Bool

  public init(_ label: String, value: String, onCommit: @escaping (String) -> Void,
              onSubmit: @escaping () -> Void = {}) {
    self.label = label
    self.value = value
    self.onCommit = onCommit
    self.onSubmit = onSubmit
  }

  public static let height: CGFloat = 30

  /// A still can't draw the AppKit-backed field (it renders as the can't-render placeholder): the value as text.
  @Environment(\.tlStillRender) private var still

  public var body: some View {
    if still {
      Text(value)
        .font(.tl(.inter(.medium), 13))
        .monospacedDigit()
        .foregroundStyle(Tokens.text)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Chrome(focused: false))
    } else {
      field
    }
  }

  private var field: some View {
    TextField(label, text: $draft)
      .textFieldStyle(.plain)
      .labelsHidden()
      .font(.tl(.inter(.medium), 13))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .autocorrectionDisabled()
      .focused($focused)
      .focusEffectDisabled()
      .tlFocusSync($focused, keyboard: focused)  // a field's focus is the keyboard's however it came
      .onSubmit {
        commit()
        onSubmit()
      }
      .modifier(Chrome(focused: focused))
      .onAppear { draft = value }
      .onChange(of: draft) { commit() }
      .onChange(of: value) { _, now in
        // An emptied field reads as the default name; keep it empty while she's typing.
        if !(focused && draft.trimmingCharacters(in: .whitespaces).isEmpty) { draft = now }
      }
      .onChange(of: focused) { _, now in if !now { draft = value } }
      .accessibilityLabel(label)
  }

  private func commit() {
    if draft != value { onCommit(draft) }
  }
}

/// The field's well: 10 px inside, 30 px, `--bg-0`, the edge gold while focused.
private struct Chrome: ViewModifier {
  let focused: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 10)
      .frame(height: TLTextField.height)
      .background(Tokens.bg0, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(focused ? Tokens.brandGold : Tokens.line, lineWidth: 1))
  }
}

/// The header's inline rename (§6.1): `TLTextField`'s well, edge gold while focused (its own focus mark, no ring),
/// in the header name's type. Its owner holds the draft (each edit goes to `onEdit`) and decides when it ends: the
/// field takes focus from the owner's focus id (`tlFocusID` under a `TLFocusLink`, not SwiftUI's timing as it
/// appears), and the key monitor gives Return and Esc to the owner first. The field's own Return (`onSubmit`) and
/// Esc (`onExitCommand`) are a fallback to the same calls. Focus leaving it, or `focusReset` changing (a press on
/// the strip, deck or stage), commits as the pointer's. The owner ignores every call after the first.
public struct TLNameField: View {
  let label: String
  let value: String
  let focusReset: Int
  let onEdit: (String) -> Void
  let onCommit: (_ keyboard: Bool) -> Void
  let onCancel: (_ keyboard: Bool) -> Void

  @State private var draft: String
  @FocusState private var focused: Bool

  public init(_ label: String, value: String, focusReset: Int, onEdit: @escaping (String) -> Void,
              onCommit: @escaping (_ keyboard: Bool) -> Void, onCancel: @escaping (_ keyboard: Bool) -> Void) {
    self.label = label
    self.value = value
    self.focusReset = focusReset
    self.onEdit = onEdit
    self.onCommit = onCommit
    self.onCancel = onCancel
    _draft = State(initialValue: value)
  }

  public static let width: CGFloat = 240

  /// A still can't draw the AppKit-backed field: the draft as text in the focused well.
  @Environment(\.tlStillRender) private var still

  public var body: some View {
    Group {
      if still {
        Text(draft)
          .font(.tl(.inter(.medium), 13))
          .monospacedDigit()
          .foregroundStyle(Tokens.text)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .modifier(Chrome(focused: true))
      } else {
        field
      }
    }
    .frame(width: Self.width)
  }

  private var field: some View {
    TextField(label, text: $draft)
      .textFieldStyle(.plain)
      .labelsHidden()
      .font(.tl(.inter(.medium), 13))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .autocorrectionDisabled()
      .focused($focused)
      .focusEffectDisabled()
      .tlFocusSync($focused, keyboard: focused)  // takes focus when the owner's id is its own
      .onSubmit { onCommit(true) }
      .onExitCommand { onCancel(true) }
      .onChange(of: draft) { _, now in if now != value { onEdit(now) } }
      .onChange(of: focused) { was, now in if was, !now { onCommit(false) } }
      .onChange(of: focusReset) { onCommit(false) }
      .modifier(Chrome(focused: focused))
      .accessibilityLabel(label)
  }
}
