// swift-tools-version: 5.9

import PackageDescription
import Foundation

let skipWhisperKit = ProcessInfo.processInfo.environment["MACPARAKEET_SKIP_WHISPERKIT"] == "1"

let packageDependencies: [Package.Dependency] = [
    // GRDB for SQLite (dictation history + transcription records)
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    // FluidAudio for Parakeet STT on CoreML/ANE
    .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.14.1")),
    // ArgumentParser for CLI
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    // Sparkle for auto-updates (non-App Store distribution)
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
] + (skipWhisperKit ? [] : [
    // WhisperKit for multilingual STT fallback (Korean + 95 other languages).
    // Argmax is not Swift 6 language-mode clean yet, so CI can omit this package
    // only for the first-party Swift 6 syntax/concurrency compile check.
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "0.18.0")
])

let coreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "FluidAudio", package: "FluidAudio"),
    "MacParakeetObjCShims"
] + (skipWhisperKit ? [] : [
    .product(name: "WhisperKit", package: "argmax-oss-swift")
])

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
            dependencies: [
                "MacParakeetCore",
                "MacParakeetViewModels",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MacParakeet",
            resources: [.process("Resources")]
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
            exclude: ["CHANGELOG.md"]
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
            exclude: ["Resources"]
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
            dependencies: ["MacParakeet", "MacParakeetCore", "MacParakeetViewModels", "MacParakeetObjCShims"],
            path: "Tests/MacParakeetTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI", "MacParakeetCore"],
            path: "Tests/CLITests"
        )
    ]
)
