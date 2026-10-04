// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMOverviewCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LLMOverviewCore", targets: ["LLMOverviewCore"]),
        .executable(name: "llmo", targets: ["llmo"]),
    ],
    targets: [
        .target(
            name: "LLMOverviewCore",
            path: "Sources/LLMOverviewCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "llmo",
            dependencies: ["LLMOverviewCore"],
            path: "Sources/llmo",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LLMOverviewCoreTests",
            dependencies: ["LLMOverviewCore"],
            path: "Tests/LLMOverviewCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
