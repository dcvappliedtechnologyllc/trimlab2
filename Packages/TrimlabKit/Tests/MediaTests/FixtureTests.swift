import AVFoundation
import Foundation
import Testing

@Suite struct FixtureTests {
  static let names = [
    "portrait_hevc.mov", "rotated.mov", "landscape.mp4", "hlg.mov", "noaudio.mp4", "vfr.mp4",
    "odd.mp4", "over3.mp4", "spaced é/clip é 1.mov", "sixty.mp4", "mono44k.mov", "sample.mkv",
    "sample.avi", "theora.mkv", "keyframes.mp4", "tiny.mp4", "corrupt.mov", "notes.txt", "still.jpg", "dark.mp4",
    "bright.mp4",
  ]

  @Test(arguments: names) func fixturePresent(_ name: String) async throws {
    let url = try await Fixtures.url(name)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func allFixturesPresent() async throws {
    for name in Self.names { _ = try await Fixtures.url(name) }
  }

  @Test func oddIsOdd() async throws {
    let v = try #require(try await FFprobe.streams(Fixtures.url("odd.mp4")).first)
    #expect(v["width"] as? Int == 1079)
    #expect(v["height"] as? Int == 1917)
  }

  @Test func hlgIsTagged() async throws {
    let v = try #require(try await FFprobe.streams(Fixtures.url("hlg.mov")).first)
    #expect(v["color_transfer"] as? String == "arib-std-b67")
    #expect(v["pix_fmt"] as? String == "yuv420p10le")
    #expect(v["color_primaries"] as? String == "bt2020")
  }

  @Test func vfrHasTenFpsTail() async throws {
    let pts = try await FFprobe.frames(Fixtures.url("vfr.mp4")).map(\.ptsTime)
    let tail = zip(pts, pts.dropFirst()).filter { $0.0 > 2.05 }.map { $0.1 - $0.0 }
    #expect(tail.count > 5)
    for d in tail { #expect(abs(d - 0.1) < 0.01) }
  }

  @Test func keyframesEverySecond() async throws {
    let keys = try await FFprobe.frames(Fixtures.url("keyframes.mp4")).filter(\.keyFrame).map { Int($0.ptsTime.rounded()) }
    #expect(keys == [0, 1, 2, 3, 4, 5])
  }

  @Test func corruptHasNoMoovInPrefix() async throws {
    let atoms = try await FFprobe.atomOrder(Fixtures.url("portrait_hevc.mov"))
    #expect(atoms.last == "moov")
    let data = try await Data(contentsOf: Fixtures.url("corrupt.mov"))
    #expect(data.count == 65536)
    #expect(data.range(of: Data("moov".utf8)) == nil)
  }

  /// Feeds the Task 19 gate: in-memory luma vs ffprobe signalstats on the HLG clip.
  @Test func frameStatsMatchesSignalstatsOnHLG() async throws {
    let url = try await Fixtures.url("hlg.mov")
    let oracle = try await FFprobe.signalstats(url, at: 1.3)
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: 1.3, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    #expect(reader.startReading())
    let sample = try #require((await OffPool.nextSample(out)), "\(String(describing: reader.error))")
    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
    let mine = try #require(FrameStats.limitedLuma(buffer))
    #expect(abs(mine - oracle.yavg) / oracle.yavg < 0.03)
  }

  @Test func imageGeneratorDecodesHLG() async throws {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try await Fixtures.url("hlg.mov")))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (image, _) = try await generator.image(at: CMTime(seconds: 1.3, preferredTimescale: 600))
    #expect(image.width == 1080 && image.height == 1920)
  }

  @Test func signalstatsAgreeWithRawPlane() async throws {
    for (name, stddev) in [("noaudio.mp4", 55.95), ("hlg.mov", 66.58)] {
      let url = try await Fixtures.url(name)
      let stats = try await FFprobe.signalstats(url, at: 1.3)
      let tags = try await FFprobe.signalstatsTagYAVG(url, at: 1.3)
      #expect(abs(stats.yavg - tags) / tags < 0.005, "\(name) yavg \(stats.yavg) vs \(tags)")
      #expect(abs(stats.ystddev - stddev) / stddev < 0.01, "\(name) stddev \(stats.ystddev)")
    }
  }
}
