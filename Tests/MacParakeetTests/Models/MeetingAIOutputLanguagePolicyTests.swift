import XCTest
@testable import MacParakeetCore

final class MeetingAIOutputLanguagePolicyTests: XCTestCase {
    func testDefaultIsEnglish() {
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.default, .language("en"))
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.default.configurationValue, "en")
    }

    func testParsesFollowTranscriptAndLanguageCodes() {
        XCTAssertEqual(
            MeetingAIOutputLanguagePolicy(configurationValue: "follow-transcript"),
            .followTranscript
        )
        XCTAssertEqual(
            MeetingAIOutputLanguagePolicy(configurationValue: "follow_transcript"),
            .followTranscript
        )
        XCTAssertEqual(MeetingAIOutputLanguagePolicy(configurationValue: "PL"), .language("pl"))
        XCTAssertNil(MeetingAIOutputLanguagePolicy(configurationValue: "ko"))
        XCTAssertNil(MeetingAIOutputLanguagePolicy(configurationValue: "auto"))
    }

    func testCurrentFallsBackToEnglishForMissingOrUnknownValues() {
        let suite = "meeting-ai-language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .english)

        defaults.set("follow-transcript", forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)

        defaults.set("not-a-policy", forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .english)
    }

    func testSaveRoundTripsThroughUserDefaults() {
        let suite = "meeting-ai-language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        MeetingAIOutputLanguagePolicy.save(.followTranscript, defaults: defaults)
        XCTAssertEqual(
            UserDefaultsAppRuntimePreferences(defaults: defaults).meetingAIOutputLanguagePolicy,
            .followTranscript
        )
    }
}
