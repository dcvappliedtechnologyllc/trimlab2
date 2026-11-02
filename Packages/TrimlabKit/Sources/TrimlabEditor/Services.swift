import AVFoundation
import CoreGraphics
import Foundation
import TrimlabMedia
import TrimlabModel

/// §7.3. What the editor needs from the Mac. The app target supplies `MacPlatformServices`; tests use a stub.
public protocol PlatformServices: Sendable {
  func openPanel(movies: Bool, projects: Bool) async -> [URL]
  func chooseFolder(start: URL?) async -> URL?
  func reveal(_ url: URL)
  func openInQuickTime(_ url: URL)
  var canAirDrop: Bool { get }
  /// Whether AirDrop can send this file now (the Done view asks once it shows; hidden when it can't, §4.9).
  @MainActor func canAirDrop(with url: URL) -> Bool
  func airDrop(_ url: URL)
  func noteRecent(_ url: URL)
  /// Takes `url` off File › Open Recent: a Reel file renamed away from it (§6.1).
  func forgetRecent(_ url: URL)
  /// The modifier keys held right now (⇧ / ⌘ at a strip press). The app reads `NSEvent.modifierFlags`.
  @MainActor func modifierKeys() -> Mods
  /// Puts `text` on the clipboard (the Error view's Copy).
  func copy(_ text: String)
}

/// §7.3. Hosts the player's `AVPlayerLayer`; the app target's `PlayerSurface` is the macOS one.
public protocol PlayerSurfaceHost { func attach(_ player: AVPlayer) }

/// §5.3. What `EditorModel` asks of the preview: `PreviewEngine` is the real one (it conforms in
/// `LiveMediaServices.swift`); tests use a stub that records the calls.
@MainActor public protocol PreviewDriving: AnyObject {
  /// The player the stage shows.
  var player: AVPlayer { get }
  /// Builds and shows `plan` at Reel time `at`; coalesces to the latest call, at most one build in flight.
  func show(_ plan: CompositionPlan, assets: [UUID: AVURLAsset], at: RationalTime, play: Bool) async
  /// Exact, zero-tolerance seek in Reel time.
  func seek(_ t: RationalTime) async -> Bool
  /// 0 pauses; negative plays in reverse and stops at 0:00.
  func setRate(_ r: Double)
  var muted: Bool { get set }
  /// Loop Reel: wrap to 0:00 at the end instead of stopping.
  var loop: Bool { get set }
  var onTime: (@MainActor (RationalTime) -> Void)? { get set }
  /// Playback stopped by itself (the end with loop off, or 0:00 in reverse).
  var onEnd: (@MainActor () -> Void)? { get set }
}

/// Everything the editor asks of `TrimlabMedia`. `LiveMediaServices` is the real one.
public protocol MediaServices: Sendable {
  /// The dates that order a dropped batch (`ImportOrder`).
  func importItem(_ url: URL) async -> ImportItem
  /// Runs `Importer.playableURL` (remuxing .mkv/.avi into the cache), then `Prober.facts`. Throws the raw
  /// `ImportError` / `ProbeError`; the editor turns them into sentences.
  func probe(_ url: URL, ref: SourceRef) async throws -> ClipFacts
  /// The file's size and date, and its path relative to `projectFolder` when it lies inside it.
  func sourceRef(_ url: URL, projectFolder: URL?) throws -> SourceRef
  /// Thumbnails of `clip`'s file at `url` (`EditorModel.url(for:)`); the clip's `source` keys the cache.
  func poster(_ clip: ReelClip, at url: URL) async throws -> CGImage
  func sprite(_ clip: ReelClip, at url: URL) async throws -> Sprite
  func peaks(_ clip: ReelClip, at url: URL) async throws -> [Float16]
  /// The clip's sync-sample times (`MediaCache.keyframes`): where a Quick cut can start (§5.7).
  func keyframes(_ clip: ReelClip, at url: URL) async throws -> KeyframeIndex
  /// The clip's playable asset for the file at `url` (`EditorModel.url(for:)`; a cached remux for .mkv/.avi),
  /// with precise timing. The editor loads it once per file for the Reel's life.
  func asset(_ clip: ReelClip, at url: URL) async throws -> AVURLAsset
  /// What a Quick cut of `clip` would weigh (§5.5 step 8): the source's sample sizes in `range` (source time), its
  /// audio counted only when `includeAudio` (`QuickCut.sampleBytes`).
  func quickBytes(_ clip: ReelClip, at url: URL, range: Range<RationalTime>, includeAudio: Bool) async -> Int64
  func ffmpegAvailable() -> Bool
  func resolve(_ clip: ReelClip, projectFolder: URL?) -> URL?
  /// Trims the media cache to its size limit, never removing an entry for one of `refs` (the open Reel's clips).
  func pruneCache(keeping refs: [SourceRef]) async
  /// Runs one export of the frozen `reel` to `dest` (§5.5, `ExportRunner`), or a Quick cut of its one clip starting at
  /// the keyframe `quick` (§5.7, `QuickCut`). `sources`: the file each clip plays from. `replacing`: a file already at
  /// `dest` (never one of the Reel's, preflight saw to that) is replaced once the new one is complete, and kept if the
  /// export fails or is cancelled. The stream ends with the result, `CancellationError`, or `ExportFailed`.
  func export(reel: Reel, dest: URL, sources: [UUID: URL], quick: RationalTime?,
              replacing: Bool) -> AsyncThrowingStream<ExportEvent, Error>
  /// Stops the running export and deletes its partial; returns once that's done or after at most 2.5 s (Quit). true
  /// only when it stopped the export: false when nothing ran, the file was already being saved, or it timed out.
  @discardableResult func cancelExport() async -> Bool
  /// The media log's last `lines` lines (the Error view's Details).
  func recentLog(_ lines: Int) -> [String]
}

/// How an export's stream fails: the plain `ExportError` and, when the system reported one, the error it was mapped
/// from (domain, code, description) for the Details disclosure.
public struct ExportFailed: Error, Sendable {
  public let error: ExportError
  public let cause: ExportCause?

  public init(error: ExportError, cause: ExportCause?) {
    self.error = error
    self.cause = cause
  }
}

/// Reading and writing `.trimlab` files. `LiveProjectStore` writes through `ProjectFile` (atomic, and never over a
/// file holding another Reel, which is why `write` takes the Reel's id).
public protocol ProjectStore: Sendable {
  func write(_ data: Data, to url: URL, reelID: UUID) throws
  func read(_ url: URL) throws -> Data
  func isWritable(_ folder: URL) -> Bool
  func exists(_ url: URL) -> Bool
  func isFolder(_ url: URL) -> Bool
  /// The names directly inside `folder` (files and subfolders); empty when it isn't a folder.
  func list(_ folder: URL) -> [String]
  /// Creates `folder` (and any missing parents) if it isn't there: the `~/Movies/trimlab 2/` fallback.
  func makeFolder(_ folder: URL) throws
  /// Renames the file at `from` to `to` in the same folder (the Reel renamed, §6.1). Never replaces anything:
  /// `.taken` when a file, folder or link is at `to`, `.noFile` when nothing is at `from`.
  func move(_ from: URL, to: URL, reelID: UUID) throws(ProjectMoveError)
}
