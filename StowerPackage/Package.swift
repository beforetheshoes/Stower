// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StowerFeature",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "StowerFeature", targets: ["StowerFeature"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", from: "1.23.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.11.0"),
        .package(url: "https://github.com/pointfreeco/sqlite-data.git", from: "1.5.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "StowerData",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "Sources/StowerData"
        ),
        .target(
            name: "StowerFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                "StowerData",
            ],
            path: "Sources/StowerFeatureV2"
        ),
        .testTarget(
            name: "StowerFeatureTests",
            dependencies: ["StowerFeature", "StowerData"],
            path: "Tests/StowerFeatureV2Tests"
        ),
    ]
)
