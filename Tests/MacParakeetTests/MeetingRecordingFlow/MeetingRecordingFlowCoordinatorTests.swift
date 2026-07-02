import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingRecordingFlowCoordinatorTests: XCTestCase {
    private var telemetry: FlowTelemetrySpy!

    override func setUp() {
        super.setUp()
        telemetry = FlowTelemetrySpy()
        Telemetry.configure(telemetry)
    }

    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        telemetry = nil
        super.tearDown()
    }

    func testAutoStopTriggerUsesNormalStopTranscribeFlow() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.holdMeetingFinalization()
        let completedTranscription = Transcription(
            fileName: output.displayName,
            filePath: output.mixedAudioURL.path,
            rawTranscript: "Auto-stopped meeting",
            status: .completed,
            sourceType: .meeting
        )
        await transcriptionService.configure(result: completedTranscription)

        var readyTranscriptions: [Transcription] = []
        var readySelections: [Bool] = []
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { transcription in
                readyTranscriptions.append(transcription)
            },
            onQueuedTranscriptionReady: { transcription, selectTranscription in
                readyTranscriptions.append(transcription)
                readySelections.append(selectTranscription)
            }
        )
        coordinator.testHook_enterRecording()

        XCTAssertTrue(coordinator.stopRecording(operationTrigger: .autoStop))
        await coordinator.testHook_waitForActionTask()

        let recordingSnapshot = await recordingService.snapshot()
        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertFalse(coordinator.isMeetingRecordingActive)
        XCTAssertEqual(recordingSnapshot.stopCallCount, 1)
        XCTAssertTrue(recordingSnapshot.completedTranscriptionSessionIDs.isEmpty)
        XCTAssertEqual(transcriptionSnapshot.prepareMeetingCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.finalizeMeetingCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.transcribeCallCount, 0)
        XCTAssertEqual(transcriptionSnapshot.preparedMeetingRecordings, [output])
        XCTAssertEqual(transcriptionSnapshot.finalizedMeetingRecordings, [output])
        XCTAssertTrue(readyTranscriptions.isEmpty)

        await transcriptionService.releaseMeetingFinalization()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()

        let completedSnapshot = await recordingService.snapshot()
        let completedTranscriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(completedSnapshot.completedTranscriptionSessionIDs, [output.sessionID])
        XCTAssertEqual(readyTranscriptions.map(\.id), completedTranscriptionSnapshot.finalizedMeetingTranscriptionIDs)
        XCTAssertEqual(readyTranscriptions.map(\.filePath), [completedTranscription.filePath])
        XCTAssertEqual(readySelections, [true])

        let operation = try XCTUnwrap(telemetry.snapshot().compactMap(\.meetingOperationPayload).last)
        XCTAssertEqual(operation.outcome, .success)
        XCTAssertEqual(operation.trigger, .autoStop)
        XCTAssertEqual(operation.durationSeconds, output.durationSeconds)
        XCTAssertEqual(operation.microphoneTrackPresent, true)
        XCTAssertEqual(operation.systemTrackPresent, true)
    }

    func testCanStartNextRecordingWhilePreviousFinalizeIsQueued() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.holdMeetingFinalization()

        var queuedSelections: [Bool] = []
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in },
            onQueuedTranscriptionReady: { _, selectTranscription in
                queuedSelections.append(selectTranscription)
            }
        )
        coordinator.testHook_enterRecording()

        XCTAssertTrue(coordinator.stopRecording(operationTrigger: .manual))
        await coordinator.testHook_waitForActionTask()
        XCTAssertEqual(coordinator.testHook_state, .idle)

        let nextGeneration = coordinator.startRecording(trigger: .manual)
        XCTAssertNotNil(nextGeneration)
        await coordinator.testHook_waitForActionTask()

        let recordingSnapshot = await recordingService.snapshot()
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertEqual(recordingSnapshot.startCallCount, 1)

        await transcriptionService.releaseMeetingFinalization()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()
        XCTAssertEqual(queuedSelections, [false])
    }

    func testLiveAskChatPersistsBeforeQueuedFinalizeTearsDownPanel() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.holdMeetingFinalization()
        let completedTranscription = Transcription(
            fileName: output.displayName,
            filePath: output.mixedAudioURL.path,
            rawTranscript: "Queued meeting transcript",
            status: .completed,
            sourceType: .meeting
        )
        await transcriptionService.configure(result: completedTranscription)
        let conversationRepo = MockChatConversationRepository()
        let llmService = MockLLMService()
        llmService.streamTokens = ["Answer saved"]

        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: conversationRepo,
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: llmService,
            pillViewModel: MeetingRecordingPillViewModel(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await coordinator.testHook_waitForActionTask()
        await coordinator.testHook_waitForActionTask()
        XCTAssertEqual(coordinator.testHook_state, .recording)

        let chatViewModel = try XCTUnwrap(coordinator.testHook_panelChatViewModel)
        chatViewModel.inputText = "What did I miss?"
        chatViewModel.sendMessage()
        for _ in 0..<20 where chatViewModel.isStreaming {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(chatViewModel.isStreaming)

        XCTAssertTrue(coordinator.stopRecording(operationTrigger: .manual))
        await coordinator.testHook_waitForActionTask()

        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertNil(coordinator.testHook_panelChatViewModel)
        XCTAssertEqual(conversationRepo.conversations.count, 1)
        let savedConversation = try XCTUnwrap(conversationRepo.conversations.first)
        XCTAssertEqual(savedConversation.title, "What did I miss?")
        XCTAssertEqual(savedConversation.messages, [
            ChatMessage(role: .user, content: "What did I miss?"),
            ChatMessage(role: .assistant, content: "Answer saved"),
        ])

        await transcriptionService.releaseMeetingFinalization()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()

        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(transcriptionSnapshot.finalizedMeetingTranscriptionIDs, [savedConversation.transcriptionId])
    }

    func testStartRecordingWhileActivelyRecordingIsRefused() {
        let coordinator = makeQuitTeardownCoordinator()
        coordinator.testHook_enterRecording()

        XCTAssertNil(coordinator.startRecording(trigger: .manual))
        XCTAssertEqual(coordinator.testHook_state, .recording)
    }

    func testCohereRecordingShowsLivePreviewUnsupportedCopy() async throws {
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: MeetingRecordingServiceSpy(output: makeRecordingOutput()),
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            speechEngineSelectionProvider: {
                SpeechEngineSelection(engine: .cohere, language: "ja")
            },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await coordinator.testHook_waitForActionTask()
        for _ in 0..<20 {
            if coordinator.testHook_panelViewModel?.liveTranscriptStatus == .previewUnsupported(engine: .cohere) {
                break
            }
            await Task.yield()
        }

        let panelViewModel = try XCTUnwrap(coordinator.testHook_panelViewModel)
        XCTAssertEqual(panelViewModel.liveTranscriptStatus, .previewUnsupported(engine: .cohere))
        XCTAssertEqual(panelViewModel.transcriptEmptyStateTitle, "Live preview off for Cohere")
        XCTAssertEqual(
            panelViewModel.transcriptEmptyStateDetail,
            "Cohere will transcribe after you stop recording."
        )
    }

    // MARK: - Quit-time pill teardown (fix/meeting-pill-lingers-on-quit)

    /// Hiding the floating pill for a quit decision must be flow-neutral: it
    /// only detaches the window, never stops or advances the recording. The
    /// AppKit window visibility itself isn't exercised here (the pill controller
    /// is only built when the `.showRecordingPill` effect runs, which the test
    /// hook deliberately skips), so this guards the invariant that matters —
    /// dismiss/restore can't accidentally tear down the recording.
    func testDismissAndRestoreFloatingPillDoNotDisturbRecordingFlow() {
        let coordinator = makeQuitTeardownCoordinator()
        coordinator.testHook_enterRecording()
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.isMeetingRecordingActive)

        coordinator.dismissFloatingPillForQuit()
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.isMeetingRecordingActive)

        coordinator.restoreFloatingPillIfRecording()
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.isMeetingRecordingActive)
    }

    /// Both calls are safe (no-ops) when idle, so the `applicationWillTerminate`
    /// safety-net path can call them unconditionally without crashing.
    func testDismissAndRestoreFloatingPillAreSafeWhenIdle() {
        let coordinator = makeQuitTeardownCoordinator()
        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertFalse(coordinator.isMeetingRecordingActive)

        coordinator.dismissFloatingPillForQuit()
        coordinator.restoreFloatingPillIfRecording()

        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertFalse(coordinator.isMeetingRecordingActive)
    }

    private func makeQuitTeardownCoordinator() -> MeetingRecordingFlowCoordinator {
        MeetingRecordingFlowCoordinator(
            meetingRecordingService: MeetingRecordingServiceSpy(output: makeRecordingOutput()),
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )
    }

    private func makeRecordingOutput() -> MeetingRecordingOutput {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let track = MeetingSourceAlignment.Track(
            firstHostTime: 1,
            lastHostTime: 2,
            startOffsetMs: 0,
            writtenFrameCount: 48_000,
            sampleRate: 48_000
        )
        return MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Design Review",
            folderURL: folder,
            mixedAudioURL: folder.appendingPathComponent("mixed.m4a"),
            microphoneAudioURL: folder.appendingPathComponent("microphone.m4a"),
            systemAudioURL: folder.appendingPathComponent("system.m4a"),
            durationSeconds: 42,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 1,
                microphone: track,
                system: track
            )
        )
    }
}

