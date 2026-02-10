// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacParakeet",
    platforms: [
        // Note: SPM doesn't support patch-level versions for macOS 14, but the app
        // documents macOS 14.2+ and enforces it at runtime.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacParakeet", targets: ["MacParakeet"]),
        .executable(name: "macparakeet", targets: ["CLI"]),
        .library(name: "MacParakeetCore", targets: ["MacParakeetCore"]),
        .library(name: "MacParakeetViewModels", targets: ["MacParakeetViewModels"])
    ],
    dependencies: [
        // MLX-Swift for local LLM inference (Qwen3-4B)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.29.0"),
        // GRDB for SQLite (dictation history + transcription records)
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        // ArgumentParser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // Main GUI app
        .executableTarget(
            name: "MacParakeet",
            dependencies: ["MacParakeetCore", "MacParakeetViewModels"],
            path: "Sources/MacParakeet"
        ),
        // CLI tool for headless testing and scripting
        .executableTarget(
            name: "CLI",
            dependencies: [
                "MacParakeetCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CLI"
        ),
        // Shared core library (no UI dependencies)
        .target(
            name: "MacParakeetCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MacParakeetCore"
        ),
        // ViewModels library (testable, depends on Core + AppKit/SwiftUI)
        .target(
            name: "MacParakeetViewModels",
            dependencies: ["MacParakeetCore"],
            path: "Sources/MacParakeetViewModels"
        ),
        // Tests
        .testTarget(
            name: "MacParakeetTests",
            dependencies: ["MacParakeetCore", "MacParakeetViewModels"],
            path: "Tests/MacParakeetTests"
        )
    ]
)
