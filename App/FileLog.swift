import AppKit
import Darwin
import Foundation
import OSLog
import Synchronization
import TrimlabEditor
import TrimlabMedia

/// §2 Logs: `os.Logger` (subsystem `com.dcv.trimlab2`, category `app`) plus the file the owner can read,
/// `~/Library/Logs/trimlab 2/trimlab.log` (`RotatingLog`, 1 MB × 3). The media layer's lines (`MediaLog`: each
/// export's spec, plan summary and settings, each remux's argv) reach the file through `MediaLog.setSink`; the app's
/// own lines (`app start`, `window shown`, `first frame` with their time since the process started, for the §10
/// launch targets, and `StallWatchdog`'s `stall`) through `note`. File writes go to one serial queue, never the main
/// thread; the last 30 lines also stay in memory for `tail` (the export Error view's Details), so it never waits.
enum FileLog {
  static let logger = Logger(subsystem: "com.dcv.trimlab2", category: "app")
  static let folder = URL.libraryDirectory.appending(path: "Logs/trimlab 2", directoryHint: .isDirectory)
  static let file = RotatingLog(dir: folder, name: "trimlab.log", limit: 1_000_000, keep: 3)
  private static let queue = DispatchQueue(label: "com.dcv.trimlab2.filelog", qos: .utility)
  private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

  /// Points the media log at the file and writes `app start`. Called first thing at launch.
  static func start() {
    MediaLog.setSink { line in write(line) }
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    note("app start: trimlab 2 \(version) (\(build)), \(os), pid \(getpid())\(sinceLaunch())")
  }

  /// An app line: to the os log and the file.
  static func note(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    write(message)
  }

  /// How many of the latest lines `tail` keeps in memory: the Error view's Details (`ExportFailure.logLines`).
  static let recentLimit = ExportFailure.logLines
  private static let recent = Mutex<[String]>([])

  /// The last `n` (at most `recentLimit`) lines written this run, oldest first, from memory: never waits on disk.
  static func tail(_ n: Int) -> [String] {
    recent.withLock { Array($0.suffix(max(n, 0))) }
  }

  private static func write(_ line: String) {
    let stamped = "\(stamp.format(Date.now)) \(line)"
    recent.withLock { lines in
      lines.append(stamped)
      if lines.count > recentLimit { lines.removeFirst(lines.count - recentLimit) }
    }
    queue.async { file.append(stamped) }
  }

  // MARK: launch milestones (§10 "cold launch to window < 1.0 s", "first item after launch")

  @MainActor private static var shown = false
  @MainActor private static var framed = false

  /// The main window is on screen: once per run.
  @MainActor static func windowShown() {
    guard !shown else { return }
    shown = true
    note("window shown\(sinceLaunch())")
  }

  /// The stage's player layer has its first frame to show: once per run.
  @MainActor static func firstFrame() {
    guard !framed else { return }
    framed = true
    note("first frame\(sinceLaunch())")
  }

  /// ", 412 ms after launch": the time since the kernel started this process (nothing when it can't be read).
  static func sinceLaunch() -> String {
    guard let start = processStart else { return "" }
    return ", \(Int((Date.now.timeIntervalSince(start) * 1000).rounded())) ms after launch"
  }

  private static let processStart: Date? = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
  }()
}

/// §10 "no main-thread work over 16 ms during playback or drags", in debug and release: two observers on the main
/// run loop time each pass from waking to the next wait, and any pass over 16 ms while the Reel plays or a drag is
/// on logs `stall <ms> ms`. A drag is the model's (a strip or deck press held, a reorder or Finder drop, a handle
/// trim) with a mouse button still down; the button is read only for a pass already over 16 ms, and a held button
/// with no model drag (a menu being tracked, a window resize) doesn't count.
@MainActor
final class StallWatchdog {
  static let threshold: UInt64 = 16_000_000  // ns

  private let model: EditorModel
  private var observers: [CFRunLoopObserver] = []
  /// When this pass woke (uptime ns); 0 while waiting.
  private var woke: UInt64 = 0
  /// Whether playback, or a model drag, was on as this pass woke.
  private var playingAtWake = false
  private var dragAtWake = false

  init(model: EditorModel) { self.model = model }

  func install() {
    guard observers.isEmpty else { return }
    // The wake observer runs before anything else in the pass, the wait observer after everything else.
    let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) {
      [weak self] _, _ in MainActor.assumeIsolated { self?.passBegan() }
    }
    let wait = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) {
      [weak self] _, _ in MainActor.assumeIsolated { self?.passEnded() }
    }
    for observer in [wake, wait].compactMap({ $0 }) {
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      observers.append(observer)
    }
  }

  /// Model state only: cheap enough for every pass.
  private var playing: Bool {
    if case .playing = model.playState { true } else { false }
  }

  private var modelDrag: Bool {
    model.pointerHeld || model.activeDrag != nil || model.draftReel != nil || model.deckGrab != nil
  }

  private func passBegan() {
    woke = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    playingAtWake = playing
    dragAtWake = modelDrag
  }

  private func passEnded() {
    guard woke != 0 else { return }
    let took = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- woke
    woke = 0
    guard took > Self.threshold else { return }
    let why: String
    if playingAtWake || playing {
      why = "playing"
    } else if dragAtWake || modelDrag, NSEvent.pressedMouseButtons != 0 {
      why = "dragging"
    } else {
      return
    }
    FileLog.note("stall \((took + 500_000) / 1_000_000) ms (\(why))")
  }
}