private actor MeetingRecordingServiceSpy: MeetingRecordingServiceProtocol {
    private let output: MeetingRecordingOutput
    var startCallCount = 0
    var stopCallCount = 0
    var completedTranscriptionSessionIDs: [UUID] = []

    init(output: MeetingRecordingOutput) {
        self.output = output
    }

    func startRecording(title: String?, sourceMode: MeetingAudioSourceMode?) async throws {
        startCallCount += 1
    }

    func stopRecording() async throws -> MeetingRecordingOutput {
        stopCallCount += 1
        return output
    }

    func completeTranscription(for recording: MeetingRecordingOutput) async {
        completedTranscriptionSessionIDs.append(recording.sessionID)
    }

    func finishTranscriptionAttempt(for recording: MeetingRecordingOutput) async {}

    func cancelRecording() async {}

    func pauseRecording() async {}

    func resumeRecording() async {}

    func setMicrophoneMuted(_ muted: Bool) async -> MeetingMicrophoneMuteState {
        MeetingMicrophoneMuteState(isMuted: muted, canMute: true)
    }

    func updateNotes(_ notes: String) async {}

    var isRecording: Bool { true }

    var isPaused: Bool { false }

    var micLevel: Float { 0 }

    var systemLevel: Float { 0 }

    var elapsedSeconds: Int { 0 }

    var captureMode: CaptureMode { .full }

    var isMicrophoneMuted: Bool { false }

    var canMuteMicrophone: Bool { true }

    var microphoneMuteState: MeetingMicrophoneMuteState {
        MeetingMicrophoneMuteState(isMuted: false, canMute: true)
    }

    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func snapshot() -> (startCallCount: Int, stopCallCount: Int, completedTranscriptionSessionIDs: [UUID]) {
        (
            startCallCount: startCallCount,
            stopCallCount: stopCallCount,
            completedTranscriptionSessionIDs: completedTranscriptionSessionIDs
        )
    }
}

