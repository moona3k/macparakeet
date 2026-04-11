import XCTest
@testable import MacParakeetCore

final class DictationServiceTests: XCTestCase {
    var service: DictationService!
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
    }

    func testInitialStateIsIdle() async {
        let state = await service.state
        if case .idle = state {} else {
            XCTFail("Expected idle state, got \(state)")
        }
    }

    func testStartRecordingChangesState() async throws {
        try await service.startRecording()
        let state = await service.state
        if case .recording = state {} else {
            XCTFail("Expected recording state, got \(state)")
        }
    }

    func testStopRecordingTranscribesAndSaves() async throws {
        let expectedResult = STTResult(
            text: "Hello world",
            words: [
                TimestampedWord(word: "Hello", startMs: 0, endMs: 500, confidence: 0.98),
                TimestampedWord(word: "world", startMs: 520, endMs: 1000, confidence: 0.95)
            ]
        )
        await mockSTT.configure(result: expectedResult)

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "Hello world")
        XCTAssertEqual(result.dictation.status, .completed)
        XCTAssertEqual(result.dictation.processingMode, .raw)
        XCTAssertEqual(result.dictation.durationMs, 1000)
        XCTAssertNil(result.postPasteAction)

        // Verify saved to DB
        let fetched = try dictationRepo.fetch(id: result.dictation.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.rawTranscript, "Hello world")
    }

    func testStopRecordingAppliesAIFormatterAsFinalStep() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Hello, world."

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "hello world")
        XCTAssertEqual(result.dictation.cleanTranscript, "Hello, world.")
        XCTAssertEqual(result.dictation.wordCount, 2)
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        XCTAssertEqual(mockLLMService.lastFormattedTranscript, "hello world")
    }

    func testStopRecordingFallsBackWhenAIFormatterFailsAndPostsWarning() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = LLMError.formatterTruncated

        let warningPosted = expectation(description: "AI formatter warning posted")
        var warningMessage: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterWarning,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "dictation" else { return }
            warningMessage = notification.userInfo?["message"] as? String
            warningPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "hello world")
        XCTAssertNil(result.dictation.cleanTranscript)
        XCTAssertEqual(result.dictation.wordCount, 2)
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        await fulfillment(of: [warningPosted], timeout: 1.0)
        XCTAssertEqual(warningMessage, "AI formatter output was incomplete. Used standard cleanup.")
    }

    func testStopRecordingPostsAuthenticationWarningWhenAIFormatterAuthFails() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = LLMError.authenticationFailed(nil)

        let warningPosted = expectation(description: "AI formatter auth warning posted")
        var warningMessage: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterWarning,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "dictation" else { return }
            warningMessage = notification.userInfo?["message"] as? String
            warningPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        try await service.startRecording()
        _ = try await service.stopRecording()

        await fulfillment(of: [warningPosted], timeout: 1.0)
        XCTAssertEqual(warningMessage, "Authentication failed. Check your API key. Used standard cleanup.")
    }

    // Note: Cancel flow tests, stop-when-not-recording, and STT error propagation
    // are covered in CancelFlowTests.swift to avoid duplication.
}
