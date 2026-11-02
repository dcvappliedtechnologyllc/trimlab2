import AppKit
import AVFoundation
import SwiftUI
import TrimlabEditor

/// §7.3. The stage's player surface: a layer-backed `NSView` hosting an `AVPlayerLayer` (`.resizeAspect`, `--bg-0`
/// behind the video). No `AVPlayerView`: no system controls.
struct PlayerSurface: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.attach(player)
    return view
  }

  func updateNSView(_ view: PlayerLayerView, context: Context) { view.attach(player) }
}

/// The view `PlayerSurface` makes; `PlayerSurfaceHost` is how the player gets onto it.
final class PlayerLayerView: NSView, @MainActor PlayerSurfaceHost {
  private let playerLayer = AVPlayerLayer()
  /// Logs `first frame` once the layer first has a frame to show (§10 first item after launch).
  private var readyObservation: NSKeyValueObservation?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    let root = CALayer()
    root.backgroundColor = NSColor(Tokens.bg0).cgColor
    layer = root
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = NSColor(Tokens.bg0).cgColor
    root.addSublayer(playerLayer)
    readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
      guard change.newValue == true else { return }
      Task { @MainActor in FileLog.firstFrame() }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  func attach(_ player: AVPlayer) {
    if playerLayer.player !== player { playerLayer.player = player }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)  // the layer follows the view at once, no implicit animation
    playerLayer.frame = bounds
    CATransaction.commit()
  }
}
