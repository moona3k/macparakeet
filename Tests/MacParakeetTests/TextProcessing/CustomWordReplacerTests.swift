import XCTest
@testable import MacParakeetCore

final class CustomWordReplacerTests: XCTestCase {

    // MARK: - Core behavior

    func testEmptyWordsIsIdentity() {
        let replacer = CustomWordReplacer(words: [])
        XCTAssertTrue(replacer.isEmpty)
        XCTAssertEqual(replacer.apply(to: "nothing to change"), "nothing to change")
    }

    func testEmptyTextReturnsEmpty() {
        let replacer = CustomWordReplacer(words: [CustomWord(word: "k8s", replacement: "Kubernetes")])
        XCTAssertEqual(replacer.apply(to: ""), "")
    }

    func testSingleReplacement() {
        let replacer = CustomWordReplacer(words: [CustomWord(word: "k8s", replacement: "Kubernetes")])
        XCTAssertFalse(replacer.isEmpty)
        XCTAssertEqual(replacer.apply(to: "deploy to k8s today"), "deploy to Kubernetes today")
    }

    func testCaseInsensitiveMatch() {
        let replacer = CustomWordReplacer(words: [CustomWord(word: "acme", replacement: "ACME Corp")])
        XCTAssertEqual(replacer.apply(to: "Acme and ACME and acme"), "ACME Corp and ACME Corp and ACME Corp")
    }

    func testWholeWordBoundary() {
        // "cap" must not match inside "capacity".
        let replacer = CustomWordReplacer(words: [CustomWord(word: "cap", replacement: "CAP")])
        XCTAssertEqual(replacer.apply(to: "the cap on capacity"), "the CAP on capacity")
    }

    func testDisabledWordSkipped() {
        let replacer = CustomWordReplacer(words: [
            CustomWord(word: "k8s", replacement: "Kubernetes", isEnabled: false)
        ])
        XCTAssertTrue(replacer.isEmpty)
        XCTAssertEqual(replacer.apply(to: "deploy to k8s"), "deploy to k8s")
    }

    func testRulesApplyInOrder() {
        // A later rule can act on an earlier rule's output.
        let replacer = CustomWordReplacer(words: [
            CustomWord(word: "foo", replacement: "bar"),
            CustomWord(word: "bar", replacement: "baz"),
        ])
        XCTAssertEqual(replacer.apply(to: "foo"), "baz")
    }

    func testNilReplacementAnchorNormalizesToStoredCasing() {
        // replacement == nil → substitute with the stored word's own casing, so
        // a vocabulary anchor canonicalizes capitalization of every match.
        let replacer = CustomWordReplacer(words: [CustomWord(word: "Swift", replacement: nil)])
        XCTAssertEqual(replacer.apply(to: "i love swift and SWIFT"), "i love Swift and Swift")
    }

    func testBlankReplacementAnchorNormalizesToStoredCasing() {
        let replacer = CustomWordReplacer(words: [CustomWord(word: "MacParakeet", replacement: "  ")])
        XCTAssertEqual(replacer.apply(to: "macparakeet and MACPARAKEET"), "MacParakeet and MacParakeet")
    }

    func testReplacementTemplateIsLiteral() {
        // Replacement text containing regex template metacharacters ("$1") must
        // be inserted literally, not interpreted as a capture reference.
        let replacer = CustomWordReplacer(words: [CustomWord(word: "price", replacement: "$1.00")])
        XCTAssertEqual(replacer.apply(to: "the price"), "the $1.00")
    }

    // MARK: - Parity with the pipeline's historical inline implementation

    func testParityWithPipelineApplyCustomWords() {
        let words = [
            CustomWord(word: "k8s", replacement: "Kubernetes"),
            CustomWord(word: "acme", replacement: "ACME Corp"),
            CustomWord(word: "disabled", replacement: "SHOULD-NOT-APPEAR", isEnabled: false),
            CustomWord(word: "anchor", replacement: nil),
            CustomWord(word: "MacParakeet", replacement: " "),
        ]
        let pipeline = TextProcessingPipeline()
        let samples = [
            "deploy k8s for acme",
            "ACME and Acme and acme",
            "anchor stays anchored",
            "macparakeet",
            "disabled words do nothing",
            "",
            "no custom words here",
        ]
        for sample in samples {
            XCTAssertEqual(
                CustomWordReplacer(words: words).apply(to: sample),
                pipeline.applyCustomWords(to: sample, words: words),
                "Replacer diverged from pipeline.applyCustomWords for: \(sample)"
            )
        }
    }
}
