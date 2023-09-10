// swift-tools-version:5.8
import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "chinchilla-postgres",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ChinchillaPostgres", targets: ["ChinchillaPostgres"]),
    ],
    dependencies: [
        .package(url: "https://github.com/slashmo/chinchilla.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ChinchillaPostgres",
            dependencies: [
                .product(name: "Chinchilla", package: "chinchilla"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "Integration",
            dependencies: [
                .target(name: "ChinchillaPostgres"),
                .product(name: "Chinchilla", package: "chinchilla"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
    ]
)
