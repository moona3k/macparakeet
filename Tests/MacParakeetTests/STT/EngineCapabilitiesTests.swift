import XCTest
@testable import MacParakeetCore

final class EngineCapabilitiesTests: XCTestCase {
    func testRegistryHasOneRowForEveryEngineVariant() {
        XCTAssertEqual(
            Set(EngineCapabilityRegistry.all.map(\.key)),
            Set(EngineVariantKey.allCases)
        )
    }

    func testRegistryLookupIsTotalForEveryEngineVariant() {
        for key in EngineVariantKey.allCases {
            XCTAssertNotNil(
                EngineCapabilityRegistry.capabilitiesIfPresent(for: key),
                "Missing capabilities row for \(key)"
            )
        }
    }

    func testNativeLiveDictationClaimsMatchNativeStreamingVariants() {
        let liveKeys = Set(EngineVariantKey.allCases.filter {
            EngineCapabilityRegistry.capabilities(for: $0).supportsNativeLiveDictation
        })

        XCTAssertEqual(liveKeys, [
            .parakeet(.unified),
            .nemotron(.multilingual1120),
            .nemotron(.english1120),
        ])
    }

    func testCapabilityFactsPreserveCurrentEngineContracts() {
        let parakeetV3 = EngineCapabilityRegistry.capabilities(for: .parakeet(.v3))
        XCTAssertTrue(parakeetV3.supportsTailPreview)
        XCTAssertTrue(parakeetV3.providesWordTimestamps)
        XCTAssertEqual(parakeetV3.supportedLanguages.mode, .automatic)
        XCTAssertEqual(parakeetV3.telemetryIdentity.modelKind, .parakeetSTT)
        XCTAssertEqual(parakeetV3.telemetryIdentity.engineVariant, .fixed("v3"))

        let parakeetUnified = EngineCapabilityRegistry.capabilities(for: .parakeet(.unified))
        XCTAssertFalse(parakeetUnified.supportsTailPreview)
        XCTAssertFalse(parakeetUnified.providesWordTimestamps)
        XCTAssertEqual(parakeetUnified.supportedLanguages, .fixed("en"))

        let whisper = EngineCapabilityRegistry.capabilities(for: .whisper(.largeV3Turbo632MB))
        XCTAssertTrue(whisper.supportsTailPreview)
        XCTAssertTrue(whisper.providesWordTimestamps)
        XCTAssertEqual(whisper.supportedLanguages.mode, .selectable)
        XCTAssertEqual(whisper.modelLifecycle.variantID, WhisperModelVariant.largeV3Turbo632MB.rawValue)

        let cohere = EngineCapabilityRegistry.capabilities(for: .cohere)
        XCTAssertFalse(cohere.supportsTailPreview)
        XCTAssertFalse(cohere.providesWordTimestamps)
        XCTAssertEqual(cohere.supportedLanguages.mode, .selectable)
        XCTAssertEqual(cohere.modelLifecycle.minimumMemoryBytes, 16 * 1024 * 1024 * 1024)
        XCTAssertEqual(cohere.telemetryIdentity.engineVariant, .cohereComputePolicy)
    }

    func testWhisperVariantSetIsClosed() {
        XCTAssertEqual(WhisperModelVariant.allCases, [.largeV3Turbo632MB])
        XCTAssertEqual(
            WhisperModelVariant.normalize("whisper-large-v3-v20240930-turbo-632MB"),
            .largeV3Turbo632MB
        )
        XCTAssertNil(WhisperModelVariant.normalize("whisper-small"))
    }
}
