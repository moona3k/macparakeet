import XCTest
@testable import MacParakeetCore

final class SpokenPunctuationTests: XCTestCase {
    private let pipeline = TextProcessingPipeline()

    func testEnglishQuestionAndExclamationMarks() {
        XCTAssertEqual(
            pipeline.process(text: "are you coming question mark.", customWords: [], snippets: []).text,
            "Are you coming?"
        )
        XCTAssertEqual(
            pipeline.process(text: "Are you coming question mark?", customWords: [], snippets: []).text,
            "Are you coming?"
        )
        XCTAssertEqual(
            pipeline.process(text: "ship it exclamation mark", customWords: [], snippets: []).text,
            "Ship it!"
        )
        XCTAssertEqual(
            pipeline.process(text: "ship it exclamation point", customWords: [], snippets: []).text,
            "Ship it!"
        )
    }

    func testLiteralPrefixKeepsTheSpokenPhrase() {
        XCTAssertEqual(
            pipeline.process(text: "say literal question mark please", customWords: [], snippets: []).text,
            "Say question mark please"
        )
        XCTAssertEqual(
            SpokenPunctuation.apply(to: "wörtlich Fragezeichen"),
            "Fragezeichen"
        )
    }

    func testMultilingualSpokenPunctuation() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "fertig fragezeichen"), "fertig?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "vamos signo de interrogación"), "vamos?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "c'est fait point d'exclamation"), "c'est fait!")
        XCTAssertEqual(SpokenPunctuation.apply(to: "pronto ponto de interrogação"), "pronto?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "koniec znak zapytania"), "koniec?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "你好问号"), "你好？")
        XCTAssertEqual(SpokenPunctuation.apply(to: "完成感叹号"), "完成！")
        XCTAssertEqual(SpokenPunctuation.apply(to: "请问号码是多少"), "请问号码是多少")
    }

    func testUserSnippetOverridesBuiltInSpokenPunctuation() {
        let snippets = [
            TextSnippet(trigger: "question mark", expansion: "[Q]")
        ]
        let result = pipeline.process(
            text: "use the question mark",
            customWords: [],
            snippets: snippets
        )
        XCTAssertEqual(result.text, "Use the [Q]")
    }

    func testSpokenPunctuationCanBeDisabled() {
        let result = pipeline.process(
            text: "are you coming question mark",
            customWords: [],
            snippets: [],
            spokenPunctuationEnabled: false
        )
        XCTAssertEqual(result.text, "Are you coming question mark")
    }

    func testPrecedingCommaIsConsumed() {
        XCTAssertEqual(
            SpokenPunctuation.apply(to: "hello, question mark"),
            "hello?"
        )
    }

    func testTrailingEnginePunctuationIsConsumed() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "hello question mark."), "hello?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "hello question mark!"), "hello?")
    }
}
