// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PatternRecorder", platforms: [.macOS(.v13)], products: [.executable(name: "PatternRecorder", targets: ["PatternRecorder"])], targets: [.target(name: "RecorderCore"), .executableTarget(name: "PatternRecorder", dependencies: ["RecorderCore"]), .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"])], swiftLanguageModes: [.v5])
