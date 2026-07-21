// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "StowerFeature",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "StowerFeature", targets: ["StowerFeature"]),
        .library(name: "StowerData", targets: ["StowerData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", from: "1.26.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump.git", from: "1.6.1"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.14.1"),
        .package(url: "https://github.com/pointfreeco/sqlite-data.git", from: "1.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // Remove this revision pin once SwiftSoup releases the Swift 6.4 optimizer fix after 2.13.6.
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            revision: "8d6ad267714cac3ae747cefdd21f7a6665006e1f"
        ),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "StowerData",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "Sources/StowerData"
        ),
        .target(
            name: "StowerFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "StowerData",
            ],
            path: "Sources/StowerFeatureV2",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "StowerFeatureTests",
            dependencies: [
                "StowerFeature",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ],
            path: "Tests/StowerFeatureV2Tests"
        ),
    ]
)
