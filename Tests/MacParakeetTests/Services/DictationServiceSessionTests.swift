import XCTest
@testable import MacParakeetCore

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
            sttClient: mockSTT,
            dictationRepo: dictationRepo
        )
        session = DictationServiceSession(service: service)
    }

    func testStartRecordingAssignsSessionIDsMonotonically() async throws {
        let firstSessionID = try await session.startRecording(context: DictationTelemetryContext())
        XCTAssertEqual(firstSessionID, 1)
        let currentAfterFirstStart = await session.currentSessionID
        XCTAssertEqual(currentAfterFirstStart, 1)

        await session.confirmCancel()

        let secondSessionID = try await session.startRecording(context: DictationTelemetryContext())
        XCTAssertEqual(secondSessionID, 2)
        let currentAfterSecondStart = await session.currentSessionID
        XCTAssertEqual(currentAfterSecondStart, 2)
    }

    func testConfirmCancelActsOnCurrentSession() async throws {
        _ = try await session.startRecording(context: DictationTelemetryContext())

        await session.confirmCancel()

        let captureStopped = await mockAudio.stopCaptureCalled
        XCTAssertTrue(captureStopped)

        let state = await session.state
        if case .idle = state {} else {
            XCTFail("Expected idle state after confirm cancel, got \(state)")
        }
    }
}
