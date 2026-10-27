// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PatternRecorder", platforms: [.macOS(.v13)], products: [.library(name: "RecorderCore", targets: ["RecorderCore"])], targets: [.target(name: "RecorderCore"), .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"])], swiftLanguageModes: [.v5])
