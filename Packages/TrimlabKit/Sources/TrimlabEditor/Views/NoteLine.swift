import SwiftUI

/// The one-line note under the stage (§4.1, §4.12): the newest note, Inter 13, `--muted` for information and
/// `--err` for something that didn't happen. A click dismisses it; `EditorModel.note` removes it after `lifetime`
/// on the model's clock.
public struct NoteLine: View {
  public static let lifetime: Duration = .seconds(6)

  let note: Note
  let onDismiss: () -> Void

  public init(note: Note, onDismiss: @escaping () -> Void) {
    self.note = note
    self.onDismiss = onDismiss
  }

  public var body: some View {
    TLButton(style: .bare, label: note.text, action: onDismiss) {
      Text(note.text)
        .font(.tl(.inter(.regular), 13))
        .monospacedDigit()
        .foregroundStyle(note.kind == .error ? Tokens.err : Tokens.muted)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(minHeight: 18)
    }
  }
}
