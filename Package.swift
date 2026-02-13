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
        .executable(name: "macparakeet-cli", targets: ["CLI"]),
        .library(name: "MacParakeetCore", targets: ["MacParakeetCore"]),
        .library(name: "MacParakeetViewModels", targets: ["MacParakeetViewModels"])
    ],
    dependencies: [
        // MLX-Swift for local LLM inference (Qwen3-8B)
        // Pin to 2.29.2: 2.29.3 has Xcode 16.1 parser breakage in Jamba.swift,
        // while 2.30.3 has a known Swift 6.1 LoRA compile regression.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.29.2"),
        // GRDB for SQLite (dictation history + transcription records)
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        // FluidAudio for Parakeet STT on CoreML/ANE
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.12.1")),
        // ArgumentParser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // Main GUI app
        .executableTarget(
            name: "MacParakeet",
            dependencies: ["MacParakeetCore", "MacParakeetViewModels"],
            path: "Sources/MacParakeet",
            resources: [.process("Resources")]
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
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
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
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI", "MacParakeetCore"],
            path: "Tests/CLITests"
        )
    ]
)
