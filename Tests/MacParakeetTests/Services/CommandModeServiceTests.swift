import XCTest
@testable import MacParakeetCore

final class CommandModeServiceTests: XCTestCase {
    var service: CommandModeService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var mockLLM: MockLLMService!

    override func setUp() async throws {
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        mockLLM = MockLLMService()
        service = CommandModeService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            llmService: mockLLM
        )
    }

    func testStartRecordingTransitionsToRecording() async throws {
        try await service.startRecording()
        let state = await service.state
        let didStartCapture = await mockAudio.startCaptureCalled
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(didStartCapture)
    }

    func testStopRecordingAndProcessHappyPath() async throws {
        await mockAudio.configure(captureResult: URL(fileURLWithPath: "/tmp/command-mode.wav"))
        await mockSTT.configure(result: STTResult(text: "Make this formal"))
        await mockLLM.configureResponse(text: "Please send the file at your earliest convenience.")

        try await service.startRecording()
        let result = try await service.stopRecordingAndProcess(selectedText: "hey send the file")

        XCTAssertEqual(result.spokenCommand, "Make this formal")
        XCTAssertEqual(result.selectedText, "hey send the file")
        XCTAssertEqual(result.transformedText, "Please send the file at your earliest convenience.")
        let state = await service.state
        let transcribeCalls = await mockSTT.transcribeCallCount
        let didStopCapture = await mockAudio.stopCaptureCalled
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(transcribeCalls, 1)
        XCTAssertTrue(didStopCapture)

        let requests = await mockLLM.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].prompt.contains("Make this formal"))
        XCTAssertTrue(requests[0].prompt.contains("hey send the file"))
    }

    func testStopFailsWhenNotRecording() async {
        do {
            _ = try await service.stopRecordingAndProcess(selectedText: "x")
            XCTFail("Expected notRecording error")
        } catch {
            XCTAssertEqual(error as? CommandModeServiceError, .notRecording)
        }
    }

    func testStopFailsWithEmptySelectedText() async throws {
        try await service.startRecording()

        do {
            _ = try await service.stopRecordingAndProcess(selectedText: "   ")
            XCTFail("Expected emptySelectedText error")
        } catch {
            XCTAssertEqual(error as? CommandModeServiceError, .emptySelectedText)
            let state = await service.state
            XCTAssertEqual(state, .idle)
        }
    }

    func testStopFailsWithEmptyCommandTranscript() async throws {
        await mockAudio.configure(captureResult: URL(fileURLWithPath: "/tmp/command-mode.wav"))
        await mockSTT.configure(result: STTResult(text: "   "))

        try await service.startRecording()
        do {
            _ = try await service.stopRecordingAndProcess(selectedText: "hello")
            XCTFail("Expected emptyCommand error")
        } catch {
            XCTAssertEqual(error as? CommandModeServiceError, .emptyCommand)
            let state = await service.state
            XCTAssertEqual(state, .idle)
        }
    }

    func testStopPropagatesLLMFailureAndResetsToIdle() async throws {
        await mockAudio.configure(captureResult: URL(fileURLWithPath: "/tmp/command-mode.wav"))
        await mockSTT.configure(result: STTResult(text: "Fix grammar"))
        await mockLLM.configureError(LLMServiceError.generationFailed("boom"))

        try await service.startRecording()
        do {
            _ = try await service.stopRecordingAndProcess(selectedText: "Their going now")
            XCTFail("Expected llm error")
        } catch {
            guard case LLMServiceError.generationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            let state = await service.state
            XCTAssertEqual(state, .idle)
        }
    }

    func testCancelRecordingReturnsToIdle() async throws {
        try await service.startRecording()
        await service.cancelRecording()
        let state = await service.state
        let didStopCapture = await mockAudio.stopCaptureCalled
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(didStopCapture)
    }
}
