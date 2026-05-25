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
}
