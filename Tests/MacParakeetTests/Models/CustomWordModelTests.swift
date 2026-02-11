import XCTest
@testable import MacParakeetCore

final class CustomWordModelTests: XCTestCase {
    func testDefaultValues() {
        let word = CustomWord(word: "kubernetes", replacement: "Kubernetes")

        XCTAssertEqual(word.word, "kubernetes")
        XCTAssertEqual(word.replacement, "Kubernetes")
        XCTAssertEqual(word.source, .manual)
        XCTAssertTrue(word.isEnabled)
    }

    func testVocabularyAnchor() {
        let word = CustomWord(word: "MacParakeet")

        XCTAssertNil(word.replacement)
        XCTAssertEqual(word.word, "MacParakeet")
    }

    func testSourceEnum() {
        XCTAssertEqual(CustomWord.Source.manual.rawValue, "manual")
        XCTAssertEqual(CustomWord.Source.learned.rawValue, "learned")
    }

    func testDisabledWord() {
        let word = CustomWord(word: "test", replacement: "Test", isEnabled: false)

        XCTAssertFalse(word.isEnabled)
    }
}
