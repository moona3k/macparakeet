import XCTest

@testable import MacParakeetCore

final class DictationTranslationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "test.dictation-translation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSettingsAreOffByDefaultAndDefaultToTypingTheTranslation() {
        XCTAssertNil(DictationTranslationSettings.current(defaults: defaults))

        defaults.set("fa", forKey: UserDefaultsAppRuntimePreferences.dictationTranslationLanguageKey)
        XCTAssertEqual(
            DictationTranslationSettings.current(defaults: defaults),
            DictationTranslationSettings(language: .persian, output: .translation))

        defaults.set("both", forKey: UserDefaultsAppRuntimePreferences.dictationTranslationOutputKey)
        XCTAssertEqual(DictationTranslationSettings.current(defaults: defaults)?.output, .both)

        defaults.set("", forKey: UserDefaultsAppRuntimePreferences.dictationTranslationLanguageKey)
        XCTAssertNil(DictationTranslationSettings.current(defaults: defaults), "Empty language means off")
    }

    func testInsertionTextFollowsTheChosenOutput() {
        var dictation = Dictation(durationMs: 1_000, rawTranscript: "hello world", cleanTranscript: "Hello world.")
        XCTAssertEqual(dictation.insertionText, "Hello world.", "No translation: unchanged")

        dictation.translation = "Hallo Welt."
        dictation.translationLanguage = "de"
        dictation.translationOutput = "translation"
        XCTAssertEqual(dictation.insertionText, "Hallo Welt.")

        dictation.translationOutput = "original"
        XCTAssertEqual(dictation.insertionText, "Hello world.")

        dictation.translationOutput = "both"
        XCTAssertEqual(dictation.insertionText, "Hello world.\nHallo Welt.")

        dictation.translation = ""
        XCTAssertEqual(dictation.insertionText, "Hello world.", "An empty translation never replaces the text")
        XCTAssertEqual(dictation.displayText, "Hello world.", "History keeps showing the spoken text")
    }

    func testTranslationRoundTripsThroughTheDatabase() throws {
        let manager = try DatabaseManager()
        let repo = DictationRepository(dbQueue: manager.dbQueue)
        let dictation = Dictation(
            durationMs: 1_000, rawTranscript: "hello", translation: "سلام", translationLanguage: "fa",
            translationOutput: "both")
        try repo.save(dictation)

        let fetched = try XCTUnwrap(repo.fetch(id: dictation.id))
        XCTAssertEqual(fetched.translation, "سلام")
        XCTAssertEqual(fetched.translationLanguage, "fa")
        XCTAssertEqual(fetched.translationOutput, "both")
    }
}
