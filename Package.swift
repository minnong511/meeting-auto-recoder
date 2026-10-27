// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
               .executable(name: "MeetingRecorderMCP", targets: ["MeetingRecorderMCP"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")
    ],
    targets: [
        .target(name: "RecorderCore"),
        .target(name: "RecorderAudio", dependencies: ["RecorderCore", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        .executableTarget(name: "MeetingRecorder", dependencies: ["RecorderCore", "RecorderAudio"]),
        .executableTarget(name: "MeetingRecorderMCP", dependencies: ["RecorderCore"]),
        .executableTarget(name: "RecorderChecks", dependencies: ["RecorderCore", "RecorderAudio", .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        .executableTarget(name: "ASRBenchmark", dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "argmax-oss-swift")])
    ],
    swiftLanguageModes: [.v5]
)
