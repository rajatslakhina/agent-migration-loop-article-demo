// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MigrationLoop",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MigrationLoop", targets: ["MigrationLoop"])
    ],
    targets: [
        .target(name: "MigrationLoop"),
        .testTarget(name: "MigrationLoopTests", dependencies: ["MigrationLoop"])
    ]
)
