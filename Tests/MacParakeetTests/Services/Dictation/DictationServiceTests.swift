import XCTest
@testable import MacParakeetCore

private final class DictationTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func flush() async {}
    func clearQueue() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class DictationServiceTests: XCTestCase {
    var service: DictationService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var dictationRepo: DictationRepository!
    var llmRunRepo: LLMRunRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
        llmRunRepo = LLMRunRepository(dbQueue: dbManager.dbQueue)

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo
        )
    }

    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        service = nil
        mockAudio = nil
        mockSTT = nil
        dictationRepo = nil
        llmRunRepo = nil
        super.tearDown()
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

    func testDiscardPreRollForwardsToAudioProcessorWhileRecording() async throws {
        try await service.startRecording()

        await service.discardPreRollForActiveCapture(sessionID: nil)

        let callCount = await mockAudio.discardPreRollCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testDiscardPreRollIgnoresStaleSession() async throws {
        try await service.startRecording(context: DictationTelemetryContext(), sessionID: 7)

        await service.discardPreRollForActiveCapture(sessionID: 6)

        let callCount = await mockAudio.discardPreRollCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testDiscardPreRollIgnoredWhenNotRecording() async {
        await service.discardPreRollForActiveCapture(sessionID: nil)

        let callCount = await mockAudio.discardPreRollCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testStartFailureUsesRequestedTelemetryContextForOperation() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)

        try await service.startRecording(context: DictationTelemetryContext(trigger: .menuBar, mode: .persistent))
        await service.confirmCancel()

        await mockAudio.configureCaptureError(AudioProcessorError.microphoneNotAvailable)
        do {
            try await service.startRecording(context: DictationTelemetryContext(trigger: .hotkey, mode: .hold))
            XCTFail("Expected startRecording to throw")
        } catch let error as AudioProcessorError {
            if case .microphoneNotAvailable = error {} else {
                XCTFail("Expected microphoneNotAvailable, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let operation = try XCTUnwrap(dictationOperationProps(in: telemetry.snapshot()).last)
        XCTAssertEqual(operation["outcome"], "failure")
        XCTAssertEqual(operation["trigger"], "hotkey")
        XCTAssertEqual(operation["mode"], "hold")
    }

    func testInterruptedSubscribeWithoutCancelEmitsFailureTelemetry() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)

        await mockAudio.configureCaptureError(AudioProcessorError.recordingFailed("interrupted during subscribe"))

        do {
            try await service.startRecording(context: DictationTelemetryContext(trigger: .hotkey, mode: .hold))
            XCTFail("Expected startRecording to throw")
        } catch let error as AudioProcessorError {
            if case .recordingFailed(let reason) = error {
                XCTAssertEqual(reason, "interrupted during subscribe")
            } else {
                XCTFail("Expected interrupted recording failure, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = telemetry.snapshot()
        XCTAssertTrue(events.contains { event in
            if case .dictationFailed = event { return true }
            return false
        })

        let operation = try XCTUnwrap(dictationOperationProps(in: events).last)
        XCTAssertEqual(operation["outcome"], "failure")
        XCTAssertEqual(operation["trigger"], "hotkey")
        XCTAssertEqual(operation["mode"], "hold")
    }

    func testCancelDuringStartCaptureStillEmitsCancelledOperation() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)
        await mockAudio.configureStartCaptureDelay(milliseconds: 100)

        let startTask = Task {
            try await self.service.startRecording(context: DictationTelemetryContext(trigger: .hotkey, mode: .hold))
        }

        try await Task.sleep(for: .milliseconds(20))
        await service.cancelRecording(reason: .hotkey)
        try await startTask.value
        await service.confirmCancel()

        let operations = dictationOperationProps(in: telemetry.snapshot())
        XCTAssertTrue(operations.contains { operation in
            operation["outcome"] == "cancelled"
                && operation["trigger"] == "hotkey"
                && operation["mode"] == "hold"
                && operation["cancel_reason"] == "hotkey"
            })
    }

    func testCancelThenConfirmEmitsCancelledTelemetryAndOperationReason() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)

        try await service.startRecording(context: DictationTelemetryContext(trigger: .hotkey, mode: .hold))
        await service.cancelRecording(reason: .escape)
        await service.confirmCancel()

        let events = telemetry.snapshot()
        XCTAssertTrue(events.contains { event in
            guard case .dictationCancelled = event else { return false }
            return event.props?["reason"] == "escape"
        })

        let operations = dictationOperationProps(in: events)
        XCTAssertTrue(operations.contains { operation in
            operation["outcome"] == "cancelled"
                && operation["trigger"] == "hotkey"
                && operation["mode"] == "hold"
                && operation["cancel_reason"] == "escape"
        })
    }

    func testInterruptedSubscribeAfterCancelDoesNotEmitFailureTelemetry() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)

        let audio = StartInterruptedAudioProcessor()
        service = DictationService(
            audioProcessor: audio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo
        )

        let startTask = Task {
            try await self.service.startRecording(context: DictationTelemetryContext(trigger: .hotkey, mode: .hold))
        }

        await audio.waitForStartCapture()
        await service.confirmCancel()
        try await startTask.value

        let events = telemetry.snapshot()
        XCTAssertFalse(events.contains { event in
            if case .dictationFailed = event { return true }
            return false
        })

        let operations = dictationOperationProps(in: events)
        XCTAssertTrue(operations.contains { operation in
            operation["outcome"] == "cancelled"
                && operation["trigger"] == "hotkey"
                && operation["mode"] == "hold"
        })
    }

    func testInterruptedSubscribeAfterCancelLeavesServiceNonRecordingBeforeCancelCompletes() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)

        let audio = StartInterruptedDelayedStopAudioProcessor()
        service = DictationService(
            audioProcessor: audio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo
        )

        let startTask = Task {
            try await self.service.startRecording(context: DictationTelemetryContext(trigger: .hotkey, mode: .hold))
            return await self.service.state
        }

        await audio.waitForStartCapture()
        let cancelTask = Task { await service.confirmCancel() }
        await audio.waitForStopCapture()

        let stateAfterSuppressedStart = try await startTask.value
        XCTAssertFalse(Self.isRecording(stateAfterSuppressedStart))

        await audio.allowStopCaptureToReturn()
        await cancelTask.value

        let finalState = await service.state
        if case .idle = finalState {} else {
            XCTFail("Expected idle after confirmCancel, got \(finalState)")
        }
    }

    func testStopRecordingTranscribesAndSaves() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)

        let expectedResult = STTResult(
            text: "Hello world",
            words: [
                TimestampedWord(word: "Hello", startMs: 0, endMs: 500, confidence: 0.98),
                TimestampedWord(word: "world", startMs: 520, endMs: 1000, confidence: 0.95)
            ],
            language: "KO_kr",
            engine: .whisper,
            engineVariant: SpeechEnginePreference.defaultWhisperModelVariant
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
        XCTAssertEqual(fetched?.engine, "whisper")
        XCTAssertEqual(fetched?.engineVariant, SpeechEnginePreference.defaultWhisperModelVariant)
        XCTAssertEqual(fetched?.language, "ko")

        let operation = try XCTUnwrap(
            dictationOperationProps(in: telemetry.snapshot()).last { $0["outcome"] == "success" }
        )
        XCTAssertEqual(operation["speech_engine"], "whisper")
        XCTAssertEqual(operation["engine_variant"], SpeechEnginePreference.defaultWhisperModelVariant)
        XCTAssertEqual(operation["language"], "ko")
    }

    func testStopRecordingUsesLiveNemotronResultWhenAvailable() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(result: STTResult(
            text: "live final",
            words: [],
            language: "en",
            engine: .nemotron,
            engineVariant: NemotronModelVariant.multilingual1120.rawValue
        ))

        try await service.startRecording()
        await mockSTT.emitLivePartial(" live partial ")
        let partialApplied = await waitForCondition { [service] in
            await service?.liveTranscript == "live partial"
        }
        XCTAssertTrue(partialApplied, "Expected live partial to reach liveTranscript")

        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "live final")
        XCTAssertEqual(result.dictation.engine, "nemotron")
        XCTAssertEqual(result.dictation.engineVariant, NemotronModelVariant.multilingual1120.rawValue)
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveAppendCallCount = await mockSTT.liveAppendCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        XCTAssertEqual(transcribeCallCount, 0)
        XCTAssertEqual(liveAppendCallCount, 1)
        XCTAssertEqual(liveFinishCallCount, 1)
    }

    func testLiveNemotronPreviewDisabledStillUsesLiveFinalButHidesPartials() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true },
            shouldShowDictationPreview: { false }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(result: STTResult(
            text: "live final",
            words: [],
            language: "en",
            engine: .nemotron,
            engineVariant: NemotronModelVariant.multilingual1120.rawValue
        ))

        try await service.startRecording()
        await mockSTT.emitLivePartial(" live partial ")
        try await Task.sleep(for: .milliseconds(50))

        let liveTranscript = await service.liveTranscript
        XCTAssertEqual(liveTranscript, "")

        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "live final")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveAppendCallCount = await mockSTT.liveAppendCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        XCTAssertEqual(transcribeCallCount, 0)
        XCTAssertEqual(liveAppendCallCount, 1)
        XCTAssertEqual(liveFinishCallCount, 1)
    }

    func testStopRecordingFallsBackToRecordedFileWhenLiveNemotronFails() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(appendError: STTError.transcriptionFailed("live failed"))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file fallback")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveAppendCallCount = await mockSTT.liveAppendCallCount
        let liveCancelCallCount = await mockSTT.liveCancelCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveAppendCallCount, 1)
        XCTAssertEqual(liveCancelCallCount, 1)
    }

    func testStopRecordingFallsBackToRecordedFileWhenLiveBeginFails() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(beginError: STTError.engineBusy)

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file fallback")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveBeginCallCount = await mockSTT.liveBeginCallCount
        let liveAppendCallCount = await mockSTT.liveAppendCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveBeginCallCount, 1)
        XCTAssertEqual(liveAppendCallCount, 0)
    }

    func testStopRecordingFallsBackToRecordedFileWhenLiveFinishFails() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(finishError: STTError.transcriptionFailed("finish failed"))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file fallback")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveFinishCallCount, 1)
    }

    func testStopRecordingFallsBackToRecordedFileWhenLiveFinalIsEmpty() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(result: STTResult(text: "  \n", words: [], engine: .nemotron))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file fallback")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveFinishCallCount, 1)
    }

    func testStopRecordingFallsBackToRecordedFileWhenLiveSamplesAreDropped() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(result: STTResult(
            text: "live final",
            words: [],
            engine: .nemotron
        ))
        await mockSTT.holdLiveAppends()

        try await service.startRecording()
        // The live sample stream buffers at most 120 chunks while the
        // consumer is held inside the first append; everything beyond the
        // buffer reports `.dropped`, which must disqualify the live result.
        for _ in 0..<130 {
            await mockAudio.emitLiveSamples([0.1])
        }
        await mockSTT.releaseLiveAppends()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file fallback")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        let liveCancelCallCount = await mockSTT.liveCancelCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveFinishCallCount, 0)
        XCTAssertEqual(liveCancelCallCount, 1)
    }

    func testStopRecordingFallsBackToRecordedFileAfterPreRollDiscard() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(result: STTResult(
            text: "live final",
            words: [],
            engine: .nemotron
        ))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2])
        await service.discardPreRollForActiveCapture(sessionID: nil)
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file fallback")
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        let liveCancelCallCount = await mockSTT.liveCancelCallCount
        let discardCallCount = await mockAudio.discardPreRollCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveFinishCallCount, 0)
        XCTAssertEqual(liveCancelCallCount, 1)
        XCTAssertEqual(discardCallCount, 1)
    }

    func testParakeetDisplayPreviewUsesSamplesButFinalStaysRecordedFile() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            dictationPreviewSpeechEngine: { SpeechEngineSelection(engine: .parakeet) },
            dictationPreviewInterval: .zero
        )
        await mockSTT.configure(result: STTResult(text: "file final", words: [], engine: .parakeet))
        await mockSTT.configurePreview(result: STTResult(text: "preview tail", words: [], engine: .parakeet))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])

        let previewApplied = await waitForCondition { [service] in
            await service?.liveTranscript == "preview tail"
        }
        XCTAssertTrue(previewApplied, "Expected display preview to update liveTranscript")

        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file final")
        let previewCallCount = await mockSTT.previewCallCount
        let previewSamples = await mockSTT.previewSamples
        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveBeginCallCount = await mockSTT.liveBeginCallCount
        XCTAssertEqual(previewCallCount, 1)
        XCTAssertEqual(previewSamples, [[0.1, 0.2, 0.3]])
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(liveBeginCallCount, 0)
    }

    func testDisplayPreviewDisabledSkipsPreviewTranscription() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldShowDictationPreview: { false },
            dictationPreviewSpeechEngine: { SpeechEngineSelection(engine: .parakeet) },
            dictationPreviewInterval: .zero
        )
        await mockSTT.configure(result: STTResult(text: "file final", words: [], engine: .parakeet))
        await mockSTT.configurePreview(result: STTResult(text: "preview tail", words: [], engine: .parakeet))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        try await Task.sleep(for: .milliseconds(50))

        let liveTranscript = await service.liveTranscript
        XCTAssertEqual(liveTranscript, "")

        let result = try await service.stopRecording()

        let previewCallCount = await mockSTT.previewCallCount
        let previewCancelCallCount = await mockSTT.previewCancelCallCount
        let transcribeCallCount = await mockSTT.transcribeCallCount
        XCTAssertEqual(result.dictation.rawTranscript, "file final")
        XCTAssertEqual(previewCallCount, 0)
        XCTAssertEqual(previewCancelCallCount, 0)
        XCTAssertEqual(transcribeCallCount, 1)
    }

    func testDisplayPreviewTailWindowDropsOldSamples() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            dictationPreviewSpeechEngine: { SpeechEngineSelection(engine: .parakeet) },
            dictationPreviewInterval: .zero,
            dictationPreviewWindowSeconds: 3.0 / 16_000.0
        )
        await mockSTT.configure(result: STTResult(text: "file final", words: [], engine: .parakeet))
        await mockSTT.configurePreview(result: STTResult(text: "preview tail", words: [], engine: .parakeet))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2])
        let firstPreviewApplied = await waitForCondition { [mockSTT] in
            await mockSTT?.previewCallCount == 1
        }
        XCTAssertTrue(firstPreviewApplied, "Expected first preview pass")

        await mockAudio.emitLiveSamples([0.3, 0.4])
        let secondPreviewApplied = await waitForCondition { [mockSTT] in
            await mockSTT?.previewCallCount == 2
        }
        XCTAssertTrue(secondPreviewApplied, "Expected second preview pass")

        _ = try await service.stopRecording()

        let previewSamples = await mockSTT.previewSamples
        XCTAssertEqual(previewSamples, [[0.1, 0.2], [0.2, 0.3, 0.4]])
    }

    func testBlockedDisplayPreviewIsCancelledBeforeRecordedFileFinal() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            dictationPreviewSpeechEngine: { SpeechEngineSelection(engine: .parakeet) },
            dictationPreviewInterval: .zero
        )
        await mockSTT.configure(result: STTResult(text: "file final", words: [], engine: .parakeet))
        await mockSTT.configurePreview(result: STTResult(text: "preview tail", words: [], engine: .parakeet))
        await mockSTT.holdPreviewTranscription()

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let previewStarted = await waitForCondition { [mockSTT] in
            await mockSTT?.previewCallCount == 1
        }
        XCTAssertTrue(previewStarted, "Expected preview pass to start")

        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file final")
        let previewCancelCallCount = await mockSTT.previewCancelCallCount
        let transcribeCallCount = await mockSTT.transcribeCallCount
        XCTAssertEqual(previewCancelCallCount, 1)
        XCTAssertEqual(transcribeCallCount, 1)
    }

    func testBlockedDisplayPreviewCancellationTimeoutStillAllowsRecordedFileFinal() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            dictationPreviewSpeechEngine: { SpeechEngineSelection(engine: .parakeet) },
            dictationPreviewInterval: .zero,
            dictationPreviewCancellationTimeout: .milliseconds(50)
        )
        await mockSTT.configure(result: STTResult(text: "file final", words: [], engine: .parakeet))
        await mockSTT.configurePreview(result: STTResult(text: "preview tail", words: [], engine: .parakeet))
        await mockSTT.holdPreviewTranscription(releaseOnCancel: false)

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2, 0.3])
        let previewStarted = await waitForCondition { [mockSTT] in
            await mockSTT?.previewCallCount == 1
        }
        XCTAssertTrue(previewStarted, "Expected preview pass to start")

        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file final")
        let previewCancelCallCount = await mockSTT.previewCancelCallCount
        let transcribeCallCount = await mockSTT.transcribeCallCount
        XCTAssertEqual(previewCancelCallCount, 1)
        XCTAssertEqual(transcribeCallCount, 1)

        await mockSTT.releasePreviewTranscription()
    }

    func testPreRollDiscardClearsDisplayPreviewAndStillUsesRecordedFileFinal() async throws {
        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            dictationPreviewSpeechEngine: { SpeechEngineSelection(engine: .parakeet) },
            dictationPreviewInterval: .zero
        )
        await mockSTT.configure(result: STTResult(text: "file final", words: [], engine: .parakeet))
        await mockSTT.configurePreview(result: STTResult(text: "preview tail", words: [], engine: .parakeet))

        try await service.startRecording()
        await mockAudio.emitLiveSamples([0.1, 0.2])
        let previewApplied = await waitForCondition { [service] in
            await service?.liveTranscript == "preview tail"
        }
        XCTAssertTrue(previewApplied, "Expected display preview before pre-roll discard")

        await service.discardPreRollForActiveCapture(sessionID: nil)

        let cleared = await waitForCondition { [service] in
            await service?.liveTranscript == ""
        }
        XCTAssertTrue(cleared, "Expected pre-roll discard to clear display preview")
        let previewCancelCallCount = await mockSTT.previewCancelCallCount
        XCTAssertEqual(previewCancelCallCount, 1)

        await mockAudio.emitLiveSamples([0.3, 0.4])
        try await Task.sleep(for: .milliseconds(50))
        let previewCallCount = await mockSTT.previewCallCount
        XCTAssertEqual(
            previewCallCount,
            1,
            "Preview should stop after pre-roll discard so stale pre-roll samples cannot re-enter the visible tail"
        )

        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "file final")
        let discardCallCount = await mockAudio.discardPreRollCallCount
        XCTAssertEqual(discardCallCount, 1)
    }

    func testStopRecordingCancelsLiveSessionWhenCaptureIsTooShort() async throws {
        let shortCaptureAudio = StopFailingLiveAudioProcessor(error: AudioProcessorError.insufficientSamples)
        service = DictationService(
            audioProcessor: shortCaptureAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldAttemptLiveDictationTranscription: { true }
        )
        await mockSTT.configure(result: STTResult(text: "file fallback"))
        await mockSTT.configureLive(result: STTResult(
            text: "live final",
            words: [],
            engine: .nemotron
        ))

        try await service.startRecording()
        await shortCaptureAudio.emitLiveSamples([0.1, 0.2])

        do {
            _ = try await service.stopRecording()
            XCTFail("Expected stopRecording to throw insufficientSamples")
        } catch let error as AudioProcessorError {
            if case .insufficientSamples = error {} else {
                XCTFail("Expected insufficientSamples, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transcribeCallCount = await mockSTT.transcribeCallCount
        let liveFinishCallCount = await mockSTT.liveFinishCallCount
        let liveCancelCallCount = await mockSTT.liveCancelCallCount
        XCTAssertEqual(transcribeCallCount, 0)
        XCTAssertEqual(liveFinishCallCount, 0)
        XCTAssertEqual(liveCancelCallCount, 1)
    }

    func testStopRecordingUsesLatestAppCategoryForTelemetry() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)
        await mockSTT.configure(result: STTResult(text: "finish target"))

        try await service.startRecording(
            context: DictationTelemetryContext(
                trigger: .menuBar,
                mode: .hold,
                appCategory: .browser
            )
        )
        await service.updateTelemetryAppCategory(.email)
        _ = try await service.stopRecording()

        let events = telemetry.snapshot()
        let completed = try XCTUnwrap(events.last { event in
            if case .dictationCompleted = event { return true }
            return false
        })
        XCTAssertEqual(completed.props?["app_category"], "email")

        let operation = try XCTUnwrap(successfulDictationOperation(
            in: events,
            trigger: .menuBar,
            mode: .hold
        ))
        XCTAssertEqual(operation["app_category"], "email")
    }

    func testNilStopTimeAppCategoryRecordsOtherTelemetryBucket() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)
        await mockSTT.configure(result: STTResult(text: "finish target"))

        try await service.startRecording(
            context: DictationTelemetryContext(
                trigger: .menuBar,
                mode: .hold,
                appCategory: .browser
            )
        )
        await service.updateTelemetryAppCategory(nil)
        _ = try await service.stopRecording()

        let events = telemetry.snapshot()
        let completed = try XCTUnwrap(events.last { event in
            if case .dictationCompleted = event { return true }
            return false
        })
        XCTAssertEqual(completed.props?["app_category"], "other")

        let operation = try XCTUnwrap(successfulDictationOperation(
            in: events,
            trigger: .menuBar,
            mode: .hold
        ))
        XCTAssertEqual(operation["app_category"], "other")
    }

    func testFirstDictationFlagFlipsAfterSuccessfulSave() async throws {
        let defaults = UserDefaults(suiteName: "dictation-first-success-\(UUID().uuidString)")!
        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertFalse(preferences.hasCompletedFirstDictation)

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            markFirstDictationCompleted: {
                preferences.markFirstDictationCompleted()
            }
        )
        await mockSTT.configureSequence(results: [
            STTResult(text: "first saved dictation"),
            STTResult(text: "second saved dictation"),
        ])

        try await service.startRecording()
        _ = try await service.stopRecording()
        XCTAssertTrue(preferences.hasCompletedFirstDictation)

        try await service.startRecording()
        _ = try await service.stopRecording()
        XCTAssertTrue(preferences.hasCompletedFirstDictation)
    }

    func testFirstDictationFlagDoesNotFlipOnFailedDictation() async throws {
        let defaults = UserDefaults(suiteName: "dictation-first-failure-\(UUID().uuidString)")!
        let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            markFirstDictationCompleted: {
                preferences.markFirstDictationCompleted()
            }
        )
        await mockSTT.configure(error: STTError.transcriptionFailed("model load failed"))

        try await service.startRecording()
        do {
            _ = try await service.stopRecording()
            XCTFail("Expected failed dictation to throw")
        } catch {
            XCTAssertFalse(preferences.hasCompletedFirstDictation)
        }
    }

    func testStopRecordingAppliesAIFormatterAsFinalStep() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Hello, world."
        mockLLMService.formatTranscriptProvider = "lmstudio"
        mockLLMService.formatTranscriptModel = "sotto-cleanup"
        mockLLMService.formatTranscriptUsage = LLMUsage(promptTokens: 10, completionTokens: 4, totalTokens: 14)
        mockLLMService.formatTranscriptStopReason = "stop"
        mockLLMService.formatTranscriptLatencyMs = 42

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            llmRunRepo: llmRunRepo,
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

        let runs = try llmRunRepo.fetchForDictation(id: result.dictation.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.feature, .formatterDictation)
        XCTAssertEqual(runs.first?.status, .succeeded)
        XCTAssertEqual(runs.first?.provider, "lmstudio")
        XCTAssertEqual(runs.first?.model, "sotto-cleanup")
        XCTAssertEqual(runs.first?.promptTokens, 10)
        XCTAssertEqual(runs.first?.completionTokens, 4)
        XCTAssertEqual(runs.first?.totalTokens, 14)
        XCTAssertEqual(runs.first?.latencyMs, 42)
        XCTAssertEqual(runs.first?.inputChars, "hello world".count)
        XCTAssertEqual(runs.first?.outputChars, "Hello, world.".count)
        XCTAssertEqual(runs.first?.stopReason, "stop")
        XCTAssertEqual(runs.first?.defaultPromptUsed, true)
        XCTAssertEqual(runs.first?.messageCount, 2)
    }

    func testStopRecordingAppliesInlineInsertionStyleToCleanDictation() async throws {
        await mockSTT.configure(result: STTResult(text: "Hello world."))

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            processingMode: { .clean },
            dictationInsertionStyle: { .inline }
        )

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "Hello world.")
        XCTAssertEqual(result.dictation.cleanTranscript, "hello world")
        XCTAssertEqual(result.dictation.wordCount, 2)
    }

    func testStopRecordingNormalizesAIFormatterOutputBeforeInlineInsertionStyle() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "  Hello world. \n"

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            processingMode: { .clean },
            dictationInsertionStyle: { .inline },
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.cleanTranscript, "hello world")
        XCTAssertEqual(result.dictation.wordCount, 2)
    }

    func testStopRecordingUsesAIFormatterProfileResolutionAndStoresMetadata() async throws {
        await mockSTT.configure(result: STTResult(text: "send update to team"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Send update to team."
        let profileID = UUID()
        let resolver = RecordingAIFormatterPromptResolver(
            resolution: AIFormatterPromptResolution(
                promptTemplate: "Slack style prompt",
                matchKind: .exactApp,
                profileID: profileID,
                profileName: "Slack",
                profileOrigin: .custom
            )
        )

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptResolver: resolver
        )

        try await service.startRecording()
        let context = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        await service.updateAIFormatterAppContext(context, phase: .start)
        let result = try await service.stopRecording()

        XCTAssertEqual(mockLLMService.lastFormatterPromptTemplate, "Slack style prompt")
        XCTAssertEqual(mockLLMService.lastFormatterDefaultPromptUsed, false)
        XCTAssertEqual(result.dictation.cleanTranscript, "Send update to team.")
        XCTAssertEqual(result.dictation.aiFormatterProfileID, profileID)
        XCTAssertEqual(result.dictation.aiFormatterProfileName, "Slack")
        XCTAssertEqual(result.dictation.aiFormatterProfileMatchKind, .exactApp)

        let contexts = await resolver.recordedContexts()
        XCTAssertEqual(contexts, [context])

        let fetched = try XCTUnwrap(dictationRepo.fetch(id: result.dictation.id))
        XCTAssertEqual(fetched.aiFormatterProfileID, profileID)
        XCTAssertEqual(fetched.aiFormatterProfileName, "Slack")
        XCTAssertEqual(fetched.aiFormatterProfileMatchKind, .exactApp)
    }

    /// A profile/category/smart-default can route a dictation and then the LLM
    /// call can still fail, dropping the dictation to standard cleanup. The
    /// saved record must NOT carry the matched profile in that case, or History
    /// would claim "Formatted with the '<profile>' prompt" for text the profile
    /// never produced. Regression guard for the QA-found provenance overclaim.
    func testStopRecordingDropsProfileProvenanceWhenAIFormatterFails() async throws {
        await mockSTT.configure(result: STTResult(text: "send update to team"))
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = LLMError.formatterTruncated
        let resolver = RecordingAIFormatterPromptResolver(
            resolution: AIFormatterPromptResolution(
                promptTemplate: "Slack style prompt",
                matchKind: .exactApp,
                profileID: UUID(),
                profileName: "Slack",
                profileOrigin: .custom
            )
        )

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptResolver: resolver
        )

        try await service.startRecording()
        let context = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        await service.updateAIFormatterAppContext(context, phase: .start)
        let result = try await service.stopRecording()

        // The formatter ran (so the resolver was consulted) but threw, so the
        // record must read as an unrouted, standard-cleanup dictation.
        XCTAssertNil(result.dictation.aiFormatterProfileID)
        XCTAssertNil(result.dictation.aiFormatterProfileName)
        XCTAssertNil(result.dictation.aiFormatterProfileMatchKind)

        let fetched = try XCTUnwrap(dictationRepo.fetch(id: result.dictation.id))
        XCTAssertNil(fetched.aiFormatterProfileID)
        XCTAssertNil(fetched.aiFormatterProfileName)
        XCTAssertNil(fetched.aiFormatterProfileMatchKind)
    }

    func testExactAppFormatterProfileDoesNotEmitExactTelemetryData() async throws {
        let telemetry = DictationTelemetrySpy()
        Telemetry.configure(telemetry)
        await mockSTT.configure(result: STTResult(text: "send confidential roadmap"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Send confidential roadmap."
        let profileID = UUID()
        let profileName = "Slack Casual"
        let promptTemplate = "Slack-only private prompt: {{TRANSCRIPT}}"
        let bundleIdentifier = "com.tinyspeck.slackmacgap"
        let displayName = "Slack"
        let resolver = RecordingAIFormatterPromptResolver(
            resolution: AIFormatterPromptResolution(
                promptTemplate: promptTemplate,
                matchKind: .exactApp,
                profileID: profileID,
                profileName: profileName,
                profileOrigin: .custom
            )
        )

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptResolver: resolver
        )

        try await service.startRecording()
        let context = AppPromptContext(bundleIdentifier: bundleIdentifier, displayName: displayName)
        await service.updateTelemetryAppCategory(context.category)
        await service.updateAIFormatterAppContext(context, phase: .finish)
        _ = try await service.stopRecording()

        let telemetryProps = allTelemetryProps(in: telemetry.snapshot())
        XCTAssertFalse(telemetryProps.isEmpty)
        for props in telemetryProps {
            let serialized = props
                .flatMap { [$0.key, $0.value] }
                .joined(separator: "\n")
                .lowercased()
            XCTAssertFalse(serialized.contains(bundleIdentifier))
            XCTAssertFalse(serialized.contains(displayName.lowercased()))
            XCTAssertFalse(serialized.contains(profileID.uuidString.lowercased()))
            XCTAssertFalse(serialized.contains(profileName.lowercased()))
            XCTAssertFalse(serialized.contains(promptTemplate.lowercased()))
            XCTAssertFalse(serialized.contains("send confidential roadmap"))
            XCTAssertFalse(serialized.contains(AIFormatterProfileMatchKind.exactApp.rawValue))
        }
        XCTAssertTrue(telemetryProps.contains { $0["app_category"] == TelemetryAppCategory.messaging.rawValue })
    }

    func testStopRecordingUsesFinishAIFormatterContextOverStartContext() async throws {
        await mockSTT.configure(result: STTResult(text: "send update"))
        let mockLLMService = MockLLMService()
        let resolver = RecordingAIFormatterPromptResolver(
            resolution: AIFormatterPromptResolution(
                promptTemplate: "Finish app prompt",
                matchKind: .category
            )
        )

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptResolver: resolver
        )

        try await service.startRecording()
        await service.updateAIFormatterAppContext(
            AppPromptContext(bundleIdentifier: "com.apple.notes", displayName: "Notes"),
            phase: .start
        )
        let finishContext = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )
        await service.updateAIFormatterAppContext(finishContext, phase: .finish)
        _ = try await service.stopRecording()

        let contexts = await resolver.recordedContexts()
        XCTAssertEqual(contexts, [finishContext])
        XCTAssertEqual(mockLLMService.lastFormatterPromptTemplate, "Finish app prompt")
    }

    func testOverlappingSessionKeepsAIFormatterContextBoundToStoppedSession() async throws {
        let delayedSTT = DelayedSTTTranscriber(result: STTResult(text: "send first update"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Send first update."
        let resolver = RecordingAIFormatterPromptResolver(
            resolution: AIFormatterPromptResolution(
                promptTemplate: "First app prompt",
                matchKind: .exactApp
            )
        )

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: delayedSTT,
            dictationRepo: dictationRepo,
            llmService: mockLLMService,
            shouldUseAIFormatter: { true },
            aiFormatterPromptResolver: resolver
        )

        try await service.startRecording(sessionID: 1)
        let firstContext = AppPromptContext(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes"
        )
        await service.updateAIFormatterAppContext(firstContext, phase: .finish)

        let service = service!
        let stopTask = Task {
            try await service.stopRecording(sessionID: 1)
        }
        await delayedSTT.waitForTranscribeCall(1)

        try await service.startRecording(sessionID: 2)
        await service.updateAIFormatterAppContext(
            AppPromptContext(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack"),
            phase: .finish
        )

        await delayedSTT.releaseTranscribeCall(1)
        let result = try await stopTask.value
        await service.confirmCancel(sessionID: 2)

        XCTAssertEqual(result.dictation.cleanTranscript, "Send first update.")
        let contexts = await resolver.recordedContexts()
        XCTAssertEqual(contexts, [firstContext])
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
            llmRunRepo: llmRunRepo,
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

        let runs = try llmRunRepo.fetchForDictation(id: result.dictation.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.feature, .formatterDictation)
        XCTAssertEqual(runs.first?.status, .failed)
        XCTAssertEqual(runs.first?.inputChars, "hello world".count)
        XCTAssertEqual(runs.first?.outputChars, 0)
        XCTAssertNotNil(runs.first?.errorType)
    }

    func testStopRecordingDoesNotSaveLLMRunWhenDictationHistoryDisabled() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "Hello, world."

        service = DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            shouldSaveDictationHistory: { false },
            llmService: mockLLMService,
            llmRunRepo: llmRunRepo,
            shouldUseAIFormatter: { true },
            aiFormatterPromptTemplate: { AIFormatter.defaultPromptTemplate }
        )

        try await service.startRecording()
        let result = try await service.stopRecording()

        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        XCTAssertNil(result.dictation.aiFormatterProfileID)
        XCTAssertNil(result.dictation.aiFormatterProfileName)
        XCTAssertNil(result.dictation.aiFormatterProfileMatchKind)
        XCTAssertEqual(try llmRunRepo.count(), 0)
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

    private func dictationOperationProps(in events: [TelemetryEventSpec]) -> [[String: String]] {
        events.compactMap { event in
            guard case .dictationOperation = event else { return nil }
            return event.props ?? [:]
        }
    }

    private func successfulDictationOperation(
        in events: [TelemetryEventSpec],
        trigger: TelemetryDictationTrigger,
        mode: TelemetryDictationMode
    ) -> [String: String]? {
        dictationOperationProps(in: events).last { props in
            props["outcome"] == ObservabilityOutcome.success.rawValue
                && props["trigger"] == trigger.rawValue
                && props["mode"] == mode.rawValue
        }
    }

    private func waitForCondition(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func allTelemetryProps(in events: [TelemetryEventSpec]) -> [[String: String]] {
        events.compactMap(\.props)
    }

    private static func isRecording(_ state: DictationState) -> Bool {
        if case .recording = state { return true }
        return false
    }
}

private actor RecordingAIFormatterPromptResolver: AIFormatterPromptResolving {
    private let resolution: AIFormatterPromptResolution
    private var contexts: [AppPromptContext?] = []

    init(resolution: AIFormatterPromptResolution) {
        self.resolution = resolution
    }

    func resolvePrompt(for context: AppPromptContext?) async -> AIFormatterPromptResolution {
        contexts.append(context)
        return resolution
    }

    func recordedContexts() -> [AppPromptContext?] {
        contexts
    }
}

private actor DelayedSTTTranscriber: STTTranscribing {
    private let result: STTResult
    private var transcribeCalls = 0
    private var waitersByCall: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaitersByCall: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedCalls: Set<Int> = []

    init(result: STTResult) {
        self.result = result
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        transcribeCalls += 1
        let call = transcribeCalls
        signalTranscribeCall(call)
        await waitUntilReleased(call)
        return result
    }

    func waitForTranscribeCall(_ call: Int) async {
        guard transcribeCalls < call else { return }
        await withCheckedContinuation { continuation in
            waitersByCall[call, default: []].append(continuation)
        }
    }

    func releaseTranscribeCall(_ call: Int) {
        releasedCalls.insert(call)
        releaseWaitersByCall.removeValue(forKey: call)?.resume()
    }

    private func signalTranscribeCall(_ call: Int) {
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

private actor StartInterruptedAudioProcessor: AudioProcessorProtocol {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startRelease: CheckedContinuation<Void, Never>?
    private var startCaptureEntered = false

    var audioLevel: Float { 0 }
    var isRecording: Bool { false }
    var recordingDeviceInfo: RecordingDeviceInfo? { nil }

    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func startCapture() async throws {
        startCaptureEntered = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()

        await withCheckedContinuation { continuation in
            startRelease = continuation
        }

        throw AudioProcessorError.recordingFailed("interrupted during subscribe")
    }

    func stopCapture() async throws -> URL {
        startRelease?.resume()
        startRelease = nil
        return URL(fileURLWithPath: "/tmp/interrupted-start.wav")
    }

    func waitForStartCapture() async {
        guard !startCaptureEntered else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor StopFailingLiveAudioProcessor: AudioProcessorProtocol {
    private let error: Error
    private var liveSampleSink: DictationAudioSampleSink?
    private var recording = false

    init(error: Error) {
        self.error = error
    }

    var audioLevel: Float { 0 }
    var isRecording: Bool { recording }
    var recordingDeviceInfo: RecordingDeviceInfo? { nil }

    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func startCapture() async throws {
        try await startCapture(sampleSink: nil)
    }

    func startCapture(sampleSink: DictationAudioSampleSink?) async throws {
        liveSampleSink = sampleSink
        recording = true
    }

    func stopCapture() async throws -> URL {
        recording = false
        liveSampleSink = nil
        throw error
    }

    func emitLiveSamples(_ samples: [Float]) {
        liveSampleSink?.onSamples(samples)
    }
}

private actor StartInterruptedDelayedStopAudioProcessor: AudioProcessorProtocol {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startRelease: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRelease: CheckedContinuation<Void, Never>?
    private var startCaptureEntered = false
    private var stopCaptureEntered = false

    var audioLevel: Float { 0 }
    var isRecording: Bool { false }
    var recordingDeviceInfo: RecordingDeviceInfo? { nil }

    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func startCapture() async throws {
        startCaptureEntered = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()

        await withCheckedContinuation { continuation in
            startRelease = continuation
        }

        throw AudioProcessorError.recordingFailed("interrupted during subscribe")
    }

    func stopCapture() async throws -> URL {
        stopCaptureEntered = true
        for waiter in stopWaiters {
            waiter.resume()
        }
        stopWaiters.removeAll()

        startRelease?.resume()
        startRelease = nil

        await withCheckedContinuation { continuation in
            stopRelease = continuation
        }

        return URL(fileURLWithPath: "/tmp/interrupted-start-delayed-stop.wav")
    }

    func waitForStartCapture() async {
        guard !startCaptureEntered else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForStopCapture() async {
        guard !stopCaptureEntered else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func allowStopCaptureToReturn() {
        stopRelease?.resume()
        stopRelease = nil
    }
}
