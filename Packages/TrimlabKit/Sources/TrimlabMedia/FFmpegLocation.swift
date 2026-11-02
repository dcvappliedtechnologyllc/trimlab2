import Foundation

/// Where ffmpeg lives. Used only to remux .mkv/.avi to .mov (§2); never in the export path.
public struct FFmpegLocation: Sendable, Equatable {
  public var ffmpeg: URL

  public init(ffmpeg: URL) { self.ffmpeg = ffmpeg }

  public static let searchPaths = ["/opt/homebrew/opt/ffmpeg-full/bin", "/opt/homebrew/bin", "/usr/local/bin"]

  /// The first search path that holds an executable `ffmpeg`.
  public static func find(
    in paths: [String] = searchPaths,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> FFmpegLocation? {
    for dir in paths {
      let path = dir + "/ffmpeg"
      if isExecutable(path) { return FFmpegLocation(ffmpeg: URL(filePath: path)) }
    }
    return nil
  }
}
