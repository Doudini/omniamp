// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OmniAmp",
    platforms: [.macOS(.v14)],
    targets: [
        // Complete concurrency checking in every build (Swift 6's data-race checks, as warnings; the language mode
        // stays Swift 5, so there are no runtime isolation traps). CI keeps the count at 0: scripts/concurrency-check.sh.
        .executableTarget(name: "OmniAmp", path: "Sources/OmniAmp",
                          swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "OmniAmpTests", dependencies: ["OmniAmp"], path: "Tests/OmniAmpTests"),
    ]
)
