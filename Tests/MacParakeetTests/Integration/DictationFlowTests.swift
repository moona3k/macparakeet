import XCTest
@testable import MacParakeetCore

final class DictationFlowTests: XCTestCase {
    var dictationService: DictationService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var dictationRepo: DictationRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)

        dictationService = DictationService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            dictationRepo: dictationRepo
        )
    }

    /// End-to-end: start recording → stop → STT → save to DB
    func testFullDictationFlow() async throws {
        // Setup mock STT result
        let sttResult = STTResult(
            text: "Send email to Sarah about the Q1 budget review",
            words: [
                TimestampedWord(word: "Send", startMs: 0, endMs: 200, confidence: 0.99),
                TimestampedWord(word: "email", startMs: 210, endMs: 450, confidence: 0.98),
                TimestampedWord(word: "to", startMs: 460, endMs: 520, confidence: 0.97),
                TimestampedWord(word: "Sarah", startMs: 530, endMs: 800, confidence: 0.95),
                TimestampedWord(word: "about", startMs: 810, endMs: 1000, confidence: 0.98),
                TimestampedWord(word: "the", startMs: 1010, endMs: 1100, confidence: 0.99),
                TimestampedWord(word: "Q1", startMs: 1110, endMs: 1300, confidence: 0.94),
                TimestampedWord(word: "budget", startMs: 1310, endMs: 1600, confidence: 0.97),
                TimestampedWord(word: "review", startMs: 1610, endMs: 2000, confidence: 0.96),
            ]
        )
        await mockSTT.configure(result: sttResult)

        // 1. Start recording
        try await dictationService.startRecording()
        let recordingState = await dictationService.state
        if case .recording = recordingState {} else {
            XCTFail("Expected recording state")
        }

        // 2. Verify audio capture started
        let captureStarted = await mockAudio.startCaptureCalled
        XCTAssertTrue(captureStarted)

        // 3. Stop recording → triggers STT → save
        let dictation = try await dictationService.stopRecording()

        // 4. Verify transcription
        XCTAssertEqual(dictation.rawTranscript, "Send email to Sarah about the Q1 budget review")
        XCTAssertEqual(dictation.durationMs, 2000)
        XCTAssertEqual(dictation.status, .completed)
        XCTAssertEqual(dictation.processingMode, .raw)

        // 5. Verify saved to database
        let savedDictation = try dictationRepo.fetch(id: dictation.id)
        XCTAssertNotNil(savedDictation)
        XCTAssertEqual(savedDictation?.rawTranscript, dictation.rawTranscript)

        // 6. Verify in history
        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
    }

    /// Test that STT errors are handled gracefully
    func testDictationFlowWithSTTError() async throws {
        await mockSTT.configure(error: STTError.transcriptionFailed("Model not loaded"))

        try await dictationService.startRecording()

        do {
            _ = try await dictationService.stopRecording()
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "Model not loaded")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Audio capture should have been attempted
        let captureStarted = await mockAudio.startCaptureCalled
        XCTAssertTrue(captureStarted)
    }

    /// Test search works on saved dictations
    func testDictationSearchAfterSave() async throws {
        let sttResult = STTResult(text: "The Kubernetes deployment is running smoothly")
        await mockSTT.configure(result: sttResult)

        try await dictationService.startRecording()
        _ = try await dictationService.stopRecording()

        // Wait for state reset
        try? await Task.sleep(for: .milliseconds(600))

        // Save another dictation directly
        let second = Dictation(durationMs: 3000, rawTranscript: "Meeting notes from Tuesday")
        try dictationRepo.save(second)

        // Search should find the right ones
        let kubeResults = try dictationRepo.search(query: "Kubernetes", limit: nil)
        XCTAssertEqual(kubeResults.count, 1)
        XCTAssertEqual(kubeResults[0].rawTranscript, "The Kubernetes deployment is running smoothly")

        let meetingResults = try dictationRepo.search(query: "Meeting", limit: nil)
        XCTAssertEqual(meetingResults.count, 1)
    }
}
