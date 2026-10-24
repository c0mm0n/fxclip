// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FxclipTelegram",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "fxclip-telegram", targets: ["fxclip-telegram"])],
    dependencies: [.package(path: "../Engine")],
    targets: [
        .target(name: "FxTelegram", dependencies: [.product(name: "FxEngine", package: "Engine")]),
        .executableTarget(name: "fxclip-telegram", dependencies: ["FxTelegram"]),
        .testTarget(name: "FxTelegramTests", dependencies: ["FxTelegram"]),
    ]
)
