import Foundation
import XCTest
@testable import MacParakeetCore

final class ObservabilityCaptureCorrelationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Observability.resetCaptureCorrelation()
    }

    override func tearDown() {
        Observability.resetCaptureCorrelation()
        super.tearDown()
    }

    func testEndingOverlappingDictationRestoresMeetingCorrelation() {
        let meeting = correlation(.meeting)
        let dictation = correlation(.dictation)
        Observability.beginCaptureCorrelation(meeting)
        Observability.beginCaptureCorrelation(dictation)
        XCTAssertEqual(Observability.currentCaptureCorrelation, dictation)

        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, meeting)

        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    func testEndingMeetingKeepsOverlappingDictationCorrelation() {
        let meeting = correlation(.meeting)
        let dictation = correlation(.dictation)
        Observability.beginCaptureCorrelation(meeting)
        Observability.beginCaptureCorrelation(dictation)

        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, dictation)

        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    func testSameConsumerSupersessionIgnoresStaleCompletionAndRestoresOtherConsumer() {
        let meeting = correlation(.meeting)
        let firstDictation = correlation(.dictation)
        let secondDictation = correlation(.dictation)
        Observability.beginCaptureCorrelation(meeting)
        Observability.beginCaptureCorrelation(firstDictation)
        Observability.beginCaptureCorrelation(secondDictation)

        Observability.endCaptureCorrelation(workflowID: firstDictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, secondDictation)

        Observability.endCaptureCorrelation(workflowID: secondDictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, meeting)

        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    func testReplacingOlderConsumerBecomesOwnerAndDoesNotRestoreSupersededWorkflow() {
        let firstMeeting = correlation(.meeting)
        let dictation = correlation(.dictation)
        let secondMeeting = correlation(.meeting)
        Observability.beginCaptureCorrelation(firstMeeting)
        Observability.beginCaptureCorrelation(dictation)
        Observability.beginCaptureCorrelation(secondMeeting)
        XCTAssertEqual(Observability.currentCaptureCorrelation, secondMeeting)

        Observability.endCaptureCorrelation(workflowID: secondMeeting.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, dictation)

        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
        Observability.endCaptureCorrelation(workflowID: firstMeeting.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    func testDuplicateBeginPreservesCurrentOwnerWithoutDuplicatingWorkflow() {
        let meeting = correlation(.meeting)
        let dictation = correlation(.dictation)
        Observability.beginCaptureCorrelation(meeting)
        Observability.beginCaptureCorrelation(dictation)
        Observability.beginCaptureCorrelation(dictation)
        Observability.beginCaptureCorrelation(meeting)
        XCTAssertEqual(Observability.currentCaptureCorrelation, dictation)

        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, meeting)

        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    func testDuplicateEndDoesNotClearRemainingConsumer() {
        let meeting = correlation(.meeting)
        let dictation = correlation(.dictation)
        Observability.beginCaptureCorrelation(meeting)
        Observability.beginCaptureCorrelation(dictation)
        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, meeting)
    }

    func testInvalidWorkflowIDDoesNotReplaceOrClearActiveCorrelations() {
        let meeting = correlation(.meeting)
        let dictation = correlation(.dictation)
        Observability.beginCaptureCorrelation(meeting)
        Observability.beginCaptureCorrelation(dictation)

        for invalidID in ["", "not-a-uuid", "microphone-name"] {
            Observability.beginCaptureCorrelation(
                ObservabilityCaptureCorrelation(workflowID: invalidID, consumer: .meeting)
            )
            Observability.endCaptureCorrelation(workflowID: invalidID)
            XCTAssertEqual(Observability.currentCaptureCorrelation, dictation)
        }

        Observability.endCaptureCorrelation(workflowID: dictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, meeting)
    }

    func testRepeatedSupersessionDoesNotRestoreRetiredWorkflows() {
        let meeting = correlation(.meeting)
        Observability.beginCaptureCorrelation(meeting)
        var latestDictation = correlation(.dictation)
        for _ in 0..<100 {
            latestDictation = correlation(.dictation)
            Observability.beginCaptureCorrelation(latestDictation)
        }

        Observability.endCaptureCorrelation(workflowID: latestDictation.workflowID)
        XCTAssertEqual(Observability.currentCaptureCorrelation, meeting)

        Observability.endCaptureCorrelation(workflowID: meeting.workflowID)
        XCTAssertNil(Observability.currentCaptureCorrelation)
    }

    private func correlation(_ consumer: ObservabilityCaptureConsumer) -> ObservabilityCaptureCorrelation {
        ObservabilityCaptureCorrelation(workflowID: UUID().uuidString, consumer: consumer)
    }
}
