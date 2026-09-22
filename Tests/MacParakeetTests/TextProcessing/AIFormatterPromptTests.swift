import XCTest
@testable import MacParakeetCore

final class AIFormatterPromptTests: XCTestCase {
    func testNormalizedEmptyPromptUsesRequestedDefault() {
        XCTAssertEqual(
            AIFormatter.normalizedPromptTemplate("   "),
            AIFormatter.defaultPromptTemplate
        )
        XCTAssertEqual(
            AIFormatter.normalizedPromptTemplate(
                "   ",
                default: AIFormatter.defaultDictationPromptTemplate
            ),
            AIFormatter.defaultDictationPromptTemplate
        )
    }

    func testLegacySharedPromptUpgradesOnlyForTranscriptDefault() {
        XCTAssertEqual(
            AIFormatter.normalizedPromptTemplate(AIFormatter.legacyDefaultPromptTemplateV1),
            AIFormatter.defaultPromptTemplate
        )
        XCTAssertEqual(
            AIFormatter.normalizedPromptTemplate(
                AIFormatter.legacyDefaultPromptTemplateV1,
                default: AIFormatter.defaultDictationPromptTemplate
            ),
            AIFormatter.legacyDefaultPromptTemplateV1
        )
    }

    func testBuiltInSharedPromptIncludesEmptyLegacyAndCurrentDefaults() {
        XCTAssertTrue(AIFormatter.isBuiltInSharedPrompt(""))
        XCTAssertTrue(AIFormatter.isBuiltInSharedPrompt(AIFormatter.defaultPromptTemplate))
        XCTAssertTrue(AIFormatter.isBuiltInSharedPrompt(AIFormatter.legacyDefaultPromptTemplateV1))
        XCTAssertFalse(
            AIFormatter.isBuiltInSharedPrompt("Rewrite:\n\(AIFormatter.transcriptPlaceholder)")
        )
        XCTAssertFalse(AIFormatter.isBuiltInSharedPrompt(AIFormatter.defaultDictationPromptTemplate))
    }

    func testResolvedDictationPromptPrefersStoredDictation() {
        XCTAssertEqual(
            AIFormatter.resolvedDictationPrompt(
                storedDictationPrompt: "Dictation only:\n\(AIFormatter.transcriptPlaceholder)",
                storedSharedPrompt: "Shared custom:\n\(AIFormatter.transcriptPlaceholder)"
            ),
            "Dictation only:\n\(AIFormatter.transcriptPlaceholder)"
        )
    }

    func testResolvedDictationPromptCopiesCustomSharedPrompt() {
        let custom = "Rewrite meetings:\n\(AIFormatter.transcriptPlaceholder)"
        XCTAssertEqual(
            AIFormatter.resolvedDictationPrompt(
                storedDictationPrompt: nil,
                storedSharedPrompt: custom
            ),
            custom
        )
    }

    func testResolvedDictationPromptUsesDictationDefaultForBuiltInSharedPrompt() {
        XCTAssertEqual(
            AIFormatter.resolvedDictationPrompt(
                storedDictationPrompt: nil,
                storedSharedPrompt: nil
            ),
            AIFormatter.defaultDictationPromptTemplate
        )
        XCTAssertEqual(
            AIFormatter.resolvedDictationPrompt(
                storedDictationPrompt: "  ",
                storedSharedPrompt: AIFormatter.defaultPromptTemplate
            ),
            AIFormatter.defaultDictationPromptTemplate
        )
        XCTAssertEqual(
            AIFormatter.resolvedDictationPrompt(
                storedDictationPrompt: nil,
                storedSharedPrompt: AIFormatter.legacyDefaultPromptTemplateV1
            ),
            AIFormatter.defaultDictationPromptTemplate
        )
    }
}
