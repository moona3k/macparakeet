import XCTest
@testable import MacParakeetCore

final class SpeechEngineCapabilitiesTests: XCTestCase {
    func testRegistryHasOneRowForEveryEngineVariant() {
        XCTAssertEqual(
            Set(SpeechEngineCapabilityRegistry.all.map(\.key)),
            Set(SpeechEngineVariantKey.allCases)
        )
    }

    func testRegistryLookupIsTotalForEveryEngineVariant() {
        for key in SpeechEngineVariantKey.allCases {
            XCTAssertNotNil(
                SpeechEngineCapabilityRegistry.capabilitiesIfPresent(for: key),
                "Missing capabilities row for \(key)"
            )
        }
    }

    func testNativeLiveDictationClaimsMatchNativeStreamingVariants() {
        let liveKeys = Set(SpeechEngineVariantKey.allCases.filter {
            SpeechEngineCapabilityRegistry.capabilities(for: $0).supportsNativeLiveDictation
        })

        XCTAssertEqual(liveKeys, Set([
            .parakeet(.unified),
            .nemotron(.multilingual1120),
            .nemotron(.english1120),
        ]))
    }

    func testCustomVocabularyClaimsMatchParakeetTDTVariants() {
        let customVocabularyKeys = Set(SpeechEngineVariantKey.allCases.filter {
            SpeechEngineCapabilityRegistry.capabilities(for: $0).supportsCustomVocabulary
        })

        XCTAssertEqual(customVocabularyKeys, Set([
            .parakeet(.v2),
            .parakeet(.v3),
        ]))
    }

    func testCustomVocabularyPresentationReadsCapabilitySupport() {
        let tdtStatus = CustomVocabularyBoostingPresentation.status(
            for: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3))
        )
        XCTAssertEqual(tdtStatus.title, "Recognition boosting on")
        XCTAssertTrue(tdtStatus.detail.contains("Parakeet TDT"))

        let unifiedStatus = CustomVocabularyBoostingPresentation.status(
            for: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.unified))
        )
        XCTAssertEqual(unifiedStatus.title, "Clean corrections only")
        XCTAssertTrue(unifiedStatus.detail.contains("Parakeet English (Unified)"))

        let cohereStatus = CustomVocabularyBoostingPresentation.status(
            for: SpeechEngineCapabilityRegistry.capabilities(for: .cohere)
        )
        XCTAssertEqual(cohereStatus.title, "Clean corrections only")
        XCTAssertTrue(cohereStatus.detail.contains("Cohere"))
    }

    func testCustomVocabularyPresentationFallsBackToUnsupportedWhenCapabilitiesAreMissing() {
        let status = CustomVocabularyBoostingPresentation.status(for: Optional<SpeechEngineCapabilities>.none)

        XCTAssertEqual(status.title, "Clean corrections only")
        XCTAssertTrue(status.detail.contains("does not support recognition-time vocabulary boosting"))
    }

    func testCapabilityFactsPreserveCurrentEngineContracts() {
        let parakeetV3 = SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3))
        XCTAssertTrue(parakeetV3.supportsTailPreview)
        XCTAssertTrue(parakeetV3.providesWordTimestamps)
        XCTAssertTrue(parakeetV3.supportsCustomVocabulary)
        XCTAssertEqual(parakeetV3.supportedLanguages.mode, .automatic)
        XCTAssertEqual(parakeetV3.telemetryIdentity.modelKind, .parakeetSTT)
        XCTAssertEqual(parakeetV3.telemetryIdentity.engineVariant, .fixed("v3"))

        let parakeetUnified = SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.unified))
        XCTAssertFalse(parakeetUnified.supportsTailPreview)
        XCTAssertTrue(parakeetUnified.providesWordTimestamps)
        XCTAssertFalse(parakeetUnified.supportsCustomVocabulary)
        XCTAssertEqual(parakeetUnified.supportedLanguages, .fixed("en"))

        let whisper = SpeechEngineCapabilityRegistry.capabilities(for: .whisper(.largeV3Turbo632MB))
        XCTAssertTrue(whisper.supportsTailPreview)
        XCTAssertTrue(whisper.providesWordTimestamps)
        XCTAssertFalse(whisper.supportsCustomVocabulary)
        XCTAssertEqual(whisper.supportedLanguages.mode, .selectable)
        XCTAssertEqual(whisper.supportedLanguages.defaultLanguage, WhisperLanguageCatalog.autoCode)
        XCTAssertEqual(whisper.supportedLanguages.supportedLanguageCodes?.first, WhisperLanguageCatalog.autoCode)
        XCTAssertEqual(whisper.modelLifecycle.variantID, WhisperModelVariant.largeV3Turbo632MB.rawValue)

        let cohere = SpeechEngineCapabilityRegistry.capabilities(for: .cohere)
        XCTAssertFalse(cohere.supportsTailPreview)
        XCTAssertFalse(cohere.providesWordTimestamps)
        XCTAssertFalse(cohere.supportsCustomVocabulary)
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
