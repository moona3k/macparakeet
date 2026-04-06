import XCTest
@testable import MacParakeetCore

@MainActor
final class DictationServiceSessionTests: XCTestCase {
    var service: DictationService!
    var session: DictationServiceSession!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var dictationRepo: DictationRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo
        )
        session = DictationServiceSession(service: service)
    }

    func testStartRecordingAssignsSessionIDsMonotonically() async throws {
        let firstSessionID = session.reserveNextSessionID()
        try await session.startRecording(sessionID: firstSessionID, context: DictationTelemetryContext())
        XCTAssertEqual(firstSessionID, 1)
        let currentAfterFirstStart = session.currentSessionID
        XCTAssertEqual(currentAfterFirstStart, 1)

        await session.confirmCancel(sessionID: firstSessionID)

        let secondSessionID = session.reserveNextSessionID()
        try await session.startRecording(sessionID: secondSessionID, context: DictationTelemetryContext())
        XCTAssertEqual(secondSessionID, 2)
        let currentAfterSecondStart = session.currentSessionID
        XCTAssertEqual(currentAfterSecondStart, 2)
    }

    func testConfirmCancelActsOnCurrentSession() async throws {
        let sessionID = session.reserveNextSessionID()
        try await session.startRecording(sessionID: sessionID, context: DictationTelemetryContext())

        await session.confirmCancel(sessionID: sessionID)

        let captureStopped = await mockAudio.stopCaptureCalled
        XCTAssertTrue(captureStopped)

        let state = await session.state
        if case .idle = state {} else {
            XCTFail("Expected idle state after confirm cancel, got \(state)")
        }
    }

    func testConfirmCancelUsesCapturedSessionIDInsteadOfLatestReservedSession() async throws {
        let firstSessionID = session.reserveNextSessionID()
        try await session.startRecording(sessionID: firstSessionID, context: DictationTelemetryContext())

        _ = session.reserveNextSessionID()
        await session.confirmCancel(sessionID: firstSessionID)

        let captureStopped = await mockAudio.stopCaptureCalled
        XCTAssertTrue(captureStopped, "Confirm cancel should target the captured session, not the latest reserved one")
    }
}
