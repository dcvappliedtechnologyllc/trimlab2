import Foundation
import TrimlabEditor

/// The app's one open-event queue (Task 39): `AppDelegate` feeds it, `TrimlabApp` attaches the model when the window
/// appears. The FIFO itself (`OpenBacklog`) lives in TrimlabEditor so it is tested there.
@MainActor
enum OpenQueue {
  private static let backlog = OpenBacklog()

  static func enqueue(_ urls: [URL]) { backlog.enqueue(urls) }

  static func attach(_ model: EditorModel) { backlog.attach { model.openExternally($0) } }

  /// `-TLOpen <path>…` on the command line feeds the same queue.
  static func enqueueLaunchArguments() { enqueue(OpenRouting.launchURLs(arguments: CommandLine.arguments)) }
}
