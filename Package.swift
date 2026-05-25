// swift-tools-version: 5.9

import PackageDescription
import Foundation

let skipWhisperKit = ProcessInfo.processInfo.environment["MACPARAKEET_SKIP_WHISPERKIT"] == "1"

let packageDependencies: [Package.Dependency] = [
    // GRDB for SQLite (dictation history + transcription records)
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    // FluidAudio for Parakeet STT on CoreML/ANE
    .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.14.5")),
    // ArgumentParser for CLI
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    // Sparkle for auto-updates (non-App Store distribution)
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
] + (skipWhisperKit ? [] : [
    // WhisperKit for multilingual STT fallback (Korean + 95 other languages).
    // Upgraded to v1.0.0 for Swift 6 compat and bug fixes, so CI can omit this package
    // only for the first-party Swift 6 syntax/concurrency compile check.
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.0.0")
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
        .library(name: "MacParakeetViewModels", targets: ["MacParakeetViewModels"]),
        .library(name: "VibeVoiceCore", targets: ["VibeVoiceCore"]),
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
        // CVibeVoice — exposes the vendored vibevoice_capi.h to Swift via a
        // module map. Contains only the module map + a stub .c; the real
        // library is built externally from vibevoice-spike/vibevoice.cpp/
        // (see docs/superpowers/plans/2026-05-25-vibevoice-swift-wrapper.md
        // for the integration plan and spike findings). The Swift sibling
        // target below links against the prebuilt static library via
        // linkerSettings.
        .target(
            name: "CVibeVoice",
            path: "Sources/VibeVoiceCore",
            exclude: [
                "DiarizedSegment.swift",
                "VibeVoiceASRError.swift",
                "VibeVoiceASR.swift",
            ],
            publicHeadersPath: "include"
        ),

        // VibeVoiceCore — Swift wrapper around the vibevoice.cpp C ABI.
        // Depends on CVibeVoice for the FFI surface; links against the
        // prebuilt libvibevoice.a + libggml*.dylib from the spike build.
        .target(
            name: "VibeVoiceCore",
            dependencies: ["CVibeVoice"],
            path: "Sources/VibeVoiceCore",
            exclude: [
                "include",
                "CVibeVoiceShim.c",
            ],
            // TEMPORARY (Phase 2.1): hard-coded paths to the spike build
            // output on the developer's local machine. These will be replaced
            // in Phase 2.5 with a build script (scripts/dev/build_vibevoice.sh)
            // and a sensible default install location. Do not assume these
            // paths exist on other machines.
            linkerSettings: [
                .unsafeFlags([
                    "-L", "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build",
                    "-L", "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build/third_party/ggml/src",
                    // Embed the same paths as rpath so the dynamic linker can resolve
                    // libggml*.dylib at xctest / app runtime without needing symlinks
                    // in .build/. Mirrors the -L pair above.
                    // SPM passes unsafeFlags to the Swift compiler driver, which
                    // requires -Xlinker per-token rather than the -Wl,... comma form.
                    "-Xlinker", "-rpath", "-Xlinker", "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build",
                    "-Xlinker", "-rpath", "-Xlinker", "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/vibevoice-spike/vibevoice.cpp/build/third_party/ggml/src",
                    "-lvibevoice",
                    "-lggml", "-lggml-base", "-lggml-cpu",
                    "-framework", "Metal",
                    "-framework", "MetalKit",
                    "-framework", "Foundation",
                    "-framework", "Accelerate",
                ]),
            ]
        ),
        // Shared core library (no UI dependencies)
        .target(
            name: "MacParakeetCore",
            dependencies: coreDependencies + ["VibeVoiceCore"],
            path: "Sources/MacParakeetCore",
            exclude: [
                "Audio/README.md",
                "Database/README.md",
                "Licensing/README.md",
                "Resources",
                "STT/README.md",
                "TextProcessing/README.md",
            ]
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
        ),
        .testTarget(
            name: "VibeVoiceCoreTests",
            dependencies: ["VibeVoiceCore"],
            path: "Tests/VibeVoiceCoreTests",
            resources: [.copy("Resources")]
        ),
    ]
)
