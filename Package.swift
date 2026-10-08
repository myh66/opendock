// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenDock", targets: ["OpenDock"])],
    targets: [
        .executableTarget(name: "OpenDock", path: "Sources/OpenDock"),
        .testTarget(name: "OpenDockTests", dependencies: ["OpenDock"], path: "Tests/OpenDockTests")
    ],
    swiftLanguageVersions: [.v5]
)
