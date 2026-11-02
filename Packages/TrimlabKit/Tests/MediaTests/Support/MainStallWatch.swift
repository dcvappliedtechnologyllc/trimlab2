import Foundation
import Synchronization
import Testing

/// Diagnostics: with `TRIMLAB_MAIN_STALL_DIR=<dir>`, a background thread pings the main queue every 100 ms and,
/// when a ping waits more than 2 s, samples this process into `<dir>` (once per stall, at most 5 times). Off
/// otherwise. It starts when its own test runs: in a parallel run that is within the first moments, since every
/// suite starts at once; with `--no-parallel` only at its turn, so stalls before it go unseen. Once started it
/// lives as long as the process.
@Suite struct MainStallWatch {
  static let dir = ProcessInfo.processInfo.environment["TRIMLAB_MAIN_STALL_DIR"]

  final class State: Sendable {
    let lastServed = Atomic<UInt64>(DispatchTime.now().uptimeNanoseconds)
    let samples = Atomic<Int>(0)
  }

  @Test(.enabled(if: dir != nil)) func watchMain() {
    guard let dir = Self.dir else { return }
    let state = State()
    let t = Thread {
      var inStall = false
      while true {
        DispatchQueue.main.async { state.lastServed.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed) }
        Thread.sleep(forTimeInterval: 0.1)
        let waited = Double(DispatchTime.now().uptimeNanoseconds - state.lastServed.load(ordering: .relaxed)) / 1e9
        if waited > 2, !inStall, state.samples.load(ordering: .relaxed) < 5 {
          inStall = true
          state.samples.add(1, ordering: .relaxed)
          let file = "\(dir)/main-\(getpid())-\(Int(Date().timeIntervalSince1970)).sample"
          FileHandle.standardError.write(Data("mainstall: main not served for \(waited) s → \(file)\n".utf8))
          let p = Process()
          p.executableURL = URL(filePath: "/usr/bin/sample")
          p.arguments = ["\(getpid())", "3", "-file", file]
          try? p.run()
        } else if waited < 0.5, inStall {
          FileHandle.standardError.write(Data("mainstall: main served again\n".utf8))
          inStall = false
        }
      }
    }
    t.qualityOfService = QualityOfService.userInteractive
    t.start()
  }
}
