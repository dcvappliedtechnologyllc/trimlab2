import SwiftUI

extension EnvironmentValues {
  /// True while a view is drawn into a still (`ImageRenderer` screens, Task 38) rather than a window. Pieces a still
  /// can't draw, the Finder drop targets, which render as SwiftUI's can't-render placeholder, are left out.
  @Entry var tlStillRender: Bool = false
  /// In a still only: the focus id (`tlFocusID`) of the control drawn as if the pointer rested on it, so its tooltip
  /// shows (a still has no hover). Ignored outside stills.
  @Entry var tlStillHover: String? = nil
}

/// Finder drops onto a view, left out of stills (`tlStillRender`).
struct FinderDropTarget: ViewModifier {
  let model: EditorModel
  let overStrip: Bool
  @Environment(\.tlStillRender) private var still

  func body(content: Content) -> some View {
    if still {
      content
    } else {
      content.onDrop(of: [.fileURL], delegate: FinderDropDelegate(model: model, overStrip: overStrip))
    }
  }
}
