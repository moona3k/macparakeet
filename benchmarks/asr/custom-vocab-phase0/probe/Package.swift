// swift-tools-version: 6.0
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
        .package(path: "../../../../.build/checkouts/FluidAudio")
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
