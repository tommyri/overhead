// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OverheadCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OverheadCore", targets: ["OverheadCore"]),
        .executable(name: "overhead", targets: ["overhead"]),
    ],
    targets: [
        .target(
            name: "OverheadCore",
            path: "Sources/OverheadCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "overhead",
            dependencies: ["OverheadCore"],
            path: "Sources/overhead",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OverheadCoreTests",
            dependencies: ["OverheadCore"],
            path: "Tests/OverheadCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
