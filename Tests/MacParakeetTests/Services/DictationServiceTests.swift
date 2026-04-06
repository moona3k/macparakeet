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

    // Note: Cancel flow tests, stop-when-not-recording, and STT error propagation
    // are covered in CancelFlowTests.swift to avoid duplication.
}
