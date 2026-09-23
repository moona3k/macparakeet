import XCTest
@testable import MacParakeetCore

final class MeetingAIOutputLanguagePolicyTests: XCTestCase {
    func testDefaultFollowsTranscript() {
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.default, .followTranscript)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.default.configurationValue, "follow-transcript")
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

    func testCurrentFallsBackToTranscriptForMissingOrUnknownValues() {
        let suite = "meeting-ai-language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)

        defaults.set("follow-transcript", forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)

        defaults.set("not-a-policy", forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)
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
