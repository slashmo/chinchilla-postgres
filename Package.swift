// swift-tools-version:5.8
import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "chinchilla-postgres",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ChinchillaPostgres", targets: ["ChinchillaPostgres"]),
    ],
    targets: [
        .target(name: "ChinchillaPostgres", swiftSettings: swiftSettings),
    ]
)
