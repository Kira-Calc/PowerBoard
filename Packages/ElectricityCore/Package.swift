// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElectricityCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ElectricityCore", targets: ["ElectricityCore"]),
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
    ]
)
