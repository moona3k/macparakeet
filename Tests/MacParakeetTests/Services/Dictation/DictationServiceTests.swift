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

        let operation = try XCTUnwrap(dictationOperationProps(in: telemetry.snapshot()).last)
        XCTAssertEqual(operation["speech_engine"], "whisper")
        XCTAssertEqual(operation["engine_variant"], SpeechEnginePreference.defaultWhisperModelVariant)
        XCTAssertEqual(operation["language"], "ko")
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
        _ = try await service.stopRecording()

        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
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

    private static func isRecording(_ state: DictationState) -> Bool {
        if case .recording = state { return true }
        return false
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
