import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class RetranscriptionEngineOptionTests: XCTestCase {

    func testIsAvailableReturnsTrueWhenNoReason() {
        let option = TranscriptionViewModel.RetranscriptionEngineOption(
            primaryEngine: SpeechEngineSelection(engine: .parakeet),
            alternativeEngines: [
                SpeechEngineSelection(engine: .whisper),
                SpeechEngineSelection(engine: .vibevoice)
            ],
            unavailableReasons: [:]
        )
        XCTAssertTrue(option.isAvailable(.whisper))
        XCTAssertTrue(option.isAvailable(.vibevoice))
    }

    func testIsAvailableReturnsFalseWhenReasonPresent() {
        let option = TranscriptionViewModel.RetranscriptionEngineOption(
            primaryEngine: SpeechEngineSelection(engine: .parakeet),
            alternativeEngines: [SpeechEngineSelection(engine: .vibevoice)],
            unavailableReasons: [.vibevoice: "Download the VibeVoice model"]
        )
        XCTAssertFalse(option.isAvailable(.vibevoice))
        XCTAssertEqual(option.unavailableReason(.vibevoice), "Download the VibeVoice model")
    }

    func testCurrentForJobKindRespectsPerFeatureOverride() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var prefs = SpeechEnginePreferences()
        prefs.global = .parakeet
        prefs.fileTranscription = .specific(.vibevoice)
        prefs.save(to: defaults)

        let selection = SpeechEngineSelection.current(for: .fileTranscription, defaults: defaults)
        XCTAssertEqual(selection.engine, .vibevoice)
    }

    func testCurrentForJobKindFallsBackToGlobalWhenNoOverride() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.save(to: defaults)

        let selection = SpeechEngineSelection.current(for: .fileTranscription, defaults: defaults)
        XCTAssertEqual(selection.engine, .whisper)
    }

    func testCurrentForJobKindLanguageNilForNonWhisperEngines() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        SpeechEnginePreference.saveWhisperDefaultLanguage("ja", defaults: defaults)
        var prefs = SpeechEnginePreferences()
        prefs.global = .vibevoice
        prefs.save(to: defaults)

        let selection = SpeechEngineSelection.current(for: .fileTranscription, defaults: defaults)
        XCTAssertEqual(selection.engine, .vibevoice)
        XCTAssertNil(selection.language)
    }
}
