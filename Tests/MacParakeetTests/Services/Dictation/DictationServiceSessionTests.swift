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

    func testStaleStartFailureDoesNotClearReplacementSession() async throws {
        let audio = DictationRaceAudioProcessor()
        service = DictationService(
            audioProcessor: audio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo
        )
        session = DictationServiceSession(service: service)

        let firstSessionID = session.reserveNextSessionID()
        let firstStart = Task {
            try await session.startRecording(sessionID: firstSessionID, context: DictationTelemetryContext())
        }
        await audio.waitForStartCall(1)

        await session.confirmCancel(sessionID: firstSessionID)

        let secondSessionID = session.reserveNextSessionID()
        let secondStart = Task {
            try await session.startRecording(sessionID: secondSessionID, context: DictationTelemetryContext())
        }
        await audio.waitForStartCall(2)

        await audio.releaseStartCall(1)
        do {
            try await firstStart.value
            XCTFail("First start should fail after being replaced")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "interrupted during subscribe")
        } catch {
            XCTFail("Unexpected first start error: \(error)")
        }

        await audio.releaseStartCall(2)
        try await secondStart.value

        let state = await session.state
        if case .recording = state {} else {
            XCTFail("Expected replacement session to still be recording, got \(state)")
        }
    }
}

private actor DictationRaceAudioProcessor: AudioProcessorProtocol {
    private var startCalls = 0
    private var waitersByCall: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaitersByCall: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedCalls: Set<Int> = []
    private var recording = false

    var audioLevel: Float { 0 }
    var isRecording: Bool { recording }
    var recordingDeviceInfo: RecordingDeviceInfo? { nil }

    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func startCapture() async throws {
        startCalls += 1
        let call = startCalls
        signalStartCall(call)
        await waitUntilReleased(call)

        if call == 1 {
            throw AudioProcessorError.recordingFailed("interrupted during subscribe")
        }

        recording = true
    }

    func stopCapture() async throws -> URL {
        recording = false
        return URL(fileURLWithPath: "/tmp/race.wav")
    }

    func waitForStartCall(_ call: Int) async {
        guard startCalls < call else { return }
        await withCheckedContinuation { continuation in
            waitersByCall[call, default: []].append(continuation)
        }
    }

    func releaseStartCall(_ call: Int) {
        releasedCalls.insert(call)
        releaseWaitersByCall.removeValue(forKey: call)?.resume()
    }

    private func signalStartCall(_ call: Int) {
        let waiters = waitersByCall.removeValue(forKey: call) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitUntilReleased(_ call: Int) async {
        guard !releasedCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            releaseWaitersByCall[call] = continuation
        }
    }
}
