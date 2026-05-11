// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-stats", targets: ["ClaudeStats"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeStats",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "ClaudeStatsTests",
            dependencies: ["ClaudeStats"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
