import XCTest
@testable import MacParakeetCore

final class SpeechEnginePreferenceTests: XCTestCase {
    func testFriendlyVariantNameMapsDefaultWhisperVariant() {
        let raw = SpeechEnginePreference.defaultWhisperModelVariant
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName(raw), "Large v3 Turbo")
    }

    func testFriendlyVariantNameFallsBackToRawForUnknownShape() {
        XCTAssertEqual(
            SpeechEnginePreference.friendlyVariantName("large-v30-experimental-build"),
            "large-v30-experimental-build"
        )
    }

    func testEngineAlternativesPreserveStableParakeetToWhisperPath() {
        XCTAssertEqual(SpeechEnginePreference.parakeet.alternative, .whisper)
        XCTAssertEqual(SpeechEnginePreference.nemotron.alternative, .whisper)
        XCTAssertEqual(SpeechEnginePreference.whisper.alternative, .parakeet)
    }

    func testSTTRuntimeUsesInjectedDefaultsForSpeechEngineLanguages() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveNemotronDefaultLanguage("en_US", defaults: defaults)
        let nemotronRuntime = STTRuntime(speechEngine: .nemotron, defaults: defaults)
        let nemotronSelection = await nemotronRuntime.currentSpeechEngineSelection()
        XCTAssertEqual(nemotronSelection, SpeechEngineSelection(engine: .nemotron, language: "en-US"))

        SpeechEnginePreference.saveWhisperDefaultLanguage("KO_kr", defaults: defaults)
        let whisperRuntime = STTRuntime(speechEngine: .whisper, defaults: defaults)
        let whisperSelection = await whisperRuntime.currentSpeechEngineSelection()
        XCTAssertEqual(whisperSelection, SpeechEngineSelection(engine: .whisper, language: "ko"))
    }

    // MARK: - Whisper optimized-variant tracking

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "test.SpeechEnginePreference.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create isolated UserDefaults suite")
        }
        return (defaults, suite)
    }

    func testWhisperOptimizedDefaultsToFalse() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(
            SpeechEnginePreference.hasOptimizedWhisper(
                variant: SpeechEnginePreference.defaultWhisperModelVariant,
                defaults: defaults
            )
        )
    }

    func testMarkWhisperOptimizedRoundTrips() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let variant = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)

        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: variant, defaults: defaults))
    }

    func testMarkWhisperOptimizedIsIdempotent() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let variant = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)

        let stored = defaults.stringArray(forKey: SpeechEnginePreference.whisperOptimizedVariantsKey) ?? []
        XCTAssertEqual(stored, [variant])
    }

    func testWhisperOptimizedNormalizesVariantPrefix() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Marked with the "whisper-" prefix, queried without it (and vice versa).
        let bare = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: "whisper-\(bare)", defaults: defaults)

        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: bare, defaults: defaults))
    }

    func testWhisperOptimizedIsTrackedPerVariant() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.markWhisperOptimized(variant: "large-v3-turbo", defaults: defaults)

        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: "large-v3-turbo", defaults: defaults))
        XCTAssertFalse(SpeechEnginePreference.hasOptimizedWhisper(variant: "small", defaults: defaults))
    }

    func testClearWhisperOptimizedForgetsVariant() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let variant = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)
        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: variant, defaults: defaults))

        SpeechEnginePreference.clearWhisperOptimized(variant: variant, defaults: defaults)
        XCTAssertFalse(SpeechEnginePreference.hasOptimizedWhisper(variant: variant, defaults: defaults))
    }

    func testClearWhisperOptimizedLeavesOtherVariantsIntact() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.markWhisperOptimized(variant: "large-v3-turbo", defaults: defaults)
        SpeechEnginePreference.markWhisperOptimized(variant: "small", defaults: defaults)

        SpeechEnginePreference.clearWhisperOptimized(variant: "large-v3-turbo", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.hasOptimizedWhisper(variant: "large-v3-turbo", defaults: defaults))
        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: "small", defaults: defaults))
    }

    func testClearWhisperOptimizedIsIdempotentWhenAbsent() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // No-op when nothing was marked — must not crash or leave stray keys.
        SpeechEnginePreference.clearWhisperOptimized(variant: "small", defaults: defaults)
        XCTAssertNil(defaults.stringArray(forKey: SpeechEnginePreference.whisperOptimizedVariantsKey))
    }

    // MARK: - Parakeet model variant

    func testParakeetModelVariantDefaultsToMultilingualV3() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v3)
    }

    func testParakeetModelVariantRoundTrips() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveParakeetModelVariant(.v2, defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v2)

        SpeechEnginePreference.saveParakeetModelVariant(.v3, defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v3)
    }

    func testParakeetModelVariantFallsBackOnCorruptValue() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("nonsense", forKey: SpeechEnginePreference.parakeetModelVariantKey)
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v3)
    }

    func testParakeetModelVariantBridgesToAsrModelVersion() {
        XCTAssertEqual(ParakeetModelVariant.v3.asrModelVersion, .v3)
        XCTAssertEqual(ParakeetModelVariant.v2.asrModelVersion, .v2)
        XCTAssertEqual(ParakeetModelVariant(asrModelVersion: .v2), .v2)
        XCTAssertEqual(ParakeetModelVariant(asrModelVersion: .v3), .v3)
        // Specialized CJK builds collapse to the multilingual default rather
        // than crashing an exhaustive switch.
        XCTAssertEqual(ParakeetModelVariant(asrModelVersion: .tdtJa), .v3)
    }

    func testParakeetModelVariantEnglishOnlyFlag() {
        XCTAssertTrue(ParakeetModelVariant.v2.isEnglishOnly)
        XCTAssertFalse(ParakeetModelVariant.v3.isEnglishOnly)
        XCTAssertEqual(ParakeetModelVariant.v3.alternative, .v2)
        XCTAssertEqual(ParakeetModelVariant.v2.alternative, .v3)
    }

    // MARK: - Parakeet Unified variant (issue #520)

    func testParakeetUnifiedVariantRoundTrips() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveParakeetModelVariant(.unified, defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .unified)
        XCTAssertEqual(ParakeetModelVariant(rawValue: "unified"), .unified)
    }

    func testParakeetUnifiedHasNoAsrModelVersionAndUsesUnifiedEngine() {
        // Unified is a separate FluidAudio runtime — no TDT `AsrModelVersion`.
        XCTAssertNil(ParakeetModelVariant.unified.asrModelVersion)
        XCTAssertTrue(ParakeetModelVariant.unified.usesUnifiedEngine)
        XCTAssertFalse(ParakeetModelVariant.v2.usesUnifiedEngine)
        XCTAssertFalse(ParakeetModelVariant.v3.usesUnifiedEngine)
    }

    func testParakeetUnifiedIsEnglishOnlyAndListed() {
        XCTAssertTrue(ParakeetModelVariant.unified.isEnglishOnly)
        // Surfaced as a selectable Parakeet build everywhere `.allCases` drives a
        // picker (Settings, `models list`).
        XCTAssertTrue(ParakeetModelVariant.allCases.contains(.unified))
        XCTAssertEqual(ParakeetModelVariant.unified.modelName, "Parakeet Unified 0.6B")
    }

    func testSpeechModelVariantSummariesStayUserFacing() {
        XCTAssertEqual(
            ParakeetModelVariant.v3.coverageSummary,
            "Fast local default for English and supported European languages. Includes word timestamps."
        )
        XCTAssertEqual(
            ParakeetModelVariant.v2.coverageSummary,
            "English-only option for stable meetings and exports. Includes word timestamps."
        )
        XCTAssertEqual(
            ParakeetModelVariant.unified.coverageSummary,
            "Readable English with live preview. No word timestamps for exports."
        )
        XCTAssertEqual(
            NemotronModelVariant.multilingual1120.coverageSummary,
            "Beta multilingual live preview. Broader coverage, quality varies by language."
        )
        XCTAssertEqual(
            NemotronModelVariant.english1120.coverageSummary,
            "Beta English live preview. Quality is still being validated."
        )
    }

    // MARK: - Nemotron model variant

    func testNemotronModelVariantDefaultsToMultilingual1120() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SpeechEnginePreference.nemotronModelVariant(defaults: defaults), .multilingual1120)
    }

    func testNemotronModelVariantRoundTrips() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveNemotronModelVariant(.english1120, defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronModelVariant(defaults: defaults), .english1120)

        SpeechEnginePreference.saveNemotronModelVariant(.multilingual1120, defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronModelVariant(defaults: defaults), .multilingual1120)
    }

    func testNemotronModelVariantFallsBackOnCorruptValue() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("nonsense", forKey: SpeechEnginePreference.nemotronModelVariantKey)
        XCTAssertEqual(SpeechEnginePreference.nemotronModelVariant(defaults: defaults), .multilingual1120)
    }

    func testNemotronModelVariantFrozenContract() {
        // Raw values are persisted in UserDefaults and surfaced via the CLI
        // (`config set nemotron-model`) — renaming them silently orphans
        // stored preferences.
        XCTAssertEqual(NemotronModelVariant.multilingual1120.rawValue, "multilingual-1120ms")
        XCTAssertEqual(NemotronModelVariant.english1120.rawValue, "english-1120ms")
        XCTAssertTrue(NemotronModelVariant.english1120.isEnglishOnly)
        XCTAssertFalse(NemotronModelVariant.multilingual1120.isEnglishOnly)
        XCTAssertEqual(NemotronModelVariant.multilingual1120.chunkMilliseconds, 1120)
        XCTAssertEqual(NemotronModelVariant.english1120.chunkMilliseconds, 1120)
        XCTAssertEqual(NemotronModelVariant.multilingual1120.alternative, .english1120)
        XCTAssertEqual(NemotronModelVariant.english1120.alternative, .multilingual1120)
    }

    func testColdSwitchOnlyAppliesToUnoptimizedActiveWhisperVariant() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveWhisperModelVariant("small", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .parakeet, defaults: defaults))
        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .nemotron, defaults: defaults))
        XCTAssertTrue(SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults))

        SpeechEnginePreference.markWhisperOptimized(variant: "small", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults))
    }

    func testNemotronDefaultLanguageRoundTripsAndNormalizes() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults))

        SpeechEnginePreference.saveNemotronDefaultLanguage("en_US", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults), "en-US")

        SpeechEnginePreference.saveNemotronDefaultLanguage("zh_hant_tw", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults), "zh-Hant-TW")

        SpeechEnginePreference.saveNemotronDefaultLanguage("es_419", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults), "es-419")

        SpeechEnginePreference.saveNemotronDefaultLanguage("definitely-not-a-language", defaults: defaults)
        XCTAssertNil(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults))

        SpeechEnginePreference.saveNemotronDefaultLanguage("auto", defaults: defaults)
        XCTAssertNil(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults))
    }

    func testSpeechEngineSelectionCarriesNemotronLanguage() {
        XCTAssertEqual(
            SpeechEngineSelection(engine: .nemotron, language: "zh_CN"),
            SpeechEngineSelection(engine: .nemotron, language: "zh-CN")
        )
        XCTAssertNil(SpeechEngineSelection(engine: .parakeet, language: "ko").language)
    }
}
