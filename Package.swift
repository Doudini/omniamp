// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode: data races are compile errors, and main-actor code checks at run time that it really
// runs on the main thread.
let package = Package(
    name: "OmniAmp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OmniAmp", path: "Sources/OmniAmp"),
        .testTarget(name: "OmniAmpTests", dependencies: ["OmniAmp"], path: "Tests/OmniAmpTests"),
    ],
    swiftLanguageModes: [.v6]
)
