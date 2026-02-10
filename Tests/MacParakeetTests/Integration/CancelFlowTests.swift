import XCTest
@testable import MacParakeetCore

/// Tests for dictation cancel flow and edge cases.
final class CancelFlowTests: XCTestCase {
    var dictationService: DictationService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var mockClipboard: MockClipboardService!
    var dictationRepo: DictationRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        mockClipboard = MockClipboardService()
        dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)

        dictationService = DictationService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            dictationRepo: dictationRepo,
            clipboardService: mockClipboard
        )
    }

    /// Cancel should not paste or save anything
    func testCancelDoesNotPasteOrSave() async throws {
        let sttResult = STTResult(text: "This should not be pasted")
        await mockSTT.configure(result: sttResult)

        // Start recording
        try await dictationService.startRecording()
        let state = await dictationService.state
        if case .recording = state {} else {
            XCTFail("Expected recording state, got \(state)")
        }

        // Cancel
        await dictationService.cancelRecording()

        // Verify no paste happened
        let pasteCount = await mockClipboard.pasteCallCount
        XCTAssertEqual(pasteCount, 0, "Cancel should not paste anything")

        // Verify nothing saved to DB
        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertTrue(all.isEmpty, "Cancel should not save to database")
    }

    /// Verify cancel stops audio capture and transitions to cancelled state
    func testCancelStopsAudioCapture() async throws {
        try await dictationService.startRecording()

        let captureStarted = await mockAudio.startCaptureCalled
        XCTAssertTrue(captureStarted)

        await dictationService.cancelRecording()

        let captureStopped = await mockAudio.stopCaptureCalled
        XCTAssertTrue(captureStopped, "Cancel should stop audio capture")

        // Verify state is cancelled (before the idle reset timer fires)
        let state = await dictationService.state
        if case .cancelled = state {} else {
            // State may have already transitioned to idle if the 5s timer elapsed,
            // but both cancelled and idle are valid post-cancel states
            if case .idle = state {} else {
                XCTFail("Expected cancelled or idle state after cancel, got \(state)")
            }
        }
    }

    /// Stop when not recording should throw
    func testStopWhenNotRecordingThrows() async throws {
        do {
            _ = try await dictationService.stopRecording()
            XCTFail("Should have thrown DictationServiceError.notRecording")
        } catch let error as DictationServiceError {
            if case .notRecording = error {} else {
                XCTFail("Expected notRecording, got \(error)")
            }
        }
    }

    /// Starting when already recording should be a no-op
    func testDoubleStartIsNoOp() async throws {
        try await dictationService.startRecording()
        // Second start should be silently ignored
        try await dictationService.startRecording()

        // Should still be in recording state
        let state = await dictationService.state
        if case .recording = state {} else {
            XCTFail("Expected recording state")
        }
    }

    /// STT error during stop should propagate
    func testSTTErrorDuringStop() async throws {
        await mockSTT.configure(error: STTError.transcriptionFailed("Model crashed"))

        try await dictationService.startRecording()

        do {
            _ = try await dictationService.stopRecording()
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "Model crashed")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Verify no paste happened
        let pasteCount = await mockClipboard.pasteCallCount
        XCTAssertEqual(pasteCount, 0)
    }

    /// Duration computation with word timestamps
    func testDurationComputedFromWordTimestamps() async throws {
        let sttResult = STTResult(
            text: "Hello world",
            words: [
                TimestampedWord(word: "Hello", startMs: 0, endMs: 300, confidence: 0.99),
                TimestampedWord(word: "world", startMs: 310, endMs: 800, confidence: 0.98),
            ]
        )
        await mockSTT.configure(result: sttResult)

        try await dictationService.startRecording()
        let dictation = try await dictationService.stopRecording()

        XCTAssertEqual(dictation.durationMs, 800, "Duration should be end of last word")
    }

    /// Duration estimation when no word timestamps
    func testDurationEstimatedWithoutTimestamps() async throws {
        let sttResult = STTResult(text: "Hello world test", words: [])
        await mockSTT.configure(result: sttResult)

        try await dictationService.startRecording()
        let dictation = try await dictationService.stopRecording()

        // 3 words * 150ms estimate = 450
        XCTAssertEqual(dictation.durationMs, 450)
    }

    /// After an STT error, state should recover to idle so a new recording can start
    func testStateRecoversToIdleAfterError() async throws {
        await mockSTT.configure(error: STTError.transcriptionFailed("Network error"))

        try await dictationService.startRecording()

        do {
            _ = try await dictationService.stopRecording()
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "Network error")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // State should be back to idle
        let state = await dictationService.state
        if case .idle = state {} else {
            XCTFail("Expected idle state after error recovery, got \(state)")
        }

        // Should be able to start a new recording
        await mockSTT.configure(result: STTResult(text: "Recovery works"))
        try await dictationService.startRecording()
        let newState = await dictationService.state
        if case .recording = newState {} else {
            XCTFail("Expected recording state after recovery, got \(newState)")
        }
    }

    /// After startRecording fails, state should recover to idle
    func testStateRecoversToIdleAfterStartError() async throws {
        await mockAudio.configureCaptureError(AudioProcessorError.microphonePermissionDenied)

        do {
            try await dictationService.startRecording()
            XCTFail("Should have thrown")
        } catch let error as AudioProcessorError {
            if case .microphonePermissionDenied = error {} else {
                XCTFail("Expected microphonePermissionDenied, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let state = await dictationService.state
        if case .idle = state {} else {
            XCTFail("Expected idle state after start error, got \(state)")
        }
    }
}
