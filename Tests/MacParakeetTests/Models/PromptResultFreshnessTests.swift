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
}
