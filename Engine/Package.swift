// swift-tools-version:5.9
import PackageDescription

// Link engine: no AppKit, so it also builds on Linux/Windows.
let package = Package(
    name: "FxEngine",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "FxEngine", targets: ["FxEngine"])],
    targets: [
        .target(name: "FxEngine"),
        .testTarget(name: "FxEngineTests", dependencies: ["FxEngine"]),
    ]
)
