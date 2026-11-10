// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LiquidBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LiquidBar", targets: ["LiquidBar"]),
        .executable(name: "LiquidBarFanControlDaemon", targets: ["LiquidBarFanControlDaemon"]),
    ],
    targets: [
        .executableTarget(
            name: "LiquidBar",
            dependencies: ["FanControlShared"],
            path: "Sources/LiquidBar"
        ),
        .target(name: "FanControlShared", path: "Sources/FanControlShared"),
        .executableTarget(name: "LiquidBarFanControlDaemon", dependencies: ["FanControlShared"],
                          path: "Sources/LiquidBarFanControlDaemon"),
        .testTarget(
            name: "LiquidBarTests",
            dependencies: ["LiquidBar", "FanControlShared", "LiquidBarFanControlDaemon"],
            path: "Tests/LiquidBarTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
