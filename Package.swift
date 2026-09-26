// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OmniAmp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OmniAmp", path: "Sources/OmniAmp"),
        .testTarget(name: "OmniAmpTests", dependencies: ["OmniAmp"], path: "Tests/OmniAmpTests"),
    ]
)
