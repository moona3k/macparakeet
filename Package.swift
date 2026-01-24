// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacParakeet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacParakeet", targets: ["MacParakeet"]),
        .library(name: "MacParakeetCore", targets: ["MacParakeetCore"])
    ],
    dependencies: [
        // MLX for LLM inference
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main"),
        // GRDB for SQLite (history storage)
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        // Main GUI app
        .executableTarget(
            name: "MacParakeet",
            dependencies: ["MacParakeetCore"],
            path: "Sources/MacParakeet"
        ),
        // Shared core library
        .target(
            name: "MacParakeetCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MacParakeetCore"
        ),
        // Tests
        .testTarget(
            name: "MacParakeetTests",
            dependencies: ["MacParakeetCore"],
            path: "Tests/MacParakeetTests"
        )
    ]
)