private extension MockTranscriptionService {
    func meetingFlowSnapshot() -> (
        transcribeCallCount: Int,
        prepareMeetingCallCount: Int,
        finalizeMeetingCallCount: Int,
        lastMeetingRecording: MeetingRecordingOutput?,
        preparedMeetingRecordings: [MeetingRecordingOutput],
        finalizedMeetingRecordings: [MeetingRecordingOutput],
        finalizedMeetingTranscriptionIDs: [UUID]
    ) {
        (
            transcribeCallCount: transcribeCallCount,
            prepareMeetingCallCount: prepareMeetingCallCount,
            finalizeMeetingCallCount: finalizeMeetingCallCount,
            lastMeetingRecording: lastMeetingRecording,
            preparedMeetingRecordings: preparedMeetingRecordings,
            finalizedMeetingRecordings: finalizedMeetingRecordings,
            finalizedMeetingTranscriptionIDs: finalizedMeetingTranscriptionIDs
        )
    }
}

private final class FlowTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
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

private struct MeetingOperationPayload: Equatable {
    let outcome: ObservabilityOutcome
    let trigger: TelemetryMeetingOperationTrigger?
    let durationSeconds: Double?
    let microphoneTrackPresent: Bool?
    let systemTrackPresent: Bool?
}

private extension TelemetryEventSpec {
    var meetingOperationPayload: MeetingOperationPayload? {
        guard case .meetingOperation(
            _,
            _,
            let outcome,
            let trigger,
            _,
            let durationSeconds,
            _,
            _,
            let microphoneTrackPresent,
            let systemTrackPresent,
            _,
            _,
            _
        ) = self else {
            return nil
        }

        return MeetingOperationPayload(
            outcome: outcome,
            trigger: trigger,
            durationSeconds: durationSeconds,
            microphoneTrackPresent: microphoneTrackPresent,
            systemTrackPresent: systemTrackPresent
        )
    }
}

private final class NoOpLLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    func loadConfig() throws -> LLMProviderConfig? { nil }
    func saveConfig(_ config: LLMProviderConfig) throws {}
    func deleteConfig() throws {}
    func loadAPIKey() throws -> String? { nil }
    func loadAPIKey(for provider: LLMProviderID) throws -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
    func updateModelName(_ modelName: String) throws {}
}

private final class NoOpQuickPromptRepository: QuickPromptRepositoryProtocol, @unchecked Sendable {
    func save(_ prompt: QuickPrompt) throws {}
    func fetch(id: UUID) throws -> QuickPrompt? { nil }
    func fetchAll() throws -> [QuickPrompt] { [] }
    func fetchVisible() throws -> [QuickPrompt] { [] }
    func fetchPinned() throws -> [QuickPrompt] { [] }
    func delete(id: UUID) throws -> Bool { false }
    func toggleVisibility(id: UUID) throws {}
    func setPinned(id: UUID, isPinned: Bool) throws -> SetPinnedResult { .notFound }
    func reorder(ids: [UUID], pinned: Bool) throws {}
    func seedIfNeeded() throws {}
    func restoreBuiltInDefaults() throws {}
    func restoreBuiltInDefault(id: UUID) throws {}
    func applyImport(
        _ bundle: QuickPromptBundle,
        mode: QuickPromptImport.Mode,
        dryRun: Bool
    ) throws -> QuickPromptImport.Summary {
        QuickPromptImport.Summary(added: 0, updated: 0, deleted: 0, unchanged: 0)
    }
}
