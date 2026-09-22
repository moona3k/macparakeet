// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceprintPhase0Harness",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "voiceprint-harness", targets: ["VoiceprintHarness"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", .exact("0.15.4"))
    ],
    targets: [
        .executableTarget(
            name: "VoiceprintHarness",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
