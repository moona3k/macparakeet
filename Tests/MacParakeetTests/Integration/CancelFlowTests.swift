import GRDB
import XCTest
@testable import MacParakeetCore

/// Tests for dictation cancel flow and edge cases.
final class CancelFlowTests: XCTestCase {
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
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo
        )
    }

    /// Cancelling during capture should not save a dictation.
    func testCancelDuringCaptureDoesNotSave() async throws {
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

        // Verify nothing saved to DB
        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertTrue(all.isEmpty, "Cancel should not save to database")
    }

    func testCancelledProcessingNeverCompletesHistoryAndPreservesReplacement() async throws {
        try await assertProcessingCancellation(at: .transcription)
    }

    func testCancellationDuringSuccessDisplayPreservesCommittedResult() async throws {
        try await assertProcessingCancellation(at: .successDisplay)
    }

    func testCancellationDuringFormatterMetadataPreservesCommittedResult() async throws {
        try await assertProcessingCancellation(at: .formatterRun)
    }

    func testCancelledFormattingNeverCompletesHistoryAndPreservesReplacement() async throws {
        try await assertProcessingCancellation(at: .formatting)
        try await assertProcessingCancellation(at: .formatterCancellation)
    }

    private enum CancellationStage: Sendable {
        case transcription, formatting, formatterCancellation, successDisplay, formatterRun

        var isCommitted: Bool { self == .successDisplay || self == .formatterRun }
    }

    private func assertProcessingCancellation(at stage: CancellationStage) async throws {
        for preserve in [false, true] {
            for saveHistory in [false, true] {
                if stage == .formatterRun && !saveHistory { continue }
                for replace in [false, true] {
                    let db = try DatabaseManager()
                    let repo = DictationRepository(dbQueue: db.dbQueue)
                    let audio = MockAudioProcessor()
                    let stt = MockSTTClient()
                    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                        UUID().uuidString + ".wav")
                    try Data([0, 1, 2]).write(to: audioURL)
                    defer { try? FileManager.default.removeItem(at: audioURL) }
                    await audio.configure(captureResult: audioURL)
                    let suspended = expectation(description: "Processing suspended at \(stage)")
                    let release = ProcessingCancellationGate()
                    let llm = MockLLMService()
                    if stage == .formatting || stage == .formatterCancellation {
                        llm.formatTranscriptHook = {
                            suspended.fulfill()
                            await release.wait()
                        }
                        if stage == .formatterCancellation { llm.errorToThrow = CancellationError() }
                    }
                    let runs = LLMRunRepository(dbQueue: db.dbQueue)
                    let service = DictationService(
                        audioProcessor: audio,
                        sttTranscriber: stt,
                        dictationRepo: repo,
                        shouldSaveDictationHistory: { saveHistory },
                        shouldPreserveDiscardedDictations: { preserve },
                        llmService: llm,
                        llmRunRepo: stage == .formatterRun
                            ? SuspendedDictationRunRepository(
                                base: runs, gate: release, entered: { suspended.fulfill() })
                            : runs,
                        shouldUseAIFormatter: { true }
                    )
                    await stt.configure(result: STTResult(text: "discarded take"))
                    if stage == .transcription {
                        await stt.setTranscribeHook {
                            suspended.fulfill()
                            await release.wait()
                        }
                    } else if stage == .successDisplay {
                        await service.setSuccessDisplayWaiterForTesting {
                            suspended.fulfill()
                            await release.wait()
                        }
                    }
                    try await service.startRecording(context: DictationTelemetryContext(), sessionID: 1)
                    let stop = Task { try await service.stopRecording(sessionID: 1) }
                    await fulfillment(of: [suspended], timeout: 2)
                    stop.cancel()
                    if replace {
                        try await service.startRecording(context: DictationTelemetryContext(), sessionID: 2)
                    }
                    await release.open()
                    do {
                        let result = try await stop.value
                        if !stage.isCommitted {
                            XCTFail("Cancelled processing returned a deliverable result")
                        } else {
                            XCTAssertEqual(result.dictation.status, .completed)
                        }
                    } catch is CancellationError {
                        XCTAssertFalse(stage.isCommitted, "A committed take keeps its terminal result")
                    }
                    // Awaiting the real service task proves persistence has settled.
                    let context = "preserve=\(preserve), history=\(saveHistory), replacement=\(replace)"
                    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), context)
                    let rows = try await db.dbQueue.read { try Dictation.fetchAll($0) }
                    let committed = stage.isCommitted
                    XCTAssertEqual(rows.count, committed || (preserve && saveHistory) ? 1 : 0, context)
                    XCTAssertTrue(rows.allSatisfy { $0.status == (committed ? .completed : .cancelled) }, context)
                    XCTAssertEqual(try repo.fetchCompleted(limit: 10).count, committed && saveHistory ? 1 : 0, context)
                    XCTAssertEqual(try repo.stats().totalCount, committed ? 1 : 0, context)
                    XCTAssertEqual(try runs.count(), committed && saveHistory ? 1 : 0, context)
                    if !committed && preserve && saveHistory {
                        XCTAssertEqual(rows.first?.rawTranscript, "discarded take", context)
                    }
                    if stage == .transcription {
                        XCTAssertEqual(llm.formatTranscriptCallCount, 0, "Cancelled STT must not start a formatter")
                    }
                    let state = await service.state
                    if replace {
                        guard case .recording = state else {
                            XCTFail("Replacement capture was overwritten: \(state), \(context)")
                            continue
                        }
                        await stt.setTranscribeHook {}
                        await service.cancelRecording(reason: nil, sessionID: 2)
                        await service.confirmCancel(sessionID: 2)
                    } else {
                        guard case .idle = state else {
                            XCTFail("Cancelled processing did not settle: \(state), \(context)")
                            continue
                        }
                    }
                }
            }
        }
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
        let result = try await dictationService.stopRecording()

        XCTAssertEqual(result.dictation.durationMs, 800, "Duration should be end of last word")
    }

    /// Duration is still populated when no word timestamps are returned.
    func testDurationPopulatedWithoutTimestamps() async throws {
        let sttResult = STTResult(text: "Hello world test", words: [])
        await mockSTT.configure(result: sttResult)

        try await dictationService.startRecording()
        let result = try await dictationService.stopRecording()

        XCTAssertGreaterThan(result.dictation.durationMs, 0)
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

    func testUndoCancelProcessesAndSaves() async throws {
        await mockSTT.configure(result: STTResult(text: "Hello world"))

        try await dictationService.startRecording()
        await dictationService.cancelRecording()

        let result = try await dictationService.undoCancel()
        XCTAssertEqual(result.dictation.rawTranscript, "Hello world")

        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
    }

    func testUndoCancelUsesDurationCapturedAtCancelTimeWhenTimestampsAreMissing() async throws {
        await mockSTT.configure(result: STTResult(text: "cohere final", words: [], engine: .cohere))

        let startedAt = Date()
        try await dictationService.startRecording()
        try await Task.sleep(for: .milliseconds(50))
        await dictationService.cancelRecording()
        let cancelDurationUpperBoundMs = Int(Date().timeIntervalSince(startedAt) * 1000) + 100

        try await Task.sleep(for: .milliseconds(300))
        let result = try await dictationService.undoCancel()

        XCTAssertLessThanOrEqual(
            result.dictation.durationMs,
            cancelDurationUpperBoundMs,
            "Undo should use the capture duration sampled at cancel time, not the dwell time before undo."
        )
    }

    func testConfirmCancelDiscardsActiveRecordingImmediately() async throws {
        try await dictationService.startRecording()

        await dictationService.confirmCancel()

        let captureStopped = await mockAudio.stopCaptureCalled
        XCTAssertTrue(captureStopped, "Immediate discard should stop audio capture")

        let state = await dictationService.state
        if case .idle = state {} else {
            XCTFail("Expected idle state after immediate discard, got \(state)")
        }

        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertTrue(all.isEmpty, "Immediate discard should not save to database")
    }

    func testStaleConfirmCancelDoesNotInterruptNewSessionStart() async throws {
        await mockAudio.configureStartCaptureDelay(milliseconds: 100)

        let startTask = Task {
            try await self.dictationService.startRecording(
                context: DictationTelemetryContext(),
                sessionID: 2
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        await dictationService.confirmCancel(sessionID: 1)

        try await startTask.value

        let captureStopped = await mockAudio.stopCaptureCalled
        XCTAssertFalse(captureStopped, "Stale cancel should not stop the new session's capture")

        let state = await dictationService.state
        if case .recording = state {} else {
            XCTFail("Expected recording state after stale cancel, got \(state)")
        }

        await dictationService.confirmCancel(sessionID: 2)
    }

    /// Regression: undoCancel transcribes the cancelled audio and then settles
    /// to .idle after a ~500ms delay. If a new dictation starts during that
    /// window it must take over — undoCancel's terminal writes must not clobber
    /// the new session back to .idle. Mirrors the reentrancy guard that
    /// stopRecording(sessionID:) already has.
    func testStaleUndoCancelDoesNotClobberNewSessionStart() async throws {
        await mockSTT.configure(result: STTResult(text: "Hello world"))

        // Session 1: start, then soft-cancel so undo is available.
        try await dictationService.startRecording(
            context: DictationTelemetryContext(),
            sessionID: 1
        )
        await dictationService.cancelRecording()

        // Begin undo for session 1. With the fast mock STT it reaches .success
        // quickly, then sleeps ~500ms before settling to .idle — that post-
        // success window is where a new session can land.
        let undoTask = Task {
            try await self.dictationService.undoCancel()
        }

        // Let undo enter its post-success settle window.
        try await Task.sleep(for: .milliseconds(100))

        // Session 2 starts during undo's settle window and takes over.
        try await dictationService.startRecording(
            context: DictationTelemetryContext(),
            sessionID: 2
        )

        // Undo completes; its terminal .idle write must be skipped because the
        // active session is now 2.
        _ = try await undoTask.value

        let state = await dictationService.state
        if case .recording = state {} else {
            XCTFail("Expected session 2 to remain recording after stale undo, got \(state)")
        }

        await dictationService.confirmCancel(sessionID: 2)
    }

    func testStopRecordingWithEmptyTranscriptThrowsAndDoesNotSave() async throws {
        await mockSTT.configure(result: STTResult(text: "   "))

        try await dictationService.startRecording()

        do {
            _ = try await dictationService.stopRecording()
            XCTFail("Expected emptyTranscript error")
        } catch let error as DictationServiceError {
            if case .emptyTranscript = error {} else {
                XCTFail("Expected emptyTranscript, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let all = try dictationRepo.fetchAll(limit: nil)
        XCTAssertTrue(all.isEmpty, "Empty transcript should not be saved")
    }
}

/// Holds the real metadata write's return, not a mock of persistence or cancellation.
private final class SuspendedDictationRunRepository: LLMRunRepositoryProtocol, Sendable {
    let base: LLMRunRepository
    let gate: ProcessingCancellationGate
    let entered: @Sendable () -> Void

    init(base: LLMRunRepository, gate: ProcessingCancellationGate, entered: @escaping @Sendable () -> Void) {
        self.base = base
        self.gate = gate
        self.entered = entered
    }

    func save(_ run: LLMRun) async throws {
        try await base.save(run)
        entered()
        await gate.wait()
    }

    func fetchRecent(limit: Int) throws -> [LLMRun] { try base.fetchRecent(limit: limit) }
    func fetchForDictation(id: UUID) throws -> [LLMRun] { try base.fetchForDictation(id: id) }
    func fetchForTranscription(id: UUID) throws -> [LLMRun] { try base.fetchForTranscription(id: id) }
    func fetchForPromptResult(id: UUID) throws -> [LLMRun] { try base.fetchForPromptResult(id: id) }
    func fetchForChatConversation(id: UUID) throws -> [LLMRun] { try base.fetchForChatConversation(id: id) }
    func fetchForTransformHistory(id: UUID) throws -> [LLMRun] { try base.fetchForTransformHistory(id: id) }
    func count() throws -> Int { try base.count() }
    func deleteAll() throws { try base.deleteAll() }
}
