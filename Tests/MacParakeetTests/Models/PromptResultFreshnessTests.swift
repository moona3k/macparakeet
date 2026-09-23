import XCTest
@testable import MacParakeetCore

final class PromptResultFreshnessTests: XCTestCase {
    func testSummaryNeedsUpdateOnlyAfterTheTranscriptRevisionChanges() {
        XCTAssertFalse(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: 0,
                currentCorrectionRevision: 0
            ))
        XCTAssertTrue(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: 0,
                currentCorrectionRevision: 2
            ))
        XCTAssertFalse(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: 2,
                currentCorrectionRevision: 2
            ))
        XCTAssertFalse(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: nil,
                currentCorrectionRevision: 0
            ))
        XCTAssertTrue(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: nil,
                currentCorrectionRevision: 1
            ))
    }

    func testTranscriptHashDetectsRetranscriptionAtResetCorrectionRevision() {
        let original = PromptResultFreshness.sourceTranscriptHash(cleanTranscript: "Original words", rawTranscript: nil)
        let retranscribed = PromptResultFreshness.sourceTranscriptHash(cleanTranscript: "New words", rawTranscript: nil)

        XCTAssertTrue(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: 0,
                currentCorrectionRevision: 0,
                sourceTranscriptHash: original,
                currentTranscriptHash: retranscribed
            ))
    }

    func testTranscriptHashIgnoresWhitespaceAndTranscriptMetadata() {
        let saved = PromptResultFreshness.sourceTranscriptHash(
            cleanTranscript: "  Same words\n", rawTranscript: "ignored")
        let current = PromptResultFreshness.sourceTranscriptHash(cleanTranscript: "Same words", rawTranscript: nil)

        XCTAssertEqual(saved, current)
        XCTAssertFalse(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: 0,
                currentCorrectionRevision: 0,
                sourceTranscriptHash: saved,
                currentTranscriptHash: current
            ))
    }

    func testMissingSourceTextReceiptIsStaleWhenCurrentTranscriptIsKnown() {
        XCTAssertTrue(
            PromptResultFreshness.summaryNeedsUpdate(
                sourceCorrectionRevision: 0,
                currentCorrectionRevision: 0,
                sourceTranscriptHash: nil,
                currentTranscriptHash: "current"
            ))
    }

    func testPromptResultJSONPreservesSourceReceiptAndOmitsUnknownSource() throws {
        let result = PromptResult(
            transcriptionId: UUID(),
            promptName: "Summary",
            promptContent: "Summarize.",
            content: "Result",
            sourceTranscriptHash: PromptResultFreshness.sourceTranscriptHash(
                cleanTranscript: "Transcript", rawTranscript: nil)
        )
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(PromptResult.self, from: encoder.encode(result))
        XCTAssertEqual(decoded.sourceTranscriptHash, result.sourceTranscriptHash)

        var unknown = result
        unknown.sourceTranscriptHash = nil
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(unknown)) as? [String: Any])
        XCTAssertNil(object["sourceTranscriptHash"])
    }
}
