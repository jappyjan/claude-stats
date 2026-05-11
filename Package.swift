// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-stats", targets: ["ClaudeStats"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeStats",
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "ClaudeStatsTests",
            dependencies: ["ClaudeStats"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
