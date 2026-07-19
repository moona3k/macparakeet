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

    func testLivePreviewUsesReadingParagraphs() {
        let sentenceWords = [
            ("First", 0, 100), ("sentence", 120, 220), ("ends.", 240, 340),
            ("Second", 400, 500), ("sentence", 520, 620), ("ends.", 640, 740),
            ("Third", 800, 900), ("sentence", 920, 1_020), ("ends.", 1_040, 1_140),
            ("Fourth", 1_200, 1_300), ("sentence", 1_320, 1_420), ("ends.", 1_440, 1_540),
        ]
        let words = sentenceWords.map { text, startMs, endMs in
            WordTimestamp(
                word: text,
                startMs: startMs,
                endMs: endMs,
                confidence: 0.99,
                speakerId: AudioSource.microphone.rawValue
            )
        }
        let update = MeetingTranscriptUpdate(
            words: words,
            speakers: [SpeakerInfo(id: AudioSource.microphone.rawValue, label: "Me")]
        )

        let lines = MeetingRecordingFlowCoordinator.testHook_makePreviewLines(from: update)

        XCTAssertEqual(lines.map(\.text), [
            "First sentence ends. Second sentence ends. Third sentence ends.",
            "Fourth sentence ends.",
        ])
        XCTAssertEqual(lines.map(\.timestamp), ["0:00", "0:01"])
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
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)

        var readyTranscriptions: [Transcription] = []
        var readySelections: [Bool] = []
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: settlementHarness.settlement,
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
        try await waitForMeetingFinalizeCall(on: transcriptionService)

        let recordingSnapshot = await recordingService.snapshot()
        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertFalse(coordinator.isMeetingRecordingActive)
        XCTAssertEqual(recordingSnapshot.stopCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.prepareMeetingCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.finalizeMeetingCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.transcribeCallCount, 0)
        XCTAssertEqual(transcriptionSnapshot.preparedMeetingRecordings, [output])
        XCTAssertEqual(transcriptionSnapshot.finalizedMeetingRecordings, [output])
        XCTAssertTrue(readyTranscriptions.isEmpty)

        await transcriptionService.releaseMeetingFinalization()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()

        let completedTranscriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(readyTranscriptions.map(\.id), completedTranscriptionSnapshot.finalizedMeetingTranscriptionIDs)
        XCTAssertEqual(readyTranscriptions.map(\.filePath), [completedTranscription.filePath])
        XCTAssertEqual(readySelections, [true])
        XCTAssertEqual(settlementHarness.lockStore.deletes, [output.folderURL])

        let operation = try XCTUnwrap(telemetry.snapshot().compactMap(\.meetingOperationPayload).last)
        XCTAssertEqual(operation.outcome, .success)
        XCTAssertEqual(operation.trigger, .autoStop)
        XCTAssertEqual(operation.durationSeconds, output.durationSeconds)
        XCTAssertEqual(operation.microphoneTrackPresent, true)
        XCTAssertEqual(operation.systemTrackPresent, true)
    }

    func testQueuedFinalizationFailurePersistsRetryableRowAndPostsOneNotification() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.configureMeetingFinalization(error: FlowTestError.finalizationFailed)
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)

        var retryNotifications: [TranscriptionCompletionNotifier.Content] = []
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: settlementHarness.settlement,
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in },
            onQueuedTranscriptionFailed: { content in
                retryNotifications.append(content)
            }
        )
        coordinator.testHook_enterRecording()

        XCTAssertTrue(coordinator.stopRecording(operationTrigger: .manual))
        await coordinator.testHook_waitForActionTask()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()

        let rows = try settlementHarness.transcriptionRepo.fetchAll(limit: nil)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.status, .error)
        XCTAssertEqual(row.sourceType, .meeting)
        XCTAssertEqual(row.errorMessage, FlowTestError.finalizationFailed.localizedDescription)
        XCTAssertEqual(retryNotifications, [TranscriptionCompletionNotifier.meetingNeedsRetryContent()])
        XCTAssertTrue(settlementHarness.lockStore.deletes.isEmpty)
    }

    func testRetryMeetingFinalizationReusesPersistedRowAndAudioFolder() async throws {
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.holdMeetingFinalization()
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)
        let folderURL = try makeArchivedRetryFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let playbackURL = folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        let failed = Transcription(
            id: UUID(),
            fileName: "Retry meeting",
            filePath: playbackURL.path,
            meetingArtifactFolderPath: folderURL.path,
            durationMs: 12_000,
            status: .error,
            errorMessage: "Previous failure",
            sourceType: .meeting
        )
        try settlementHarness.transcriptionRepo.save(failed)
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: MeetingRecordingServiceSpy(output: makeRecordingOutput()),
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: settlementHarness.settlement,
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        try await coordinator.retryMeetingFinalization(failed)
        try await waitForTranscriptionStatus(
            id: failed.id,
            in: settlementHarness.transcriptionRepo,
            status: .processing
        )

        await transcriptionService.releaseMeetingFinalization()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()

        let completed = try XCTUnwrap(settlementHarness.transcriptionRepo.fetch(id: failed.id))
        XCTAssertEqual(completed.status, .completed)
        XCTAssertNil(completed.errorMessage)
        XCTAssertEqual(settlementHarness.transcriptionRepo.transcriptions.map(\.id), [failed.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertEqual(settlementHarness.lockStore.deletes, [folderURL.standardizedFileURL])

        let snapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(snapshot.prepareMeetingCallCount, 0)
        XCTAssertEqual(snapshot.finalizeMeetingCallCount, 1)
        XCTAssertEqual(snapshot.finalizedMeetingTranscriptionIDs, [failed.id])
        XCTAssertEqual(snapshot.finalizedMeetingRecordings.first?.displayName, failed.fileName)
        XCTAssertEqual(snapshot.finalizedMeetingRecordings.first?.durationSeconds, 12)
    }

    func testCaptureFailureSignalUsesStopTranscribeFlowExactlyOnce() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: settlementHarness.settlement,
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        try await waitForStartCall(on: recordingService, coordinator: coordinator)

        await recordingService.emitCaptureFailure()
        await recordingService.emitCaptureFailure()
        try await waitForStopCall(on: recordingService, coordinator: coordinator)

        let recordingSnapshot = await recordingService.snapshot()
        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertEqual(recordingSnapshot.stopCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.prepareMeetingCallCount, 1)
    }

    func testStopWhileServiceStartIsPendingSuppressesLateStartSideEffects() async throws {
        let recordingService = MeetingRecordingServiceSpy(
            output: makeRecordingOutput(),
            blocksStart: true
        )
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await recordingService.waitUntilStartCalled()
        XCTAssertEqual(coordinator.testHook_state, .starting)

        XCTAssertTrue(coordinator.stopRecording(operationTrigger: .manual))
        try await waitForStopCall(on: recordingService, coordinator: coordinator)
        XCTAssertEqual(coordinator.testHook_state, .idle)

        await recordingService.releaseStart()
        try await Task.sleep(for: .milliseconds(50))

        let eventNames = telemetry.snapshot().map(\.name)
        XCTAssertFalse(eventNames.contains(.meetingRecordingStarted))
        XCTAssertFalse(eventNames.contains(.meetingRecordingFailed))
        XCTAssertEqual(coordinator.testHook_state, .idle)
    }

    func testCaptureFailureSignalWhilePausedUsesStopTranscribeFlow() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)
        let pillViewModel = MeetingRecordingPillViewModel()
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: pillViewModel,
            meetingRecordingSettlement: settlementHarness.settlement,
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        try await waitForStartCall(on: recordingService, coordinator: coordinator)
        coordinator.togglePause()
        try await waitForPillState(pillViewModel, .paused)

        await recordingService.emitCaptureFailure()
        try await waitForStopCall(on: recordingService, coordinator: coordinator)

        let recordingSnapshot = await recordingService.snapshot()
        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(coordinator.testHook_state, .idle)
        XCTAssertEqual(recordingSnapshot.stopCallCount, 1)
        XCTAssertEqual(transcriptionSnapshot.prepareMeetingCallCount, 1)
    }

    func testStaleGenerationCaptureFailureSignalIsIgnored() async throws {
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )
        coordinator.testHook_enterRecording()
        let staleGeneration = coordinator.testHook_generation - 1

        coordinator.testHook_startCaptureFailureObservation(generation: staleGeneration)
        await recordingService.emitCaptureFailure()
        await coordinator.testHook_waitForCaptureFailureObservationTask()

        let recordingSnapshot = await recordingService.snapshot()
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertEqual(recordingSnapshot.stopCallCount, 0)
    }

    func testCanStartNextRecordingWhilePreviousFinalizeIsQueued() async throws {
        let output = makeRecordingOutput()
        let recordingService = MeetingRecordingServiceSpy(output: output)
        let transcriptionService = MockTranscriptionService()
        await transcriptionService.holdMeetingFinalization()
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)

        var queuedSelections: [Bool] = []
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: settlementHarness.settlement,
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
        XCTAssertEqual(settlementHarness.lockStore.deletes, [output.folderURL])
    }

    func testManualStartPassesProbableCalendarSnapshotWithoutChangingTitle() async throws {
        let expectedSnapshot = MeetingCalendarSnapshot(
            confidence: .probable,
            eventIdentifier: "evt-manual",
            externalId: "external-manual",
            title: "Manual Calendar Overlap",
            scheduledStartAt: Date().addingTimeInterval(-120),
            scheduledEndAt: Date().addingTimeInterval(1200),
            attendees: [MeetingCalendarPerson(name: "Alice", email: "alice@example.com")],
            organizer: MeetingCalendarPerson(name: "Omar", email: "omar@example.com"),
            meetingURL: "https://zoom.us/j/123456789",
            meetingService: "Zoom"
        )
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            probableCalendarSnapshotProvider: { expectedSnapshot },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await coordinator.testHook_waitForActionTask()

        let snapshot = await recordingService.snapshot()
        XCTAssertEqual(snapshot.startCallCount, 1)
        XCTAssertEqual(snapshot.startTitles.count, 1)
        XCTAssertNil(snapshot.startTitles[0])
        XCTAssertEqual(snapshot.calendarEventSnapshots.first ?? nil, expectedSnapshot)
    }

    func testHotkeyStartUsesLateAssignedProbableCalendarSnapshotProvider() async throws {
        let expectedSnapshot = MeetingCalendarSnapshot(
            confidence: .probable,
            eventIdentifier: "evt-hotkey",
            title: "Hotkey Calendar Overlap",
            scheduledStartAt: Date().addingTimeInterval(-120),
            scheduledEndAt: Date().addingTimeInterval(1200),
            meetingURL: "https://meet.google.com/abc-defg-hij",
            meetingService: "Google Meet"
        )
        let holder = ProbableCalendarSnapshotHolder()
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            probableCalendarSnapshotProvider: { holder.snapshot },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )
        holder.snapshot = expectedSnapshot

        XCTAssertNotNil(coordinator.startRecording(trigger: .hotkey))
        await coordinator.testHook_waitForActionTask()

        let snapshot = await recordingService.snapshot()
        XCTAssertEqual(snapshot.startCallCount, 1)
        XCTAssertEqual(snapshot.startTitles, [nil])
        XCTAssertEqual(snapshot.calendarEventSnapshots.first ?? nil, expectedSnapshot)
    }

    func testCalendarStartPassesConfirmedSnapshotAsTitleAndContext() async throws {
        let expectedSnapshot = MeetingCalendarSnapshot(
            confidence: .confirmed,
            eventIdentifier: "evt-confirmed",
            title: "Confirmed Calendar Start",
            scheduledStartAt: Date(),
            scheduledEndAt: Date().addingTimeInterval(1800)
        )
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            probableCalendarSnapshotProvider: { nil },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startFromCalendar(calendarEventSnapshot: expectedSnapshot))
        await coordinator.testHook_waitForActionTask()

        let snapshot = await recordingService.snapshot()
        XCTAssertEqual(snapshot.startTitles, ["Confirmed Calendar Start"])
        XCTAssertEqual(snapshot.calendarEventSnapshots.first ?? nil, expectedSnapshot)
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
        let settlementHarness = await makeSettlementHarness(transcriptionService: transcriptionService)
        let conversationRepo = MockChatConversationRepository()
        let llmService = MockLLMService()
        llmService.streamTokens = ["Answer saved"]

        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: transcriptionService,
            permissionService: MockPermissionService(),
            transcriptionRepo: settlementHarness.transcriptionRepo,
            conversationRepo: conversationRepo,
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            llmService: llmService,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: settlementHarness.settlement,
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
        XCTAssertEqual(
            savedConversation.messages,
            [
                ChatMessage(role: .user, content: "What did I miss?"),
                ChatMessage(role: .assistant, content: "Answer saved"),
            ])

        await transcriptionService.releaseMeetingFinalization()
        await coordinator.testHook_waitForMeetingTranscriptionQueue()

        let transcriptionSnapshot = await transcriptionService.meetingFlowSnapshot()
        XCTAssertEqual(transcriptionSnapshot.finalizedMeetingTranscriptionIDs, [savedConversation.transcriptionId])
        XCTAssertEqual(settlementHarness.lockStore.deletes, [output.folderURL])
    }

    func testStartRecordingWhileActivelyRecordingIsRefused() {
        let coordinator = makeQuitTeardownCoordinator()
        coordinator.testHook_enterRecording()

        XCTAssertNil(coordinator.startRecording(trigger: .manual))
        XCTAssertEqual(coordinator.testHook_state, .recording)
    }

    func testStartRecordingCapturesStartContextForDiscoveredStartPaths() async throws {
        let app = MeetingStartContext.FrontmostApplication(
            bundleIdentifier: "COM.Example.MeetingApp",
            localizedName: "Meeting App"
        )

        let manualService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let manualCoordinator = makeStartContextCoordinator(
            recordingService: manualService,
            sourceMode: .microphoneOnly,
            frontmostApplication: app
        )
        XCTAssertNotNil(manualCoordinator.startRecording(trigger: .manual))
        try await waitForStartCall(on: manualService, coordinator: manualCoordinator)
        var serviceSnapshot = await manualService.snapshot()
        var start = try XCTUnwrap(serviceSnapshot.startCalls.first)
        XCTAssertNil(start.title)
        XCTAssertEqual(start.sourceMode, .microphoneOnly)
        XCTAssertEqual(start.startContext?.triggerKind, .manual)
        XCTAssertEqual(start.startContext?.frontmostApplication, app)
        XCTAssertEqual(start.startContext?.sourceMode, .microphoneOnly)

        let hotkeyService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let hotkeyCoordinator = makeStartContextCoordinator(
            recordingService: hotkeyService,
            sourceMode: .microphoneAndSystem,
            frontmostApplication: app
        )
        XCTAssertNotNil(hotkeyCoordinator.startRecording(trigger: .hotkey))
        try await waitForStartCall(on: hotkeyService, coordinator: hotkeyCoordinator)
        serviceSnapshot = await hotkeyService.snapshot()
        start = try XCTUnwrap(serviceSnapshot.startCalls.first)
        XCTAssertNil(start.title)
        XCTAssertEqual(start.sourceMode, .microphoneAndSystem)
        XCTAssertEqual(start.startContext?.triggerKind, .hotkey)
        XCTAssertEqual(start.startContext?.frontmostApplication, app)
        XCTAssertEqual(start.startContext?.sourceMode, .microphoneAndSystem)

        let calendarService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let calendarCoordinator = makeStartContextCoordinator(
            recordingService: calendarService,
            sourceMode: .systemOnly,
            frontmostApplication: app
        )
        XCTAssertNotNil(calendarCoordinator.startFromCalendar(title: "Roadmap Review"))
        try await waitForStartCall(on: calendarService, coordinator: calendarCoordinator)
        serviceSnapshot = await calendarService.snapshot()
        start = try XCTUnwrap(serviceSnapshot.startCalls.first)
        XCTAssertEqual(start.title, "Roadmap Review")
        XCTAssertEqual(start.sourceMode, .systemOnly)
        XCTAssertEqual(start.startContext?.triggerKind, .calendarAutoStart)
        XCTAssertEqual(start.startContext?.frontmostApplication, app)
        XCTAssertEqual(start.startContext?.sourceMode, .systemOnly)
    }

    func testCohereRecordingShowsLivePreviewUnsupportedCopy() async throws {
        let liveSelection = SpeechEngineSelection(engine: .cohere, language: "ja")
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: MeetingRecordingServiceSpy(
                output: makeRecordingOutput(),
                activeSpeechEngineSelection: liveSelection,
                activeMeetingSpeechPlan: MeetingSpeechPlan(
                    preview: nil,
                    final: liveSelection
                )
            ),
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            speechEngineSelectionProvider: { liveSelection },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await coordinator.testHook_waitForActionTask()
        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) <= .seconds(1) {
            if coordinator.testHook_panelViewModel?.liveTranscriptStatus == .previewUnsupported(engine: .cohere) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let panelViewModel = try XCTUnwrap(coordinator.testHook_panelViewModel)
        XCTAssertEqual(panelViewModel.liveTranscriptStatus, .previewUnsupported(engine: .cohere))
        XCTAssertEqual(panelViewModel.transcriptEmptyStateTitle, "Live preview off for Cohere")
        XCTAssertEqual(
            panelViewModel.transcriptEmptyStateDetail,
            "Audio will be transcribed after you stop recording."
        )
    }

    func testMeetingWarmUpUsesCapturedPreviewSelection() async throws {
        let stt = MockSTTClient()
        await stt.setReady(false)
        let meetingSelection = SpeechEngineSelection(engine: .parakeet)
        let changedPreference = SpeechEngineSelection(engine: .cohere, language: "fr")
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: MeetingRecordingServiceSpy(
                output: makeRecordingOutput(),
                activeSpeechEngineSelection: meetingSelection,
                activeMeetingSpeechPlan: MeetingSpeechPlan(
                    preview: meetingSelection,
                    final: meetingSelection
                )
            ),
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            sttManager: stt,
            speechEngineSelectionProvider: { changedPreference },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await coordinator.testHook_waitForActionTask()

        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) <= .seconds(1) {
            if await stt.routedWarmUpSelectionsSnapshot() == [meetingSelection] {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let routedWarmUps = await stt.routedWarmUpSelectionsSnapshot()
        let backgroundWarmUps = await stt.backgroundWarmUpCallCountSnapshot()
        XCTAssertEqual(routedWarmUps, [meetingSelection])
        XCTAssertEqual(backgroundWarmUps, 0)
    }

    func testMeetingStartupDoesNotWarmUnsupportedLiveEngineAndAttributesFinalRoute() async throws {
        let stt = MockSTTClient()
        await stt.setReady(false)
        let pinnedSelection = SpeechEngineSelection(engine: .cohere, language: "fr")
        let finalSelection = SpeechEngineSelection(engine: .parakeet)
        let recordingService = MeetingRecordingServiceSpy(
            output: makeRecordingOutput(),
            activeSpeechEngineSelection: pinnedSelection,
            activeMeetingSpeechPlan: MeetingSpeechPlan(preview: nil, final: finalSelection)
        )
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            sttManager: stt,
            speechEngineSelectionProvider: { finalSelection },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        await coordinator.testHook_waitForActionTask()

        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) <= .seconds(1) {
            if coordinator.testHook_panelViewModel?.liveTranscriptStatus == .previewUnsupported(engine: .cohere) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let routedWarmUps = await stt.routedWarmUpSelectionsSnapshot()
        XCTAssertEqual(routedWarmUps, [])
        XCTAssertEqual(
            coordinator.testHook_panelViewModel?.liveTranscriptStatus,
            .previewUnsupported(engine: .cohere)
        )
        XCTAssertEqual(
            coordinator.testHook_panelViewModel?.speechRouteAttribution,
            "Live preview: Off (Cohere (fr)) · Final transcript: Parakeet after recording ends"
        )
    }

    func testMeetingReadinessUsesEnginePinnedByStartedSession() async throws {
        let stt = MockSTTClient()
        let pinnedSelection = SpeechEngineSelection(engine: .parakeet)
        let changedPreference = SpeechEngineSelection(engine: .cohere, language: "fr")
        let recordingService = MeetingRecordingServiceSpy(
            output: makeRecordingOutput(),
            activeSpeechEngineSelection: pinnedSelection,
            activeMeetingSpeechPlan: MeetingSpeechPlan(
                preview: pinnedSelection,
                final: changedPreference
            )
        )
        let coordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            sttManager: stt,
            speechEngineSelectionProvider: { changedPreference },
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )

        XCTAssertNotNil(coordinator.startRecording(trigger: .manual))
        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) <= .seconds(1) {
            if await stt.routedReadinessSelectionsSnapshot().contains(pinnedSelection) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let readinessSelections = await stt.routedReadinessSelectionsSnapshot()
        XCTAssertTrue(readinessSelections.contains(pinnedSelection))
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

    func testStartWithFloatingPillHiddenStillStartsRecordingFlow() async throws {
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let visibility = FloatingPillVisibilityProbe(shouldShow: false)
        let coordinator = makeQuitTeardownCoordinator(
            recordingService: recordingService,
            shouldShowFloatingMeetingPill: { visibility.shouldShow }
        )

        XCTAssertNotNil(coordinator.startRecording())
        try await waitForStartCall(on: recordingService, coordinator: coordinator)

        let snapshot = await recordingService.snapshot()
        XCTAssertEqual(snapshot.startCallCount, 1)
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.isMeetingRecordingActive)
        XCTAssertTrue(coordinator.testHook_hasFloatingPillController)
        XCTAssertFalse(coordinator.testHook_isFloatingPillVisible)
        XCTAssertFalse(coordinator.testHook_isMeetingPanelVisible)
    }

    func testStartRecordingCanPresentLivePanelWhenReady() async throws {
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let coordinator = makeQuitTeardownCoordinator(recordingService: recordingService)

        XCTAssertNotNil(coordinator.startRecording(presentLivePanelWhenReady: true))
        try await waitForStartCall(on: recordingService, coordinator: coordinator)

        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.testHook_isMeetingPanelVisible)
    }

    func testRefreshingFloatingPillVisibilityDoesNotDisturbRecordingFlow() async throws {
        let recordingService = MeetingRecordingServiceSpy(output: makeRecordingOutput())
        let visibility = FloatingPillVisibilityProbe(shouldShow: false)
        let coordinator = makeQuitTeardownCoordinator(
            recordingService: recordingService,
            shouldShowFloatingMeetingPill: { visibility.shouldShow }
        )

        XCTAssertNotNil(coordinator.startRecording())
        try await waitForStartCall(on: recordingService, coordinator: coordinator)
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertFalse(coordinator.testHook_isFloatingPillVisible)

        visibility.shouldShow = true
        coordinator.refreshFloatingPillVisibility()

        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.testHook_isFloatingPillVisible)

        visibility.shouldShow = false
        coordinator.refreshFloatingPillVisibility()

        let snapshot = await recordingService.snapshot()
        XCTAssertEqual(snapshot.startCallCount, 1)
        XCTAssertEqual(snapshot.stopCallCount, 0)
        XCTAssertEqual(coordinator.testHook_state, .recording)
        XCTAssertTrue(coordinator.isMeetingRecordingActive)
        XCTAssertFalse(coordinator.testHook_isFloatingPillVisible)
    }

    private func makeQuitTeardownCoordinator(
        recordingService: MeetingRecordingServiceSpy? = nil,
        shouldShowFloatingMeetingPill: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> MeetingRecordingFlowCoordinator {
        let recordingService = recordingService ?? MeetingRecordingServiceSpy(output: makeRecordingOutput())
        return MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            shouldShowFloatingMeetingPill: shouldShowFloatingMeetingPill,
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )
    }

    private func makeStartContextCoordinator(
        recordingService: MeetingRecordingServiceSpy,
        sourceMode: MeetingAudioSourceMode,
        frontmostApplication: MeetingStartContext.FrontmostApplication?
    ) -> MeetingRecordingFlowCoordinator {
        MeetingRecordingFlowCoordinator(
            meetingRecordingService: recordingService,
            transcriptionService: MockTranscriptionService(),
            permissionService: MockPermissionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            conversationRepo: MockChatConversationRepository(),
            quickPromptRepo: NoOpQuickPromptRepository(),
            configStore: NoOpLLMConfigStore(),
            meetingAudioSourceModeProvider: { sourceMode },
            frontmostApplicationProvider: StaticFrontmostApplicationProvider(frontmostApplication),
            llmService: nil,
            pillViewModel: MeetingRecordingPillViewModel(),
            meetingRecordingSettlement: makeSettlement(),
            onMenuBarIconUpdate: { _ in },
            onTranscriptionReady: { _ in }
        )
    }

    private func makeSettlement() -> MeetingRecordingSettlement {
        MeetingRecordingSettlement(
            lockFileStore: FlowRecordingLockFileStore(),
            transcriptionRepo: MockTranscriptionRepository()
        )
    }

    private func makeSettlementHarness(
        transcriptionService: MockTranscriptionService
    ) async -> (
        transcriptionRepo: MockTranscriptionRepository,
        lockStore: FlowRecordingLockFileStore,
        settlement: MeetingRecordingSettlement
    ) {
        let transcriptionRepo = MockTranscriptionRepository()
        await transcriptionService.persistFinalizedMeetings(to: transcriptionRepo)
        let lockStore = FlowRecordingLockFileStore()
        return (
            transcriptionRepo,
            lockStore,
            MeetingRecordingSettlement(
                lockFileStore: lockStore,
                transcriptionRepo: transcriptionRepo
            )
        )
    }

    private func waitForStartCall(
        on service: MeetingRecordingServiceSpy,
        coordinator: MeetingRecordingFlowCoordinator
    ) async throws {
        for _ in 0..<3 {
            await coordinator.testHook_waitForActionTask()
            let snapshot = await service.snapshot()
            if snapshot.startCallCount > 0 {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected recording service to receive startRecording.")
    }

    private func waitForStopCall(
        on service: MeetingRecordingServiceSpy,
        coordinator: MeetingRecordingFlowCoordinator,
        expectedCount: Int = 1
    ) async throws {
        let startedAt = ContinuousClock.now
        while true {
            await coordinator.testHook_waitForActionTask()
            let snapshot = await service.snapshot()
            if snapshot.stopCallCount >= expectedCount {
                return
            }
            if startedAt.duration(to: .now) > .seconds(1) {
                XCTFail("Expected recording service to receive stopRecording.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForPillState(
        _ pillViewModel: MeetingRecordingPillViewModel,
        _ expectedState: MeetingRecordingPillViewModel.PillState
    ) async throws {
        let startedAt = ContinuousClock.now
        while pillViewModel.state != expectedState {
            if startedAt.duration(to: .now) > .seconds(1) {
                XCTFail("Timed out waiting for pill state \(expectedState); latest state: \(pillViewModel.state)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForMeetingFinalizeCall(
        on service: MockTranscriptionService,
        expectedCount: Int = 1
    ) async throws {
        let startedAt = ContinuousClock.now
        while true {
            let snapshot = await service.meetingFlowSnapshot()
            if snapshot.finalizeMeetingCallCount >= expectedCount {
                return
            }
            if startedAt.duration(to: .now) > .seconds(1) {
                XCTFail("Expected queued meeting finalization to start.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForTranscriptionStatus(
        id: UUID,
        in repo: MockTranscriptionRepository,
        status: Transcription.TranscriptionStatus
    ) async throws {
        let startedAt = ContinuousClock.now
        while true {
            let transcription = try XCTUnwrap(repo.fetch(id: id))
            if transcription.status == status {
                XCTAssertNil(transcription.errorMessage)
                return
            }
            if startedAt.duration(to: .now) > .seconds(1) {
                XCTFail(
                    "Timed out waiting for transcription \(id) status \(status); latest status: \(transcription.status)"
                )
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
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
            microphoneAudioURL: folder.appendingPathComponent("microphone-raw.m4a"),
            systemAudioURL: folder.appendingPathComponent("system-raw.m4a"),
            durationSeconds: 42,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 1,
                microphone: track,
                system: track
            )
        )
    }

    private func makeArchivedRetryFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meeting-retry-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let playbackURL = folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        try Data("audio".utf8).write(to: playbackURL)
        try MeetingRecordingMetadataStore.save(
            MeetingRecordingMetadata(
                sourceAlignment: MeetingSourceAlignment(
                    meetingOriginHostTime: nil,
                    microphone: nil,
                    system: nil
                )
            ),
            folderURL: folder
        )
        return folder
    }
}

private enum FlowTestError: LocalizedError {
    case finalizationFailed

    var errorDescription: String? {
        switch self {
        case .finalizationFailed:
            return "Finalization failed"
        }
    }
}

@MainActor
private final class FloatingPillVisibilityProbe {
    var shouldShow: Bool

    init(shouldShow: Bool) {
        self.shouldShow = shouldShow
    }
}

private struct StaticFrontmostApplicationProvider: FrontmostApplicationProviding {
    private let frontmostApplication: MeetingStartContext.FrontmostApplication?

    init(_ frontmostApplication: MeetingStartContext.FrontmostApplication?) {
        self.frontmostApplication = frontmostApplication
    }

    @MainActor
    func currentFrontmostApplication() -> MeetingStartContext.FrontmostApplication? {
        frontmostApplication
    }
}

private actor MeetingRecordingServiceSpy: MeetingRecordingServiceProtocol {
    struct StartCall: Sendable, Equatable {
        let title: String?
        let sourceMode: MeetingAudioSourceMode?
        let startContext: MeetingStartContext?
        let calendarEventSnapshot: MeetingCalendarSnapshot?
    }

    private let output: MeetingRecordingOutput
    private let blocksStart: Bool
    let activeSpeechEngineSelection: SpeechEngineSelection?
    let activeMeetingSpeechPlan: MeetingSpeechPlan?
    var startCallCount = 0
    var startCalls: [StartCall] = []
    var stopCallCount = 0
    var startTitles: [String?] = []
    var calendarEventSnapshots: [MeetingCalendarSnapshot?] = []
    private var paused = false
    private var captureFailureSessionID = UUID()
    private var captureFailureSignaled = false
    private var captureFailureContinuations: [UUID: AsyncStream<MeetingCaptureFailureSignal>.Continuation] = [:]
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startObservationContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        output: MeetingRecordingOutput,
        activeSpeechEngineSelection: SpeechEngineSelection? = nil,
        activeMeetingSpeechPlan: MeetingSpeechPlan? = nil,
        blocksStart: Bool = false
    ) {
        self.output = output
        self.activeSpeechEngineSelection = activeSpeechEngineSelection
        self.activeMeetingSpeechPlan = activeMeetingSpeechPlan
        self.blocksStart = blocksStart
    }

    func startRecording(
        title: String?,
        sourceMode: MeetingAudioSourceMode?,
        startContext: MeetingStartContext?,
        calendarEventSnapshot: MeetingCalendarSnapshot?
    ) async throws {
        startCallCount += 1
        startCalls.append(
            StartCall(
                title: title,
                sourceMode: sourceMode,
                startContext: startContext,
                calendarEventSnapshot: calendarEventSnapshot
            ))
        startTitles.append(title)
        calendarEventSnapshots.append(calendarEventSnapshot)
        paused = false
        resetCaptureFailureObservationState()
        let observers = startObservationContinuations
        startObservationContinuations.removeAll()
        for observer in observers {
            observer.resume()
        }
        if blocksStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
    }

    func waitUntilStartCalled() async {
        guard startCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startObservationContinuations.append(continuation)
        }
    }

    func releaseStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }

    func stopRecording() async throws -> MeetingRecordingOutput {
        stopCallCount += 1
        paused = false
        resetCaptureFailureObservationState()
        return output
    }

    func cancelRecording() async {
        paused = false
        resetCaptureFailureObservationState()
    }

    func pauseRecording() async {
        paused = true
    }

    func resumeRecording() async {
        paused = false
    }

    func setMicrophoneMuted(_ muted: Bool) async -> MeetingMicrophoneMuteState {
        MeetingMicrophoneMuteState(isMuted: muted, canMute: true)
    }

    func updateNotes(_ notes: String) async {}

    var isRecording: Bool { true }

    var isPaused: Bool { paused }

    var micLevel: Float { 0 }

    var systemLevel: Float { 0 }

    var elapsedSeconds: Int { 0 }

    var captureMode: CaptureMode { paused ? .paused : .full }

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

    func captureFailureSignalForCurrentSession() async -> AsyncStream<MeetingCaptureFailureSignal> {
        var continuation: AsyncStream<MeetingCaptureFailureSignal>.Continuation?
        let stream = AsyncStream<MeetingCaptureFailureSignal>(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        guard let continuation else { return stream }

        if captureFailureSignaled {
            continuation.yield(MeetingCaptureFailureSignal(sessionID: captureFailureSessionID))
            continuation.finish()
            return stream
        }

        let continuationID = UUID()
        captureFailureContinuations[continuationID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeCaptureFailureContinuation(id: continuationID)
            }
        }
        return stream
    }

    func emitCaptureFailure() {
        guard !captureFailureSignaled else { return }
        captureFailureSignaled = true
        let continuations = captureFailureContinuations
        captureFailureContinuations.removeAll()
        let signal = MeetingCaptureFailureSignal(sessionID: captureFailureSessionID)
        for continuation in continuations.values {
            continuation.yield(signal)
            continuation.finish()
        }
    }

    private func finishCaptureFailureContinuations() {
        let continuations = captureFailureContinuations
        captureFailureContinuations.removeAll()
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    private func resetCaptureFailureObservationState() {
        finishCaptureFailureContinuations()
        captureFailureSessionID = UUID()
        captureFailureSignaled = false
    }

    private func removeCaptureFailureContinuation(id: UUID) {
        captureFailureContinuations[id] = nil
    }

    func snapshot() -> (
        startCallCount: Int,
        startCalls: [StartCall],
        stopCallCount: Int,
        startTitles: [String?],
        calendarEventSnapshots: [MeetingCalendarSnapshot?]
    ) {
        (
            startCallCount: startCallCount,
            startCalls: startCalls,
            stopCallCount: stopCallCount,
            startTitles: startTitles,
            calendarEventSnapshots: calendarEventSnapshots
        )
    }
}

private final class ProbableCalendarSnapshotHolder: @unchecked Sendable {
    var snapshot: MeetingCalendarSnapshot?
}

private final class FlowRecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var deletes: [URL] = []

    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {}

    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { nil }

    func delete(folderURL: URL) throws {
        lock.withLock {
            deletes.append(folderURL)
        }
    }

    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] { [] }
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
        guard
            case .meetingOperation(
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
            ) = self
        else {
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
