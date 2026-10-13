// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElectricityCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ElectricityCore", targets: ["ElectricityCore"]),
        .library(name: "ElectricityReceipt", targets: ["ElectricityReceipt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ElectricityCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        // The receipt view and its PNG and print rendering (appendix R). SwiftUI, so kept out of the core.
        .target(
            name: "ElectricityReceipt",
            dependencies: ["ElectricityCore"]
        ),
        // Development-only tool for running ingestion against local logs. Not shipped.
        .executableTarget(
            name: "ElectricityDev",
            dependencies: ["ElectricityCore"]
        ),
        .testTarget(
            name: "ElectricityCoreTests",
            dependencies: ["ElectricityCore"],
            resources: [.copy("Fixtures")]
        ),
        // Reference images live in Snapshots/Receipt and are read by path, not bundled.
        .testTarget(
            name: "ElectricityReceiptTests",
            dependencies: ["ElectricityReceipt", "ElectricityCore"],
            exclude: ["Snapshots"]
        ),
    ]
)
