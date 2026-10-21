// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MulticamStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MulticamStudio", targets: ["MulticamStudio"]),
        .executable(name: "mcstudio", targets: ["mcstudio"]),
        .library(name: "MulticamCore", targets: ["MulticamCore"]),
    ],
    targets: [
        .target(name: "MulticamCore", path: "Sources/MulticamCore"),
        .executableTarget(name: "MulticamStudio", dependencies: ["MulticamCore"], path: "Sources/MulticamStudio"),
        .executableTarget(name: "mcstudio", dependencies: ["MulticamCore"], path: "Sources/mcstudio"),
        .testTarget(name: "MulticamCoreTests", dependencies: ["MulticamCore"], path: "Tests/MulticamCoreTests"),
    ]
)
