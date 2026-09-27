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
        XCTAssertNil(MeetingAIOutputLanguagePolicy(configurationValue: "auto"))
        XCTAssertNil(MeetingAIOutputLanguagePolicy(configurationValue: "klingon"))
        XCTAssertNil(MeetingAIOutputLanguagePolicy(configurationValue: ""))
    }

    func testAcceptsEveryCatalogLanguageAndNormalizesAliases() {
        for language in WhisperLanguageCatalog.all {
            XCTAssertEqual(
                MeetingAIOutputLanguagePolicy(configurationValue: language.code),
                .language(language.code),
                "Catalog code \(language.code) should be accepted"
            )
        }
        XCTAssertEqual(MeetingAIOutputLanguagePolicy(configurationValue: "ko"), .language("ko"))
        XCTAssertEqual(MeetingAIOutputLanguagePolicy(configurationValue: "ko-KR"), .language("ko"))
        XCTAssertEqual(MeetingAIOutputLanguagePolicy(configurationValue: "Korean"), .language("ko"))
    }

    func testLanguageInstructionNamesTheLanguageInEnglish() {
        let korean = MeetingAIOutputLanguagePolicy.language("ko")
        XCTAssertEqual(korean.displayTitle, "Korean")
        XCTAssertTrue(korean.assemblyInstruction.hasPrefix("Write the result, including headings, in Korean."))
        XCTAssertTrue(korean.detail.contains("Korean"))
    }

    func testLegacyStoredLanguageCodesStillResolve() {
        for code in ["en", "pl", "de", "es", "fr", "pt", "ja", "zh"] {
            XCTAssertEqual(MeetingAIOutputLanguagePolicy(configurationValue: code), .language(code))
        }
    }

    func testCurrentFallsBackToTranscriptForMissingOrUnknownValues() {
        let suite = makeIsolatedDefaultsSuite("meeting-ai-language-")
        let defaults = UserDefaults(suiteName: suite)!

        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)

        defaults.set("follow-transcript", forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)

        defaults.set("not-a-policy", forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
        XCTAssertEqual(MeetingAIOutputLanguagePolicy.current(defaults: defaults), .followTranscript)
    }

    func testSaveRoundTripsThroughUserDefaults() {
        let suite = makeIsolatedDefaultsSuite("meeting-ai-language-")
        let defaults = UserDefaults(suiteName: suite)!

        MeetingAIOutputLanguagePolicy.save(.followTranscript, defaults: defaults)
        XCTAssertEqual(
            UserDefaultsAppRuntimePreferences(defaults: defaults).meetingAIOutputLanguagePolicy,
            .followTranscript
        )
    }
}
