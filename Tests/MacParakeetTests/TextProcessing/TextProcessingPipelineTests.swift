import XCTest
@testable import MacParakeetCore

final class TextProcessingPipelineTests: XCTestCase {
    let pipeline = TextProcessingPipeline()

    // MARK: - Full Pipeline

    func testEmptyInput() {
        let result = pipeline.process(text: "", customWords: [], snippets: [])
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.expandedSnippetIDs.isEmpty)
    }

    func testFullPipeline() {
        let words = [
            CustomWord(word: "kubernetes", replacement: "Kubernetes")
        ]
        let snippets = [
            TextSnippet(trigger: "my signature", expansion: "Best regards, David")
        ]

        let result = pipeline.process(
            text: "um kubernetes is great my signature",
            customWords: words,
            snippets: snippets
        )

        XCTAssertEqual(result.text, "Kubernetes is great Best regards, David")
        XCTAssertEqual(result.expandedSnippetIDs.count, 1)
    }

    func testPipelineNoTransformations() {
        let result = pipeline.process(text: "Hello world", customWords: [], snippets: [])
        XCTAssertEqual(result.text, "Hello world")
    }

    // MARK: - Step 1: Filler Removal

    func testAlwaysSafeFillerRemoval() {
        let result = pipeline.removeFillers(from: "um hello uh world")
        // After filler removal, we get "  hello  world" — whitespace cleanup is separate
        XCTAssertFalse(result.contains("um"))
        XCTAssertFalse(result.contains("uh"))
    }

    func testFillerRemovalPreservesPartialWords() {
        // Word boundaries prevent "um" from matching inside "umbrella"
        let result = pipeline.removeFillers(from: "umbrella this is humble")
        XCTAssertTrue(result.contains("umbrella"))
        XCTAssertTrue(result.contains("humble"))
    }

    func testFillerRemovalCaseInsensitive() {
        let result = pipeline.removeFillers(from: "UM hello UHH world")
        XCTAssertFalse(result.lowercased().contains("um"))
        XCTAssertFalse(result.lowercased().contains("uhh"))
    }

    func testHesitationVariants() {
        let result = pipeline.removeFillers(from: "umm this is uhh interesting")
        XCTAssertFalse(result.contains("umm"))
        XCTAssertFalse(result.contains("uhh"))
    }

    // MARK: - Step 2: Custom Words

    func testCustomWordReplacement() {
        let words = [CustomWord(word: "aye pee eye", replacement: "API")]
        let result = pipeline.applyCustomWords(to: "the aye pee eye is great", words: words)
        XCTAssertTrue(result.contains("API"))
        XCTAssertFalse(result.contains("aye pee eye"))
    }

    func testVocabularyAnchor() {
        let words = [CustomWord(word: "Kubernetes")]
        let result = pipeline.applyCustomWords(to: "I love kubernetes", words: words)
        XCTAssertTrue(result.contains("Kubernetes"))
        XCTAssertFalse(result.contains("kubernetes"))
    }

    func testDisabledWordSkipped() {
        let words = [CustomWord(word: "test", replacement: "TEST", isEnabled: false)]
        let result = pipeline.applyCustomWords(to: "this is a test", words: words)
        XCTAssertTrue(result.contains("test"))
        XCTAssertFalse(result.contains("TEST"))
    }

    func testCustomWordCaseInsensitive() {
        let words = [CustomWord(word: "macparakeet", replacement: "MacParakeet")]
        let result = pipeline.applyCustomWords(to: "I use MACPARAKEET daily", words: words)
        XCTAssertTrue(result.contains("MacParakeet"))
    }

    func testCustomWordWholeWordBoundary() {
        let words = [CustomWord(word: "go", replacement: "Go")]
        let result = pipeline.applyCustomWords(to: "I go to google", words: words)
        XCTAssertTrue(result.contains("Go"))
        XCTAssertTrue(result.contains("google"))  // "go" inside "google" not replaced
    }

    func testMultipleCustomWords() {
        let words = [
            CustomWord(word: "kubernetes", replacement: "Kubernetes"),
            CustomWord(word: "aye pee eye", replacement: "API"),
        ]
        let result = pipeline.applyCustomWords(
            to: "the kubernetes aye pee eye is fast",
            words: words
        )
        XCTAssertTrue(result.contains("Kubernetes"))
        XCTAssertTrue(result.contains("API"))
    }

    // MARK: - Step 3: Snippet Expansion

    func testSnippetExpansion() {
        let snippets = [
            TextSnippet(trigger: "my signature", expansion: "Best regards, David")
        ]
        let (result, ids) = pipeline.expandSnippets(in: "please add my signature", snippets: snippets)
        XCTAssertTrue(result.contains("Best regards, David"))
        XCTAssertEqual(ids.count, 1)
    }

    func testDisabledSnippetSkipped() {
        let snippets = [
            TextSnippet(trigger: "my sig", expansion: "Sincerely", isEnabled: false)
        ]
        let (result, ids) = pipeline.expandSnippets(in: "add my sig here", snippets: snippets)
        XCTAssertTrue(result.contains("my sig"))
        XCTAssertTrue(ids.isEmpty)
    }

    func testLongestTriggerFirst() {
        let short = TextSnippet(trigger: "my address", expansion: "123 Main St")
        let long = TextSnippet(trigger: "my address block", expansion: "123 Main St\nCity, ST 12345")

        let (result, ids) = pipeline.expandSnippets(
            in: "send to my address block",
            snippets: [short, long]
        )
        XCTAssertTrue(result.contains("City, ST 12345"))
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids.contains(long.id))
    }

    func testSnippetCaseInsensitive() {
        let snippets = [
            TextSnippet(trigger: "my signature", expansion: "Best regards")
        ]
        let (result, _) = pipeline.expandSnippets(in: "add My Signature here", snippets: snippets)
        XCTAssertTrue(result.contains("Best regards"))
    }

    func testNoSnippetsReturnsOriginal() {
        let (result, ids) = pipeline.expandSnippets(in: "hello world", snippets: [])
        XCTAssertEqual(result, "hello world")
        XCTAssertTrue(ids.isEmpty)
    }

    func testMultipleSnippetExpansions() {
        let s1 = TextSnippet(trigger: "my name", expansion: "David Moon")
        let s2 = TextSnippet(trigger: "my email", expansion: "david@example.com")

        let (result, ids) = pipeline.expandSnippets(
            in: "my name and my email",
            snippets: [s1, s2]
        )
        XCTAssertTrue(result.contains("David Moon"))
        XCTAssertTrue(result.contains("david@example.com"))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: - Step 4: Whitespace Cleanup

    func testCollapseMultipleSpaces() {
        let result = pipeline.cleanWhitespace(in: "hello   world")
        XCTAssertEqual(result, "Hello world")
    }

    func testRemoveSpaceBeforePunctuation() {
        let result = pipeline.cleanWhitespace(in: "hello .")
        XCTAssertEqual(result, "Hello.")
    }

    func testTrim() {
        let result = pipeline.cleanWhitespace(in: "  hello world  ")
        XCTAssertEqual(result, "Hello world")
    }

    func testCapitalizeFirstLetter() {
        let result = pipeline.cleanWhitespace(in: "hello world")
        XCTAssertEqual(result, "Hello world")
    }

    func testAlreadyCapitalized() {
        let result = pipeline.cleanWhitespace(in: "Hello world")
        XCTAssertEqual(result, "Hello world")
    }

    func testMultiplePunctuationSpaces() {
        let result = pipeline.cleanWhitespace(in: "hello , world . great !")
        XCTAssertEqual(result, "Hello, world. great!")
    }

    func testWhitespaceOnlyInput() {
        let result = pipeline.cleanWhitespace(in: "   ")
        XCTAssertEqual(result, "")
    }

    func testCleanSpacesAroundNewlines() {
        let result = pipeline.cleanWhitespace(in: "Hello, \n world")
        XCTAssertEqual(result, "Hello,\nworld")
    }

    func testCleanSpacesAroundDoubleNewline() {
        let result = pipeline.cleanWhitespace(in: "Hello, \n\n world")
        XCTAssertEqual(result, "Hello,\n\nworld")
    }

    func testNewlineSnippetExpansionEndToEnd() {
        let snippets = [
            TextSnippet(trigger: "enter", expansion: "\n")
        ]
        let result = pipeline.process(text: "Hello, enter world", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Hello,\nworld")
    }

    func testDoubleNewlineSnippetExpansionEndToEnd() {
        let snippets = [
            TextSnippet(trigger: "new paragraph", expansion: "\n\n")
        ]
        let result = pipeline.process(text: "Hello, new paragraph world", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Hello,\n\nworld")
    }

    // Regression: Parakeet adds punctuation after trigger phrase.
    // Step 4b's \s+ was eating newlines before punctuation, producing ".." or ",,".
    // https://github.com/moona3k/macparakeet-community/issues/24

    func testNewlineSnippetPreservedBeforePeriod() {
        let snippets = [
            TextSnippet(trigger: "new paragraph", expansion: "\n\n")
        ]
        let result = pipeline.process(
            text: "Please review the attached. New paragraph. Let me know.",
            customWords: [],
            snippets: snippets
        )
        XCTAssertTrue(result.text.contains("\n\n"), "Newlines must survive when followed by punctuation, got: \(result.text)")
        XCTAssertFalse(result.text.contains(".."), "Must not collapse newlines into double period")
    }

    func testNewlineSnippetPreservedBeforeComma() {
        let snippets = [
            TextSnippet(trigger: "new paragraph", expansion: "\n\n")
        ]
        let result = pipeline.process(
            text: "Hey, new paragraph, just checking in.",
            customWords: [],
            snippets: snippets
        )
        XCTAssertTrue(result.text.contains("\n\n"), "Newlines must survive when followed by comma, got: \(result.text)")
        XCTAssertFalse(result.text.contains(",,"), "Must not collapse newlines into double comma")
    }

    func testCleanWhitespacePreservesNewlinesBeforePunctuation() {
        let result = pipeline.cleanWhitespace(in: "Hello.\n\n. World")
        XCTAssertTrue(result.contains("\n\n"), "Newlines before punctuation must not be stripped, got: \(result)")
    }

    // MARK: - Keystroke Action Snippets

    func testActionSnippetAtEndOfText() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "hello world return", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testActionSnippetMidTextIgnored() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "press return to continue", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Press return to continue")
        XCTAssertNil(result.postPasteAction)
    }

    func testActionSnippetCaseInsensitive() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "hello RETURN", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testActionSnippetWithTrailingPunctuation() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "hello world return.", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testActionSnippetWithTrailingComma() {
        let snippets = [
            TextSnippet(trigger: "press return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "git status press return,", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Git status")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testActionSnippetTracksExpandedID() {
        let snippet = TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        let result = pipeline.process(text: "hello return", customWords: [], snippets: [snippet])
        XCTAssertTrue(result.expandedSnippetIDs.contains(snippet.id))
    }

    func testNoActionSnippetsReturnsNilAction() {
        let snippets = [
            TextSnippet(trigger: "my sig", expansion: "Best regards, Daniel")
        ]
        let result = pipeline.process(text: "hello my sig", customWords: [], snippets: snippets)
        XCTAssertNil(result.postPasteAction)
    }

    func testTextAndActionSnippetsTogether() {
        let snippets = [
            TextSnippet(trigger: "my sig", expansion: "Best regards"),
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "my sig return", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Best regards")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testDisabledActionSnippetIgnored() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", isEnabled: false, action: .returnKey)
        ]
        let result = pipeline.process(text: "hello return", customWords: [], snippets: snippets)
        XCTAssertNil(result.postPasteAction)
        XCTAssertEqual(result.text, "Hello return")
    }

    func testMultiWordActionTrigger() {
        let snippets = [
            TextSnippet(trigger: "press return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "git status press return", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Git status")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testActionOnlyDictation() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "return", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testTriggerMidTextAndAtEnd() {
        let snippets = [
            TextSnippet(trigger: "return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "press return and then return", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Press return and then")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testMultiWordTriggerWithFillerGap() {
        // Filler removal can leave double spaces: "press um return" → "press  return"
        let snippets = [
            TextSnippet(trigger: "press return", expansion: "return", action: .returnKey)
        ]
        let result = pipeline.process(text: "git status press um return", customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "Git status")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }
}
