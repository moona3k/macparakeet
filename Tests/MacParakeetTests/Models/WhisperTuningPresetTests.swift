import XCTest
@testable import MacParakeetCore

final class WhisperTuningPresetTests: XCTestCase {

    func testDefaultPresetMatchesWhisperEngineTuningDefault() {
        XCTAssertEqual(WhisperTuningPreset.default.tuning, WhisperEngineTuning())
    }

    func testCleanStudioHasStricterFilters() {
        let s = WhisperTuningPreset.cleanStudio.tuning
        let d = WhisperEngineTuning()
        XCTAssertGreaterThan(s.logProbThreshold, d.logProbThreshold,
                             "Clean Studio should be stricter (higher logProbThreshold)")
        XCTAssertGreaterThan(s.noSpeechThreshold, d.noSpeechThreshold,
                             "Clean Studio should be more aggressive about silence")
        XCTAssertLessThan(s.compressionRatioThreshold, d.compressionRatioThreshold,
                          "Clean Studio should catch repetitions more aggressively")
    }

    func testNoisyHasLoosenFilters() {
        let n = WhisperTuningPreset.noisy.tuning
        let d = WhisperEngineTuning()
        XCTAssertLessThan(n.logProbThreshold, d.logProbThreshold,
                          "Noisy preset should be more permissive")
        XCTAssertLessThan(n.noSpeechThreshold, d.noSpeechThreshold,
                          "Noisy preset should be less aggressive about silence")
    }

    func testReverseLookupFindsExactMatch() {
        for preset in WhisperTuningPreset.allCases where preset != .custom {
            let matched = WhisperTuningPreset.matching(preset.tuning)
            XCTAssertEqual(matched, preset,
                           "Reverse-lookup should round-trip for \(preset.displayName)")
        }
    }

    func testReverseLookupFallsBackToCustomForUnknown() {
        var tweaked = WhisperEngineTuning()
        tweaked.logProbThreshold = -1.234  // not a preset value
        XCTAssertEqual(WhisperTuningPreset.matching(tweaked), .custom)
    }

    func testEveryPresetHasNonEmptyDisplayNameAndSummary() {
        for preset in WhisperTuningPreset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty)
            XCTAssertFalse(preset.summary.isEmpty)
        }
    }

    /// Sanity: `temperature: 0.0` everywhere — non-zero temperature
    /// introduces hallucinations and is never the right default.
    func testAllPresetsKeepTemperatureAtZero() {
        for preset in WhisperTuningPreset.allCases where preset != .custom {
            XCTAssertEqual(preset.tuning.temperature, 0.0,
                           "\(preset.displayName) should keep temperature deterministic")
        }
    }
}
