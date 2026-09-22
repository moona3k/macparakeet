// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CustomVocabPhase0Probe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "custom-vocab-phase0-probe", targets: ["CustomVocabPhase0Probe"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.4")
    ],
    targets: [
        .executableTarget(
            name: "CustomVocabPhase0Probe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
