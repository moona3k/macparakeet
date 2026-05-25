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

    func testColdSwitchOnlyAppliesToUnoptimizedActiveWhisperVariant() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveWhisperModelVariant("small", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .parakeet, defaults: defaults))
        XCTAssertTrue(SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults))

        SpeechEnginePreference.markWhisperOptimized(variant: "small", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults))
    }
}
