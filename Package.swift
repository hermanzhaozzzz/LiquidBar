// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LiquidBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LiquidBar", targets: ["LiquidBar"]),
    ],
    targets: [
        .executableTarget(
            name: "LiquidBar",
            path: "Sources/LiquidBar"
        ),
        .testTarget(
            name: "LiquidBarTests",
            dependencies: ["LiquidBar"],
            path: "Tests/LiquidBarTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
