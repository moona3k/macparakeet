// swift-tools-version: 5.9

import PackageDescription
import Foundation

let skipWhisperKit = ProcessInfo.processInfo.environment["MACPARAKEET_SKIP_WHISPERKIT"] == "1"
let enableMLXLocalLLM = ProcessInfo.processInfo.environment["MACPARAKEET_ENABLE_MLX_LOCAL_LLM"] == "1"

let packageDependencies: [Package.Dependency] = [
    // GRDB for SQLite (dictation history + transcription records)
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    // FluidAudio for Parakeet and Nemotron STT on CoreML/ANE
    .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.15.4")),
    // ArgumentParser for CLI
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    // Sparkle for auto-updates (non-App Store distribution)
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    // FluidAudio's Swift module exposes yyjson under current Xcode/Swift.
    .package(url: "https://github.com/ibireme/yyjson.git", exact: "0.12.0"),
    // WhisperKit for multilingual STT fallback (Korean + 95 other languages).
    // Argmax is not Swift 6 language-mode clean yet, so CI can omit this package
    // as a target dependency for the first-party Swift 6 syntax/concurrency
    // compile check without removing its lockfile pins.
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "0.18.0")
] + (enableMLXLocalLLM ? [
    // Opt-in only. mlx-swift-lm currently needs Swift tools 6.1 and Xcode-built
    // Metal shaders, so plain `swift build` / `swift test` / CI must not resolve it.
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
    .package(url: "https://github.com/huggingface/swift-transformers", "1.1.6" ..< "1.2.0"),
] : [])

let coreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "FluidAudio", package: "FluidAudio"),
    .product(name: "yyjson", package: "yyjson"),
    "MacParakeetObjCShims"
] + (skipWhisperKit ? [] : [
    .product(name: "WhisperKit", package: "argmax-oss-swift")
])

let whisperKitSwiftSettings: [SwiftSetting] = skipWhisperKit ? [] : [
    .define("MACPARAKEET_HAS_WHISPERKIT")
]

let mlxLocalLLMSwiftSettings: [SwiftSetting] = enableMLXLocalLLM ? [
    .define("MACPARAKEET_HAS_MLX_LOCAL_LLM")
] : []

let appDependencies: [Target.Dependency] = [
    "MacParakeetCore",
    "MacParakeetViewModels",
    .product(name: "Sparkle", package: "Sparkle")
] + (enableMLXLocalLLM ? [
    "MacParakeetLocalLLM"
] : [])

let appTestDependencies: [Target.Dependency] = [
    "MacParakeet",
    "MacParakeetCore",
    "MacParakeetViewModels",
    "MacParakeetObjCShims"
] + (enableMLXLocalLLM ? [
    "MacParakeetLocalLLM"
] : [])

let mlxLocalLLMTargets: [Target] = enableMLXLocalLLM ? [
    .target(
        name: "MacParakeetLocalLLM",
        dependencies: [
            "MacParakeetCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ],
        path: "Sources/MacParakeetLocalLLM",
        swiftSettings: mlxLocalLLMSwiftSettings
    )
] : []

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
    dependencies: packageDependencies,
    targets: [
        // Main GUI app
        .executableTarget(
            name: "MacParakeet",
            dependencies: appDependencies,
            path: "Sources/MacParakeet",
            resources: [.process("Resources")],
            swiftSettings: mlxLocalLLMSwiftSettings
        ),
        // macparakeet-cli — versioned public surface (semver, Sources/CLI/CHANGELOG.md).
        // Consumed by the macOS app, scripted callers, and downstream agent skills
        // (see /AGENTS.md and integrations/README.md).
        .executableTarget(
            name: "CLI",
            dependencies: [
                "MacParakeetCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CLI",
            exclude: ["CHANGELOG.md", "README.md"]
        ),
        // Objective-C shim target for catching NSException in Swift.
        // Swift's `do/try/catch` cannot catch Objective-C exceptions raised by
        // AppKit / AVFoundation / Core Audio — we need an @try/@catch trampoline
        // to convert them into Swift-throwable NSError values. See issue #91.
        .target(
            name: "MacParakeetObjCShims",
            path: "Sources/MacParakeetObjCShims",
            publicHeadersPath: "include"
        ),
        // Shared core library (no UI dependencies)
        .target(
            name: "MacParakeetCore",
            dependencies: coreDependencies,
            path: "Sources/MacParakeetCore",
            exclude: [
                "Audio/README.md",
                "Database/README.md",
                "Licensing/README.md",
                "Resources",
                "Services/System/README.md",
                "STT/README.md",
                "TextProcessing/README.md",
            ],
            swiftSettings: whisperKitSwiftSettings
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
            dependencies: appTestDependencies,
            path: "Tests/MacParakeetTests",
            swiftSettings: whisperKitSwiftSettings + mlxLocalLLMSwiftSettings
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI", "MacParakeetCore"],
            path: "Tests/CLITests"
        )
    ] + mlxLocalLLMTargets
)
