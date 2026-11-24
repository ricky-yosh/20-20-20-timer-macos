// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TimerCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TimerCore", targets: ["TimerCore"])
    ],
    targets: [
        .target(name: "TimerCore"),
        .testTarget(name: "TimerCoreTests", dependencies: ["TimerCore"])
    ]
)
