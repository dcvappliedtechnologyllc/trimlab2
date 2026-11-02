import AVFoundation
import Foundation

/// Drops the last reference to AVFoundation objects off the main thread. An `AVURLAsset` (and what holds one: a
/// composition, a player item) does real work as it goes — notification-centre removals that wait on a shared
/// AVFoundation queue — and a Reel's worth of them freed on the main actor froze it for seconds under load
/// (hang-report.md, main-actor stall). Hand them here instead of letting them die where they were held.
public enum Offload {
  /// Takes ownership of `value` and lets it go on a utility queue.
  public static func release<T: Sendable>(_ value: consuming T) {
    let box = Box(value)
    DispatchQueue.global(qos: .utility).async { box.drop() }
  }

  /// How long a player's or item's asset is kept after the player or item itself is let go.
  static let playerGrace = DispatchTimeInterval.seconds(2)

  /// Players and items: AVFoundation ends their lives with blocks on the main queue, so the player or item itself
  /// always dies on main. Their assets are what is costly to free, so they are held here past that and let go on
  /// a utility queue afterwards.
  @MainActor
  public static func release(players: [AVPlayer]) {
    release(items: players.compactMap(\.currentItem), also: players)
  }

  /// `release(players:)` for player items (and anything else, `also`, that holds them).
  @MainActor
  public static func release<T: Sendable>(items: [AVPlayerItem], also: consuming T) {
    let box = Box((items.map(\.asset), items, also))
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + playerGrace) { box.drop() }
  }

  @MainActor
  public static func release(item: AVPlayerItem?) {
    guard let item else { return }
    release(items: [item], also: ())
  }

  /// Only `drop` touches the value, once, on the queue it was handed to.
  private final class Box<T>: @unchecked Sendable {
    private var value: T?
    init(_ value: consuming T) { self.value = value }
    func drop() { value = nil }
  }
}
