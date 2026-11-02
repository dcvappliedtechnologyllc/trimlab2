// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TrimlabKit",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "TrimlabModel", targets: ["TrimlabModel"]),
    .library(name: "TrimlabMedia", targets: ["TrimlabMedia"]),
    .library(name: "TrimlabEditor", targets: ["TrimlabEditor"]),
  ],
  targets: [
    .target(name: "TrimlabModel"),
    // v1's HDR → SDR conversion, baked by scripts/make-hdr-lut.py (copied file by file so they sit at the bundle root).
    .target(name: "TrimlabMedia", dependencies: ["TrimlabModel"], exclude: ["Resources/LUT-PROVENANCE.txt"],
            resources: [.copy("Resources/hlg_to_sdr_v1.lut"), .copy("Resources/pq_to_sdr_v1.lut")]),
    .target(name: "TrimlabEditor", dependencies: ["TrimlabModel", "TrimlabMedia"]),
    .testTarget(name: "ModelTests", dependencies: ["TrimlabModel"], exclude: ["Golden"]),
    .testTarget(name: "MediaTests", dependencies: ["TrimlabModel", "TrimlabMedia"]),
    .testTarget(name: "EditorTests", dependencies: ["TrimlabModel", "TrimlabMedia", "TrimlabEditor"]),
  ],
  swiftLanguageModes: [.v6]
)
