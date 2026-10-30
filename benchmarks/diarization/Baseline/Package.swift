// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacParakeetDiarizationBaseline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "diarization-baseline", targets: ["DiarizationBaseline"])],
    dependencies: [
        // Separate resolution is necessary: the app now resolves 0.17.4.
        // The disabled TTS text-normalization trait has no diarization effect.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.7", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "DiarizationBaseline",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
