import XCTest
@testable import MacParakeetCore

/// Tests for `SpeechEnginePreference` (enum) and `SpeechEnginePreferences`
/// (the per-feature container introduced in Phase 2.2 Task 3). Task 1 sets up
/// the file with enum-case tests; Task 3 appends container + migration tests.
final class SpeechEnginePreferencesTests: XCTestCase {

    func testVibeVoiceCaseExistsAndHasDisplayName() {
        let pref: SpeechEnginePreference = .vibevoice
        XCTAssertEqual(pref.rawValue, "vibevoice")
        XCTAssertEqual(pref.displayName, "VibeVoice")
    }

    func testAllCasesIncludesVibeVoice() {
        let all = SpeechEnginePreference.allCases
        XCTAssertTrue(all.contains(.vibevoice))
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - FeatureEngineSelection

    func testFeatureSelectionGlobalEquality() {
        XCTAssertEqual(FeatureEngineSelection.global, FeatureEngineSelection.global)
    }

    func testFeatureSelectionSpecificEquality() {
        XCTAssertEqual(
            FeatureEngineSelection.specific(.whisper),
            FeatureEngineSelection.specific(.whisper)
        )
        XCTAssertNotEqual(
            FeatureEngineSelection.specific(.whisper),
            FeatureEngineSelection.specific(.parakeet)
        )
    }

    func testFeatureSelectionCodableRoundTrip() throws {
        let cases: [FeatureEngineSelection] = [.global, .specific(.parakeet), .specific(.vibevoice)]
        for selection in cases {
            let data = try JSONEncoder().encode(selection)
            let decoded = try JSONDecoder().decode(FeatureEngineSelection.self, from: data)
            XCTAssertEqual(decoded, selection)
        }
    }

    // MARK: - SpeechEnginePreferences resolution

    func testDefaultPreferencesAllFollowParakeet() {
        let prefs = SpeechEnginePreferences()
        XCTAssertEqual(prefs.global, .parakeet)
        XCTAssertEqual(prefs.dictation, .global)
        XCTAssertEqual(prefs.fileTranscription, .global)
        XCTAssertEqual(prefs.meetingRecording, .global)
        XCTAssertEqual(prefs.engine(for: .dictation), .parakeet)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .parakeet)
        XCTAssertEqual(prefs.engine(for: .meetingFinalize), .parakeet)
        XCTAssertEqual(prefs.engine(for: .meetingLiveChunk), .parakeet)
    }

    func testGlobalWhisperResolvesAllJobsToWhisper() {
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        XCTAssertEqual(prefs.engine(for: .dictation), .whisper)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .whisper)
        XCTAssertEqual(prefs.engine(for: .meetingFinalize), .whisper)
    }

    func testPerFeatureOverrideTrumpsGlobal() {
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.dictation = .specific(.parakeet)
        prefs.meetingRecording = .specific(.vibevoice)
        XCTAssertEqual(prefs.engine(for: .dictation), .parakeet)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .whisper)
        XCTAssertEqual(prefs.engine(for: .meetingFinalize), .vibevoice)
        XCTAssertEqual(prefs.engine(for: .meetingLiveChunk), .vibevoice)
    }

    // MARK: - Persistence and migration

    func testRoundTripPersistsAllFields() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.dictation = .specific(.parakeet)
        prefs.meetingRecording = .specific(.vibevoice)
        prefs.save(to: defaults)

        let loaded = SpeechEnginePreferences.current(defaults: defaults)
        XCTAssertEqual(loaded, prefs)
    }

    func testMigratesFromLegacySingleEnginePreference() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // Simulate a pre-Phase-2.2 user: only the old single key is set
        defaults.set("whisper", forKey: SpeechEnginePreference.defaultsKey)

        let loaded = SpeechEnginePreferences.current(defaults: defaults)

        // Migration: global = old value, every per-feature = .global
        XCTAssertEqual(loaded.global, .whisper)
        XCTAssertEqual(loaded.dictation, .global)
        XCTAssertEqual(loaded.fileTranscription, .global)
        XCTAssertEqual(loaded.meetingRecording, .global)
    }

    func testMigrationDefaultsToParakeetWhenLegacyKeyMissing() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // No keys set at all
        let loaded = SpeechEnginePreferences.current(defaults: defaults)
        XCTAssertEqual(loaded.global, .parakeet)
        XCTAssertEqual(loaded.dictation, .global)
    }
}
