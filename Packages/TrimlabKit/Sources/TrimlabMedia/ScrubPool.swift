import AVFoundation
import Foundation
import TrimlabModel

/// §5.3. One `AVPlayer` per recently peeked clip, on that clip's own asset, for peek and handle drags: the stage
/// shows a source frame without touching the Reel's composition. The least recently used player goes when a
/// fourth clip arrives.
@MainActor
public final class ScrubPool {
  public let capacity: Int
  private var entries: [(id: UUID, player: AVPlayer)] = []

  public init(capacity: Int = 3) { self.capacity = max(1, capacity) }

  /// The clip's player, made on first use (the item is made here, on the main actor). Most recent first.
  public func player(for clipID: UUID, asset: AVURLAsset) -> AVPlayer {
    if let i = entries.firstIndex(where: { $0.id == clipID }) {
      let hit = entries.remove(at: i)
      entries.insert(hit, at: 0)
      return hit.player
    }
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    player.automaticallyWaitsToMinimizeStalling = false
    player.isMuted = true
    entries.insert((clipID, player), at: 0)
    if entries.count > capacity {
      let evicted = entries.suffix(entries.count - capacity).map(\.player)
      entries.removeLast(entries.count - capacity)
      Offload.release(players: evicted)  // each holds its clip's asset: never the last reference on main
    }
    return player
  }

  /// Exact seek of the clip's player to source time `t`; nothing if the clip has no player.
  public func seek(_ clipID: UUID, to t: RationalTime) async {
    guard let player = entries.first(where: { $0.id == clipID })?.player else { return }
    _ = await player.seek(to: CMTime(t), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// The clips with a player, most recently used first.
  public var clipIDs: [UUID] { entries.map(\.id) }

  /// Drops every player off the main actor (`Offload`).
  public func removeAll() { Offload.release(players: takeAll()) }

  /// Every player, removed from the pool, for the caller to let go off the main actor.
  public func takeAll() -> [AVPlayer] {
    let players = entries.map(\.player)
    entries.removeAll()
    return players
  }
}
