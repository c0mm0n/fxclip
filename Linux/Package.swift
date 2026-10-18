// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FxClipLinux",
    platforms: [.macOS(.v13)], // Allows engine/unit checks on a development Mac.
    products: [.executable(name: "fxclip", targets: ["fxclip"])],
    dependencies: [.package(path: "../Engine")],
    targets: [
        .target(name: "FxClipCore", dependencies: [.product(name: "FxEngine", package: "Engine")]),
        .executableTarget(name: "fxclip", dependencies: ["FxClipCore"]),
        .testTarget(name: "FxClipCoreTests", dependencies: ["FxClipCore"]),
    ]
)
