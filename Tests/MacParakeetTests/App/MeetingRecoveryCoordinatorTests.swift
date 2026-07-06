import XCTest

import MacParakeetCore
@testable import MacParakeet

@MainActor
final class MeetingRecoveryCoordinatorTests: XCTestCase {
    func testTelemetryPhasesAggregateByLockStateOrder() {
        let recoveries = [
            makeLock(state: .awaitingTranscription),
            makeLock(state: .recording),
            makeLock(state: .recording),
        ]

        XCTAssertEqual(
            TelemetryMeetingRecoveryPhases.aggregate(
                lockStates: MeetingRecoveryCoordinator.telemetryPhases(for: recoveries)
            ),
            "recording:2,awaitingTranscription:1"
        )
    }

    private func makeLock(state: MeetingRecordingLockState) -> MeetingRecordingLockFile {
        MeetingRecordingLockFile(
            sessionId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 0,
            displayName: "Meeting",
            state: state
        )
    }
}
