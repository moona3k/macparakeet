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
        let expectedTranscription = Transcription(
            id: UUID(),
            fileName: output.displayName,
            filePath: output.mixedAudioURL.path,
            rawTranscript: "Auto-stopped meeting",
            status: .completed,
            sourceType: .meeting
        )
        await transcriptionService.configure(result: expectedTranscription)

        var readyTranscriptions: [Transcription] = []
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
            }
        )
        coordinator.testHook_enterRecording()

        XCTAssertTrue(coordinator.stopRecording(operationTrigger: .autoStop))
        await coordinator.testHook_waitForActionTask()

        let recordingSnapshot = await recordingService.snapshot()
        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(recordingSnapshot.stopCallCount, 1)
        XCTAssertEqual(recordingSnapshot.completedTranscriptionSessionIDs, [output.sessionID])
        XCTAssertEqual(transcriptionSnapshot.transcribeCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.lastMeetingRecording, output)
        XCTAssertEqual(readyTranscriptions.map(\.id), [expectedTranscription.id])
        XCTAssertEqual(readyTranscriptions.map(\.filePath), [expectedTranscription.filePath])

        let operation = try XCTUnwrap(telemetry.snapshot().compactMap(\.meetingOperationPayload).last)
        XCTAssertEqual(operation.outcome, .success)
        XCTAssertEqual(operation.trigger, .autoStop)
        XCTAssertEqual(operation.durationSeconds, output.durationSeconds)
        XCTAssertEqual(operation.microphoneTrackPresent, true)
        XCTAssertEqual(operation.systemTrackPresent, true)
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
    var stopCallCount = 0
    var completedTranscriptionSessionIDs: [UUID] = []

    init(output: MeetingRecordingOutput) {
        self.output = output
    }

    func startRecording(title: String?, sourceMode: MeetingAudioSourceMode?) async throws {}

    func stopRecording() async throws -> MeetingRecordingOutput {
        stopCallCount += 1
        return output
    }

    func completeTranscription(for recording: MeetingRecordingOutput) async {
        completedTranscriptionSessionIDs.append(recording.sessionID)
    }

    func finishTranscriptionAttempt(for recording: MeetingRecordingOutput) async {}

    func discardStoppedRecording(_ recording: MeetingRecordingOutput) async {}

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

    func snapshot() -> (stopCallCount: Int, completedTranscriptionSessionIDs: [UUID]) {
        (
            stopCallCount: stopCallCount,
            completedTranscriptionSessionIDs: completedTranscriptionSessionIDs
        )
    }
}

private extension MockTranscriptionService {
    func meetingFlowSnapshot() -> (transcribeCallCount: Int, lastMeetingRecording: MeetingRecordingOutput?) {
        (
            transcribeCallCount: transcribeCallCount,
            lastMeetingRecording: lastMeetingRecording
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
