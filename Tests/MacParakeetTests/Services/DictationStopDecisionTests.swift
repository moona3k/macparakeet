import XCTest
@testable import MacParakeetCore

final class DictationStopDecisionTests: XCTestCase {
    func testProceedWhenServiceIsRecording() {
        let decision = DictationStopDecider.decide(
            serviceState: .recording,
            isStartRecordingInFlight: false
        )
        XCTAssertEqual(decision, .proceed)
    }

    func testDeferWhenStartIsInFlightAndServiceNotRecording() {
        let decision = DictationStopDecider.decide(
            serviceState: .processing,
            isStartRecordingInFlight: true
        )
        XCTAssertEqual(decision, .deferUntilRecording)
    }

    func testRejectWhenNotRecordingAndStartNotInFlight() {
        let decision = DictationStopDecider.decide(
            serviceState: .idle,
            isStartRecordingInFlight: false
        )
        XCTAssertEqual(decision, .rejectNotRecording)
    }
}
