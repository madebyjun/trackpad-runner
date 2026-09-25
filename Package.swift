// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "trackpad-runner",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CMultitouch"),
        .target(name: "TrackpadRunnerCore"),
        .executableTarget(
            name: "trackpad-runner",
            dependencies: ["CMultitouch", "TrackpadRunnerCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
