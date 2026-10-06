// swift-tools-version:5.9
import PackageDescription

// SwiftPM builds and tests the core only; build.sh compiles the app with swiftc.
let package = Package(
    name: "PortBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PortCore"),
        .testTarget(name: "PortCoreTests", dependencies: ["PortCore"]),
    ]
)
