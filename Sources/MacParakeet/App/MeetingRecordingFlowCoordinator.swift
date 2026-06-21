import AppKit
import MacParakeetCore
import MacParakeetViewModels
import OSLog

enum MeetingRecordingQuitState {
    case starting
    case recording
    case finishing
}

@MainActor
final class MeetingRecordingFlowCoordinator {
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingRecordingFlow")

    var isMeetingRecordingActive: Bool {
        switch stateMachine.state {
        case .idle, .finishing:
            return false
        case .checkingPermissions, .starting, .recording, .stopping:
            return true
        }
    }

    var isCapturingMeetingAudioForAutoStop: Bool {
        stateMachine.state == .recording
    }

    var quitState: MeetingRecordingQuitState? {
        switch stateMachine.state {
        case .idle, .finishing:
            return nil
        case .checkingPermissions, .starting:
            return .starting
        case .recording:
            return .recording
        case .stopping:
            return .finishing
        }
    }

    private let meetingRecordingService: MeetingRecordingServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let conversationRepo: ChatConversationRepositoryProtocol
    private let quickPromptRepo: QuickPromptRepositoryProtocol
    private let configStore: LLMConfigStoreProtocol
    private let cliConfigStore: LocalCLIConfigStore
    private let sttManager: (any STTRuntimeManaging)?
    private let meetingAudioSourceModeProvider: @MainActor @Sendable () -> MeetingAudioSourceMode
    private var llmService: LLMServiceProtocol?
    private let onMenuBarIconUpdate: (BreathWaveIcon.MenuBarState) -> Void
    private let onTranscriptionReady: (Transcription) -> Void
    private let onQueuedTranscriptionReady: (Transcription, Bool) -> Void
    private let onRecordingBegan: () -> Void
    private let onRecordingStopping: () -> Void
    private let onFlowReturnedToIdle: () -> Void
    private let meetingTranscriptionQueue: MeetingTranscriptionQueue

    private var stateMachine = MeetingRecordingFlowStateMachine()
    private var pillController: MeetingRecordingPillController?
    /// Long-lived view model shared with the Transcribe-tab tile so the tile
    /// can render live recording state. Owned by `AppEnvironmentConfigurer`,
    /// passed in via init. Reset to `.idle` (not nilled) on flow teardown.
    private let pillViewModel: MeetingRecordingPillViewModel
    private var panelController: MeetingRecordingPanelController?
    private var panelViewModel: MeetingRecordingPanelViewModel?
    private var actionTask: Task<Void, Never>?
    private var pauseToggleTask: Task<Void, Never>?
    private var microphoneMuteToggleTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var pillPollingTask: Task<Void, Never>?
    private var pillGlowPollingTask: Task<Void, Never>?
    private var transcriptObservationTask: Task<Void, Never>?
    private var speechWarmUpObservationTask: Task<Void, Never>?
    // Saved-completion celebration (Metatron bloom → checkmark). The flow returns
    // to `.idle` the instant the recording is queued (back-to-back stays instant);
    // these drive the pill's self-contained, interruptible visual epilogue.
    private var metatronMinDurationTask: Task<Void, Never>?
    private var savedCompletionDismissTask: Task<Void, Never>?
    private var meetingDurablySaved = false
    private var metatronBloomSettled = false
    /// Minimum on-screen time for the Metatron "saving" bloom before it may
    /// resolve to the checkmark, so the flourish always reads even when the
    /// background queueing finishes instantly (pairs with the ~1 s collapse for
    /// a ~3 s post-collapse celebration).
    private let metatronMinimumDisplay: Duration = .milliseconds(1500)
    /// How long the "saved" checkmark holds before the pill self-dismisses.
    private let savedCheckmarkHold: Duration = .milliseconds(1700)
    private var activeFlowSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentMeetingOperationContext: ObservabilityOperationContext?
    private var currentMeetingTrigger: TelemetryMeetingOperationTrigger?
    private var pendingAudioSourceMode: MeetingAudioSourceMode?

    init(
        meetingRecordingService: MeetingRecordingServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        permissionService: PermissionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        conversationRepo: ChatConversationRepositoryProtocol,
        quickPromptRepo: QuickPromptRepositoryProtocol,
        configStore: LLMConfigStoreProtocol,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore(),
        sttManager: (any STTRuntimeManaging)? = nil,
        meetingAudioSourceModeProvider: @escaping @MainActor @Sendable () -> MeetingAudioSourceMode = {
            .microphoneAndSystem
        },
        llmService: LLMServiceProtocol?,
        pillViewModel: MeetingRecordingPillViewModel,
        meetingTranscriptionQueue: MeetingTranscriptionQueue? = nil,
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onTranscriptionReady: @escaping (Transcription) -> Void,
        onQueuedTranscriptionReady: ((Transcription, Bool) -> Void)? = nil,
        onRecordingBegan: @escaping () -> Void = {},
        onRecordingStopping: @escaping () -> Void = {},
        onFlowReturnedToIdle: @escaping () -> Void = {}
    ) {
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionService = transcriptionService
        self.permissionService = permissionService
        self.transcriptionRepo = transcriptionRepo
        self.conversationRepo = conversationRepo
        self.quickPromptRepo = quickPromptRepo
        self.configStore = configStore
        self.cliConfigStore = cliConfigStore
        self.sttManager = sttManager
        self.meetingAudioSourceModeProvider = meetingAudioSourceModeProvider
        self.llmService = llmService
        self.pillViewModel = pillViewModel
        self.meetingTranscriptionQueue =
            meetingTranscriptionQueue
            ?? MeetingTranscriptionQueue(
                transcriptionService: transcriptionService,
                meetingRecordingService: meetingRecordingService
            )
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onTranscriptionReady = onTranscriptionReady
        self.onQueuedTranscriptionReady =
            onQueuedTranscriptionReady ?? { transcription, _ in
                onTranscriptionReady(transcription)
            }
        self.onRecordingBegan = onRecordingBegan
        self.onRecordingStopping = onRecordingStopping
        self.onFlowReturnedToIdle = onFlowReturnedToIdle
        self.meetingTranscriptionQueue.onStateChanged = { [weak self] snapshot in
            self?.pillViewModel.backgroundTranscriptionCount = snapshot.totalCount
        }
        self.meetingTranscriptionQueue.onCompletion = { [weak self] completion in
            self?.handleQueuedMeetingTranscriptionCompletion(completion)
        }
    }

    /// Updates the LLM service when the user changes providers. Mirrors what
    /// AppEnvironmentConfigurer.refreshLLMAvailability does for the singleton chat VM.
    func updateLLMService(_ service: LLMServiceProtocol?) {
        self.llmService = service
        panelViewModel?.chatViewModel.updateLLMService(service)
    }

    /// Trigger source for the *next* `.startRequested` event. Reset to nil
    /// after the start telemetry fires so subsequent toggles don't carry a
    /// stale trigger. Calendar-driven starts call `startFromCalendar`,
    /// which sets this and re-enters `toggleRecording`.
    private var pendingTrigger: TelemetryMeetingRecordingTrigger?

    /// Pre-set title for the *next* `.startRecording` effect. Paired with
    /// `pendingTrigger`: `startFromCalendar(title:)` sets both, the
    /// `.startRecording` handler snapshots and clears both before the async
    /// hop. Manual / hotkey starts set only the trigger, so the service falls
    /// back to its date-based default title.
    private var pendingTitle: String?

    /// Pause / resume the in-flight recording. The state flip happens AFTER
    /// the service confirms — an optimistic flip before the await would race
    /// with the 150ms polling reconciler (which reads `captureMode` from the
    /// actor and could see `.full` while the spawned pause Task is still
    /// queued, then flip the pill back to `.recording`).
    ///
    /// Stale toggles are cancelled so a rapid pause/resume/pause sequence
    /// settles in the latest user intent rather than the order Tasks happen
    /// to be scheduled.
    func togglePause() {
        guard pillViewModel.canTogglePause else { return }
        let wantPause = !pillViewModel.isPaused
        pauseToggleTask?.cancel()
        pauseToggleTask = Task { @MainActor [meetingRecordingService, weak self] in
            if wantPause {
                await meetingRecordingService.pauseRecording()
            } else {
                await meetingRecordingService.resumeRecording()
            }
            guard !Task.isCancelled, let self else { return }
            // Only flip if the pill is still in a togglable state. A stop or
            // capture-failure that landed during the await may have moved
            // the pill to `.transcribing` / `.error`; we must not stomp it.
            guard self.pillViewModel.canTogglePause else { return }
            self.pillViewModel.state = wantPause ? .paused : .recording
            self.pillController?.refreshState()
            self.panelViewModel?.isPaused = wantPause
        }
    }

    func toggleMicrophoneMute() {
        guard panelViewModel?.canToggleMicrophoneMute == true else { return }
        let wantMuted = !(panelViewModel?.isMicrophoneMuted ?? false)
        microphoneMuteToggleTask?.cancel()
        microphoneMuteToggleTask = Task { @MainActor [meetingRecordingService, weak self] in
            let microphoneMuteState = await meetingRecordingService.setMicrophoneMuted(wantMuted)
            guard !Task.isCancelled, let self else { return }
            self.panelViewModel?.isMicrophoneMuted = microphoneMuteState.isMuted
            self.panelViewModel?.canToggleMicrophoneMute = microphoneMuteState.canMute
        }
    }

    @discardableResult
    func startRecording(
        title: String? = nil,
        trigger: TelemetryMeetingRecordingTrigger = .manual
    ) -> Int? {
        guard stateMachine.state == .idle else { return nil }
        pendingTrigger = pendingTrigger ?? trigger
        pendingTitle = title
        currentMeetingOperationContext = ObservabilityOperationContext()
        sendEvent(.startRequested)
        return stateMachine.generation
    }

    func toggleRecording(trigger: TelemetryMeetingRecordingTrigger = .manual) {
        switch stateMachine.state {
        case .idle:
            startRecording(trigger: trigger)
        case .recording, .starting, .stopping:
            stopRecording(trigger: trigger)
        case .checkingPermissions, .finishing:
            break
        }
    }

    @discardableResult
    func stopRecording(trigger: TelemetryMeetingRecordingTrigger = .manual) -> Bool {
        stopRecording(operationTrigger: TelemetryMeetingOperationTrigger(trigger))
    }

    @discardableResult
    func stopRecording(operationTrigger trigger: TelemetryMeetingOperationTrigger) -> Bool {
        switch stateMachine.state {
        case .recording, .starting:
            currentMeetingTrigger = trigger
            sendEvent(.stopRequested)
            return true
        case .idle, .checkingPermissions, .stopping, .finishing:
            return false
        }
    }

    func stopRecordingAndWaitForCompletion() async {
        switch stateMachine.state {
        case .checkingPermissions, .starting:
            sendEvent(.cancelRequested)
        default:
            _ = stopRecording(trigger: .manual)
        }
        await waitForActiveFlowToSettle()
        if let actionTask {
            await actionTask.value
        }
    }

    func discardRecordingAndWaitForCompletion() async {
        sendEvent(.cancelRequested)
        await waitForActiveFlowToSettle()
        if let actionTask {
            await actionTask.value
        }
    }

    /// Detach the floating recording pill's window without disturbing the
    /// recording/transcription flow. Called when the app begins a quit
    /// decision or is terminating: the pill is a `.canJoinAllSpaces`,
    /// background-draggable `NSPanel`, so while the app's main loop is busy
    /// with the active-meeting quit alert or the final-transcription wait it
    /// would otherwise linger on every Space as a window you can drag but
    /// whose click/right-click handlers no longer respond — a "frozen ghost
    /// pill." The recording itself keeps running; restore the pill with
    /// `restoreFloatingPillIfRecording()` if the user cancels the quit. Safe
    /// (no-op) when no pill is showing.
    func dismissFloatingPillForQuit() {
        pillController?.hide(preserveFrameForNextShow: true)
    }

    /// Re-show the floating pill after a quit was cancelled, but only while a
    /// recording is still active — otherwise there is nothing to show and the
    /// normal `.hidePill` teardown owns the lifecycle. The long-lived pill
    /// view model still holds live state, so the rebuilt window renders the
    /// current recording face immediately.
    func restoreFloatingPillIfRecording() {
        guard isMeetingRecordingActive else { return }
        pillController?.show()
        pillController?.refreshState()
    }

    /// Calendar-driven entry point. Marks the next start as auto-start so
    /// telemetry distinguishes it and pre-names the recording with the
    /// event title, then enters the normal start flow. No-op if a recording
    /// is already in progress (manual recording wins by arriving first —
    /// see ADR-017 §10), in which case it emits
    /// `calendar_auto_start_failed{reason=state_busy}` so we can see how
    /// often back-to-back meetings actually collide in the wild. Returns the
    /// recording generation on success (or `nil` when the state was busy).
    @discardableResult
    func startFromCalendar(title: String? = nil) -> Int? {
        guard stateMachine.state == .idle else {
            Telemetry.send(.calendarAutoStartFailed(reason: "state_busy"))
            return nil
        }
        pendingTrigger = .calendarAutoStart
        pendingTitle = title
        currentMeetingOperationContext = ObservabilityOperationContext()
        sendEvent(.startRequested)
        return stateMachine.generation
    }

    /// Discard the pending start context (trigger + title) when the start
    /// sequence exits without ever reaching the `.startRecording` effect —
    /// today, only the permissions-denied path. The `.startRecording`
    /// effect handler clears these inline because it needs to snapshot
    /// them first to fire telemetry; this helper is for the paths that
    /// bail out earlier. If the bailing-out start was calendar-driven,
    /// emits `calendar_auto_start_failed{reason}` for observability.
    private func clearPendingStartContext(failureReason: String) {
        let wasCalendarTriggered = pendingTrigger == .calendarAutoStart
        sendMeetingOperation(
            outcome: .unavailable,
            trigger: pendingTrigger.map(TelemetryMeetingOperationTrigger.init),
            stage: .permissions,
            errorType: failureReason
        )
        pendingTrigger = nil
        pendingTitle = nil
        pendingAudioSourceMode = nil
        currentMeetingOperationContext = nil
        currentMeetingTrigger = nil
        if wasCalendarTriggered {
            Telemetry.send(.calendarAutoStartFailed(reason: failureReason))
        }
    }

    private func waitForActiveFlowToSettle() async {
        while isMeetingRecordingActive {
            await withCheckedContinuation { continuation in
                activeFlowSettlementWaiters.append(continuation)
            }
        }
    }

    private func sendEvent(_ event: MeetingRecordingFlowEvent) {
        let effects = stateMachine.handle(event)
        executeEffects(effects)
        resumeActiveFlowSettlementWaitersIfNeeded()
    }

    private func resumeActiveFlowSettlementWaitersIfNeeded() {
        guard !isMeetingRecordingActive, !activeFlowSettlementWaiters.isEmpty else { return }
        let waiters = activeFlowSettlementWaiters
        activeFlowSettlementWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func executeEffects(_ effects: [MeetingRecordingFlowEffect]) {
        for effect in effects {
            executeEffect(effect)
        }
    }

    private func executeEffect(_ effect: MeetingRecordingFlowEffect) {
        switch effect {
        case .checkPermissions:
            let gen = stateMachine.generation
            actionTask = Task { @MainActor in
                let sourceMode = meetingAudioSourceModeProvider()
                self.pendingAudioSourceMode = sourceMode
                let microphoneGranted: Bool
                let microphonePrompted: Bool
                if sourceMode.capturesMicrophone {
                    let microphoneStatus = await permissionService.checkMicrophonePermission()
                    switch microphoneStatus {
                    case .granted:
                        microphoneGranted = true
                        microphonePrompted = false
                    case .denied:
                        microphoneGranted = false
                        microphonePrompted = false
                    case .notDetermined:
                        Telemetry.send(.permissionPrompted(permission: .microphone))
                        microphonePrompted = true
                        microphoneGranted = await permissionService.requestMicrophonePermission()
                    }
                } else {
                    microphoneGranted = true
                    microphonePrompted = false
                }

                if !microphoneGranted {
                    if microphonePrompted {
                        Telemetry.send(.permissionDenied(permission: .microphone))
                    }
                    self.clearPendingStartContext(failureReason: "permission_denied")
                    self.sendEvent(.permissionsDenied(generation: gen, reason: .microphone))
                    return
                }
                if microphonePrompted {
                    Telemetry.send(.permissionGranted(permission: .microphone))
                }

                if sourceMode.capturesSystemAudio {
                    let existingScreenGrant = permissionService.checkScreenRecordingPermission()
                    if !existingScreenGrant {
                        Telemetry.send(.permissionPrompted(permission: .screenRecording))
                    }
                    let screenGranted = existingScreenGrant || permissionService.requestScreenRecordingPermission()
                    if !screenGranted {
                        Telemetry.send(.permissionDenied(permission: .screenRecording))
                        self.clearPendingStartContext(failureReason: "permission_denied")
                        self.sendEvent(.permissionsDenied(generation: gen, reason: .screenRecording))
                        return
                    }
                    if !existingScreenGrant {
                        Telemetry.send(.permissionGranted(permission: .screenRecording))
                    }
                }
                self.sendEvent(.permissionsGranted(generation: gen))
            }

        case .showRecordingPill:
            // A new recording supersedes any in-flight saved-completion
            // celebration from the previous meeting (back-to-back): cancel its
            // dismiss/min-display tasks so they can't tear down this fresh pill.
            cancelSavedCompletion()
            let vm = pillViewModel
            vm.onStop = { [weak self] in self?.toggleRecording() }
            vm.onPauseToggle = { [weak self] in self?.togglePause() }
            vm.elapsedSeconds = 0
            vm.micLevel = 0
            vm.systemLevel = 0
            vm.state = .recording
            let panelVM = panelViewModel ?? MeetingRecordingPanelViewModel()
            panelVM.state = .recording
            panelVM.elapsedSeconds = 0
            panelVM.micLevel = 0
            panelVM.systemLevel = 0
            panelVM.isPaused = false
            panelVM.isMicrophoneMuted = false
            panelVM.canToggleMicrophoneMute =
                (pendingAudioSourceMode ?? meetingAudioSourceModeProvider()).capturesMicrophone
            panelVM.updateLiveTranscriptStatus(.startingAudio)
            panelVM.updatePreviewLines([], isTranscriptionLagging: false)
            panelVM.onStop = { [weak self] in self?.toggleRecording() }
            panelVM.onPauseToggle = { [weak self] in self?.togglePause() }
            panelVM.onMicrophoneMuteToggle = { [weak self] in self?.toggleMicrophoneMute() }
            panelVM.onClose = { [weak self] in self?.hideMeetingPanel() }
            // Configure live Ask: in-memory mode (no transcriptionId/conversationRepo).
            // Promotion to a persisted ChatConversation happens after stop-time
            // stub creation, before the panel is torn down for queued finalize.
            panelVM.chatViewModel.configure(
                llmService: llmService,
                transcriptText: panelVM.chatTranscript,
                configStore: configStore,
                cliConfigStore: cliConfigStore
            )
            panelVM.quickPromptsViewModel.configure(repo: quickPromptRepo)
            // Wire the notepad's debounced persistence target through the
            // recording service. The service serializes lock-file writes and
            // carries the latest notes into MeetingRecordingOutput.userNotes,
            // where TranscriptionService persists them onto the Transcription
            // (ADR-020 §8, §10). The "Memo-Steered Notes" built-in prompt that
            // originally consumed these notes was reverted on 2026-05-02; the
            // notes themselves and the {{userNotes}} template variable remain
            // available for custom prompts.
            panelVM.notesViewModel.bindPersist { [weak self] notes in
                await self?.meetingRecordingService.updateNotes(notes)
            }
            panelViewModel = panelVM

            if pillController == nil {
                pillController = MeetingRecordingPillController(viewModel: vm)
            }
            pillController?.onClick = { [weak self] in
                self?.showMeetingPanel()
            }
            pillController?.onStopRecording = { [weak self] in
                self?.stopRecording(trigger: .manual)
            }
            pillController?.onOpenApp = { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showMeetingPanel()
            }
            pillController?.onCancelRecording = { [weak self] in
                self?.confirmAndCancelRecording()
            }
            pillController?.onPauseToggle = { [weak self] in
                self?.togglePause()
            }
            if panelController == nil {
                let controller = MeetingRecordingPanelController(viewModel: panelVM)
                controller.onCloseRequested = { [weak self] in
                    self?.hideMeetingPanel()
                }
                panelController = controller
            }
            pillController?.show()
            startSpeechWarmUpObservation()
            startPillPolling()
            startPillGlowPolling()
            startTranscriptObservation()

        case .startRecording:
            let gen = stateMachine.generation
            // Snapshot + clear before the async hop so a subsequent toggle
            // can't smuggle a stale trigger / title into this start.
            let trigger = pendingTrigger
            let title = pendingTitle
            let sourceMode = pendingAudioSourceMode ?? meetingAudioSourceModeProvider()
            pendingTrigger = nil
            pendingTitle = nil
            pendingAudioSourceMode = nil
            let operationContext = currentMeetingOperationContext ?? ObservabilityOperationContext()
            currentMeetingOperationContext = operationContext
            currentMeetingTrigger = trigger.map(TelemetryMeetingOperationTrigger.init)
            actionTask = Task { @MainActor in
                do {
                    try await meetingRecordingService.startRecording(title: title, sourceMode: sourceMode)
                    let isSpeechModelReady = await self.sttManager?.isReady() ?? true
                    switch self.panelViewModel?.liveTranscriptStatus {
                    case .some(.startingAudio) where isSpeechModelReady:
                        self.panelViewModel?.updateLiveTranscriptStatus(.listening)
                    case .some(.startingAudio):
                        self.panelViewModel?.updateLiveTranscriptStatus(.preparingSpeechModel(message: nil))
                    case .some(.preparingSpeechModel) where isSpeechModelReady:
                        self.panelViewModel?.updateLiveTranscriptStatus(.listening)
                    case .some(.listening), .some(.live), .some(.previewUnavailable), .none:
                        break
                    case .some(.preparingSpeechModel):
                        break
                    }
                    self.sendEvent(.recordingStarted(generation: gen))
                    Telemetry.send(.meetingRecordingStarted(trigger: trigger))
                    self.onRecordingBegan()
                } catch {
                    Telemetry.send(
                        .meetingRecordingFailed(
                            errorType: TelemetryErrorClassifier.classify(error),
                            errorDetail: TelemetryErrorClassifier.errorDetail(error)
                        ))
                    // If this start was driven by calendar auto-start, emit
                    // the dedicated failure event so analysts can see *why*
                    // (vs just inferring "silent failure" by subtraction
                    // from `.calendarAutoStartTriggered`).
                    if trigger == .calendarAutoStart {
                        Telemetry.send(.calendarAutoStartFailed(reason: "service_threw"))
                    }
                    self.sendMeetingOperation(
                        outcome: .failure,
                        trigger: trigger.map(TelemetryMeetingOperationTrigger.init),
                        stage: .startRecording,
                        errorType: TelemetryErrorClassifier.classify(error)
                    )
                    self.currentMeetingOperationContext = nil
                    self.currentMeetingTrigger = nil
                    self.sendEvent(.startFailed(generation: gen, message: error.localizedDescription))
                }
            }

        case .showTranscribingState:
            onRecordingStopping()
            stopPillPolling()
            stopTranscriptObservation()
            stopSpeechWarmUpObservation()
            // Begin a fresh saved-completion celebration.
            cancelSavedCompletion()
            pillViewModel.micLevel = 0
            pillViewModel.systemLevel = 0
            pillViewModel.state = .completing
            pillController?.refreshState()
            pillViewModel.onCompletionAnimationFinished = { [weak self] in
                guard let self, self.pillViewModel.state == .completing else { return }
                // Flower collapsed → the Metatron "saving" bloom takes over and
                // holds until the recording is durably queued (`.showSavedCompletion`).
                self.pillViewModel.state = .transcribing
                self.pillController?.refreshState()
                self.startMetatronMinimumDisplay()
            }
            panelViewModel?.state = .transcribing
            panelViewModel?.micLevel = 0
            panelViewModel?.systemLevel = 0
            hideMeetingPanel()

        case .stopRecordingAndTranscribe:
            let gen = stateMachine.generation
            let liveWordCount = panelViewModel?.wordCount ?? 0
            let liveTranscriptLagged = panelViewModel?.isTranscriptionLagging ?? false
            let notesVM = panelViewModel?.notesViewModel
            let operationContext = currentMeetingOperationContext ?? ObservabilityOperationContext()
            let operationTrigger = currentMeetingTrigger
            currentMeetingOperationContext = operationContext
            actionTask = Task { @MainActor in
                var stoppedOutput: MeetingRecordingOutput?
                do {
                    let prepared = try await Observability.withOperationContext(operationContext) {
                        // Flush any keystrokes typed in the last < 250 ms so
                        // they make it onto the lock file and into the saved
                        // Transcription.userNotes (ADR-020 §8).
                        await notesVM?.commit()
                        let output = try await meetingRecordingService.stopRecording()
                        stoppedOutput = output
                        Telemetry.send(
                            .meetingRecordingCompleted(
                                durationSeconds: output.durationSeconds,
                                liveWordCount: liveWordCount,
                                liveTranscriptLagged: liveTranscriptLagged
                            ))
                        let prepared = try await transcriptionService.prepareMeetingTranscription(recording: output)
                        self.persistLiveAskConversationIfNeeded(transcriptionID: prepared.id)
                        meetingTranscriptionQueue.enqueue(
                            MeetingTranscriptionQueue.Item(
                                recording: output,
                                transcriptionID: prepared.id,
                                operationContext: operationContext,
                                trigger: operationTrigger,
                                liveWordCount: liveWordCount,
                                liveTranscriptLagged: liveTranscriptLagged
                            ))
                        return prepared
                    }
                    self.currentMeetingOperationContext = nil
                    self.currentMeetingTrigger = nil
                    self.sendEvent(.recordingQueued(generation: gen, transcriptionID: prepared.id))
                } catch {
                    if let stoppedOutput {
                        await meetingRecordingService.finishTranscriptionAttempt(for: stoppedOutput)
                    }
                    if error is CancellationError {
                        self.sendMeetingOperation(
                            outcome: .cancelled,
                            output: stoppedOutput,
                            stage: stoppedOutput == nil ? .stopRecording : .completeTranscription,
                            liveWordCount: liveWordCount,
                            liveTranscriptLagged: liveTranscriptLagged
                        )
                        self.currentMeetingOperationContext = nil
                        self.currentMeetingTrigger = nil
                    } else {
                        Telemetry.send(
                            .meetingRecordingFailed(
                                errorType: TelemetryErrorClassifier.classify(error),
                                errorDetail: TelemetryErrorClassifier.errorDetail(error)
                            ))
                        self.sendMeetingOperation(
                            outcome: .failure,
                            output: stoppedOutput,
                            stage: stoppedOutput == nil ? .stopRecording : .completeTranscription,
                            liveWordCount: liveWordCount,
                            liveTranscriptLagged: liveTranscriptLagged,
                            errorType: TelemetryErrorClassifier.classify(error)
                        )
                        self.currentMeetingOperationContext = nil
                        self.currentMeetingTrigger = nil
                        self.sendEvent(.transcriptionFailed(generation: gen, message: error.localizedDescription))
                    }
                }
            }

        case .cancelRecording:
            let durationSeconds = Double(panelViewModel?.elapsedSeconds ?? 0)
            let notesVM = panelViewModel?.notesViewModel
            let cancelledTrigger = currentMeetingTrigger ?? pendingTrigger.map(TelemetryMeetingOperationTrigger.init)
            pendingTrigger = nil
            pendingTitle = nil
            pendingAudioSourceMode = nil
            actionTask?.cancel()
            actionTask = Task { @MainActor in
                // Stop the in-flight debounce so it can't fire against a
                // session folder that cancelRecording is about to delete.
                // The notes themselves are intentionally discarded with
                // the rest of the cancelled recording — symmetric with
                // .stopRecordingAndTranscribe's commit() call.
                await notesVM?.commit()
                await meetingRecordingService.cancelRecording()
                Telemetry.send(.meetingRecordingCancelled(durationSeconds: durationSeconds))
                self.sendMeetingOperation(
                    outcome: .cancelled,
                    trigger: cancelledTrigger,
                    stage: .cancel,
                    durationSeconds: durationSeconds
                )
                self.currentMeetingOperationContext = nil
                self.currentMeetingTrigger = nil
            }

        case .showError(let message):
            cancelSavedCompletion()
            stopPillPolling()
            stopTranscriptObservation()
            stopSpeechWarmUpObservation()
            panelViewModel?.state = .error(message)
            pillViewModel.state = .error(
                panelViewModel?.compactErrorRecoveryMessage
                    ?? "Meeting interrupted. Open Library to retry transcription or export captured audio."
            )
            pillController?.refreshState()
            hideMeetingPanel()

        case .showSavedCompletion:
            // Durably saved + queued. The expanded panel is already hidden and
            // its live-Ask chat persisted (in .stopRecordingAndTranscribe), so
            // tear it down now; the floating pill alone carries the celebration.
            meetingDurablySaved = true
            teardownMeetingPanel()
            // The Metatron resolves to the checkmark once its minimum bloom has
            // also elapsed, then the pill self-dismisses. Interruptible: a
            // back-to-back start cancels it.
            advanceToSavedCheckmarkIfReady()

        case .hidePill:
            cancelSavedCompletion()
            teardownPillFlow()

        case .updateMenuBar(let state):
            let iconState: BreathWaveIcon.MenuBarState =
                switch state {
                case .idle: .idle
                case .recording: .recording
                case .processing: .processing
                }
            onMenuBarIconUpdate(iconState)

        case .presentPermissionAlert(let reason):
            onFlowReturnedToIdle()
            presentPermissionAlert(for: reason)

        case .startAutoDismissTimer(let seconds):
            // Only emitted on the error paths now (start/stop failure), where
            // `.showError` has already put the pill in `.error` immediately
            // before this effect, so the dismiss timer always uses `seconds`.
            autoDismissTask?.cancel()
            let gen = stateMachine.generation
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self.sendEvent(.autoDismissExpired(generation: gen))
            }

        case .cancelAutoDismissTimer:
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    // MARK: - Saved-completion celebration

    /// Hold the Metatron bloom for a minimum on-screen time before it may resolve
    /// to the checkmark, so the celebration reads even when queueing is instant.
    private func startMetatronMinimumDisplay() {
        metatronBloomSettled = false
        metatronMinDurationTask?.cancel()
        let duration = metatronMinimumDisplay
        metatronMinDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.metatronBloomSettled = true
            self.advanceToSavedCheckmarkIfReady()
        }
    }

    /// Resolve the bloom into the "saved" checkmark once the recording is durably
    /// queued AND the bloom has shown for its minimum time, then self-dismiss the
    /// pill. No-op unless the pill is still showing the bloom (a new recording or
    /// an error may have taken over in the meantime).
    private func advanceToSavedCheckmarkIfReady() {
        guard pillViewModel.state == .transcribing,
            meetingDurablySaved,
            metatronBloomSettled
        else { return }
        pillViewModel.state = .completed
        pillController?.refreshState()
        scheduleSavedDismiss()
    }

    private func scheduleSavedDismiss() {
        savedCompletionDismissTask?.cancel()
        let duration = savedCheckmarkHold
        savedCompletionDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            // Only tear down if nothing new took over the pill in the meantime.
            guard self.stateMachine.state == .idle, self.pillViewModel.state == .completed else { return }
            self.teardownPillFlow()
        }
    }

    private func cancelSavedCompletion() {
        metatronMinDurationTask?.cancel()
        metatronMinDurationTask = nil
        savedCompletionDismissTask?.cancel()
        savedCompletionDismissTask = nil
        meetingDurablySaved = false
        metatronBloomSettled = false
    }

    /// Tear down the floating pill + panel and return the pill view model to
    /// `.idle`. Shared by the immediate `.hidePill` (cancel/error) and the
    /// deferred saved-completion dismiss. The pill view model is long-lived (it
    /// also drives the Transcribe-tab tile), so it is reset rather than nilled;
    /// its callbacks are re-bound on the next `.showRecordingPill`.
    private func teardownPillFlow() {
        stopPillPolling()
        stopTranscriptObservation()
        stopSpeechWarmUpObservation()
        pauseToggleTask?.cancel()
        pauseToggleTask = nil
        microphoneMuteToggleTask?.cancel()
        microphoneMuteToggleTask = nil
        pillController?.hide()
        pillController = nil
        pillViewModel.onStop = nil
        pillViewModel.onPauseToggle = nil
        pillViewModel.onCompletionAnimationFinished = nil
        pillViewModel.elapsedSeconds = 0
        pillViewModel.micLevel = 0
        pillViewModel.systemLevel = 0
        pillViewModel.state = .idle
        teardownMeetingPanel()
        onFlowReturnedToIdle()
    }

    /// Close the expanded meeting panel and release its view model. Safe to call
    /// repeatedly (the saved-completion path tears the panel down before the pill,
    /// then the pill teardown calls this again as a no-op).
    private func teardownMeetingPanel() {
        panelController?.close()
        panelController = nil
        panelViewModel = nil
    }

    private func confirmAndCancelRecording() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard Recording?"
        alert.informativeText =
            "This will stop the meeting recording and delete all captured audio. This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            sendEvent(.cancelRequested)
        }
    }

    private func presentPermissionAlert(for reason: MeetingRecordingPermissionFailure) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case .microphone:
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "Meeting recording needs microphone access to capture your voice."
        case .screenRecording:
            alert.messageText = "Screen Recording Access Required"
            alert.informativeText =
                "Meeting recording needs Screen & System Audio Recording access to capture system audio."
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings(for: reason)
        }
    }

    private func startPillPolling() {
        pillPollingTask?.cancel()
        pillPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let micLevel = Self.displayLevel(await meetingRecordingService.micLevel)
                let systemLevel = Self.displayLevel(await meetingRecordingService.systemLevel)
                let elapsedSeconds = await meetingRecordingService.elapsedSeconds
                let captureMode = await meetingRecordingService.captureMode
                let microphoneMuteState = await meetingRecordingService.microphoneMuteState

                guard !Task.isCancelled else { break }
                if pillViewModel.micLevel != micLevel {
                    pillViewModel.micLevel = micLevel
                }
                if pillViewModel.systemLevel != systemLevel {
                    pillViewModel.systemLevel = systemLevel
                }
                if pillViewModel.elapsedSeconds != elapsedSeconds {
                    pillViewModel.elapsedSeconds = elapsedSeconds
                }
                if let panelViewModel {
                    if panelViewModel.elapsedSeconds != elapsedSeconds {
                        panelViewModel.elapsedSeconds = elapsedSeconds
                    }
                    // While actively recording the panel orbs are driven by the
                    // fast (~30 fps) glow loop; this 1 s loop only settles them
                    // (→ 0) when paused/stopped so they don't freeze on the last
                    // live frame. Writing levels here every second while recording
                    // would also visibly fight the fast loop's smoother updates.
                    if captureMode != .full {
                        if panelViewModel.micLevel != micLevel {
                            panelViewModel.micLevel = micLevel
                        }
                        if panelViewModel.systemLevel != systemLevel {
                            panelViewModel.systemLevel = systemLevel
                        }
                    }
                    if panelViewModel.isMicrophoneMuted != microphoneMuteState.isMuted {
                        panelViewModel.isMicrophoneMuted = microphoneMuteState.isMuted
                    }
                    if panelViewModel.canToggleMicrophoneMute != microphoneMuteState.canMute {
                        panelViewModel.canToggleMicrophoneMute = microphoneMuteState.canMute
                    }
                }
                // Pause/resume reconciliation (issue #235). The user-facing
                // toggle does an optimistic flip; this poll is the
                // authoritative source if the optimistic flip diverged from
                // the service (e.g., capture failed before the service saw
                // the pause call). Only flip pillViewModel.state between
                // .recording and .paused — never override .completing /
                // .transcribing / .completed / .error from here.
                let serviceIsPaused = (captureMode == .paused)
                if pillViewModel.state == .recording, serviceIsPaused {
                    pillViewModel.state = .paused
                } else if pillViewModel.state == .paused, !serviceIsPaused, captureMode == .full {
                    pillViewModel.state = .recording
                }
                panelViewModel?.isPaused = serviceIsPaused
                if captureMode == .stopped,
                    stateMachine.state == .recording,
                    pillViewModel.state == .recording || pillViewModel.state == .paused
                {
                    // Audio capture stopped while the state machine still
                    // expects a live recording — typically because
                    // `MeetingRecordingService.failCapture` ran (mic unplug,
                    // writer error, OS audio routing change). Could also
                    // fire while paused if a USB mic is unplugged mid-pause.
                    // Without this signal the pill keeps showing the paused
                    // glyph or "recording" with a ticking timer while no
                    // audio is actually being captured. Surface it through
                    // the state machine so the existing stop+transcribe
                    // path saves whatever made it to disk.
                    pillViewModel.micLevel = 0
                    pillViewModel.systemLevel = 0
                    panelViewModel?.micLevel = 0
                    panelViewModel?.systemLevel = 0
                    sendEvent(.captureFailed(generation: stateMachine.generation))
                    break
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func displayLevel(_ level: Float) -> Float {
        let clamped = min(1, max(0, level))
        return (clamped * 20).rounded() / 20
    }

    /// Fast (~30 fps) audio channel for the live, near-real-time visualizers.
    /// Deliberately separate from `startPillPolling` (1 s): that loop writes the
    /// `@Observable` props (elapsed, state, mute) that fan out to the *whole*
    /// panel/tile body, so speeding it up would re-trigger the per-tick relayout
    /// this PR fixed. This loop only touches surfaces where a level change is
    /// cheap — the pill rosette's `CALayer` opacity (no `@Observable` at all) and
    /// the panel's `DualAudioOrbView`, whose read is isolated in the `LiveAudioOrb`
    /// leaf so only the 20pt orb re-renders. Runs only while actively recording
    /// (paused/processing states rest dim).
    private func startPillGlowPolling() {
        pillGlowPollingTask?.cancel()
        pillGlowPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if pillViewModel.state == .recording {
                    let mic = await meetingRecordingService.micLevel
                    let system = await meetingRecordingService.systemLevel
                    guard !Task.isCancelled else { break }
                    // Floating pill rosette: straight to CALayer opacity.
                    pillController?.updateLiveAudioLevel(max(mic, system))
                    // Panel orbs: quantized + change-gated, so a write (and the
                    // leaf re-render it triggers) fires only on a visible step.
                    if let panelViewModel {
                        let micQ = Self.displayLevel(mic)
                        let systemQ = Self.displayLevel(system)
                        if panelViewModel.micLevel != micQ {
                            panelViewModel.micLevel = micQ
                        }
                        if panelViewModel.systemLevel != systemQ {
                            panelViewModel.systemLevel = systemQ
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopPillGlowPolling() {
        pillGlowPollingTask?.cancel()
        pillGlowPollingTask = nil
    }

    private func stopPillPolling() {
        pillPollingTask?.cancel()
        pillPollingTask = nil
        stopPillGlowPolling()
    }

    private func startTranscriptObservation() {
        transcriptObservationTask?.cancel()
        transcriptObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await meetingRecordingService.transcriptUpdates
            for await update in stream {
                guard !Task.isCancelled else { break }
                let previewLines = await Task.detached(priority: .utility) {
                    Self.makePreviewLines(from: update)
                }.value
                guard !Task.isCancelled else { break }
                panelViewModel?.updatePreviewLines(
                    previewLines,
                    isTranscriptionLagging: update.isTranscriptionLagging
                )
            }
        }
    }

    private func stopTranscriptObservation() {
        transcriptObservationTask?.cancel()
        transcriptObservationTask = nil
    }

    private func startSpeechWarmUpObservation() {
        guard let sttManager else { return }

        speechWarmUpObservationTask?.cancel()
        speechWarmUpObservationTask = Task { @MainActor [weak self, sttManager] in
            let (observerId, stream) = await sttManager.observeWarmUpProgress()
            defer {
                Task {
                    await sttManager.removeWarmUpObserver(id: observerId)
                }
            }

            await sttManager.backgroundWarmUp()

            for await state in stream {
                guard !Task.isCancelled else { break }
                self?.handleSpeechWarmUpState(state)
            }
        }
    }

    private func stopSpeechWarmUpObservation() {
        speechWarmUpObservationTask?.cancel()
        speechWarmUpObservationTask = nil
    }

    private func handleSpeechWarmUpState(_ state: STTWarmUpState) {
        guard let panelViewModel, panelViewModel.previewLines.isEmpty else { return }

        switch state {
        case .idle:
            break
        case .working(let message, _):
            panelViewModel.updateLiveTranscriptStatus(.preparingSpeechModel(message: message))
        case .ready:
            if stateMachine.state != .starting {
                panelViewModel.updateLiveTranscriptStatus(.listening)
            }
        case .failed:
            panelViewModel.updateLiveTranscriptStatus(.previewUnavailable)
        }
    }

    nonisolated private static func makePreviewLines(from update: MeetingTranscriptUpdate)
        -> [MeetingRecordingPreviewLine]
    {
        let speakerLabels = Dictionary(uniqueKeysWithValues: update.speakers.map { ($0.id, $0.label) })
        let segments = TranscriptSegmenter.groupIntoSegments(words: update.words)
        return segments.map { segment in
            let source = segment.speakerId.flatMap(AudioSource.init(rawValue:))
            return MeetingRecordingPreviewLine(
                id: "\(segment.startMs)-\(segment.speakerId ?? "unknown")",
                timestamp: format(milliseconds: segment.startMs),
                speakerLabel: speakerLabels[segment.speakerId ?? ""] ?? source?.displayLabel ?? "Speaker",
                text: segment.text,
                source: source
            )
        }
    }

    nonisolated private static func format(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func openSystemSettings(for reason: MeetingRecordingPermissionFailure) {
        switch reason {
        case .microphone:
            permissionService.openMicrophoneSettings()
        case .screenRecording:
            permissionService.openScreenRecordingSettings()
        }
    }

    private func showMeetingPanel() {
        switch stateMachine.state {
        case .starting, .recording:
            break
        case .idle, .checkingPermissions, .stopping, .finishing:
            return
        }
        panelController?.show()
    }

    private func hideMeetingPanel() {
        panelController?.hide()
    }

    private func handleQueuedMeetingTranscriptionCompletion(_ completion: MeetingTranscriptionQueue.Completion) {
        switch completion {
        case .success(let item, let transcription):
            sendMeetingOperation(
                operationContext: item.operationContext,
                outcome: .success,
                trigger: item.trigger,
                output: item.recording,
                stage: .completeTranscription,
                liveWordCount: item.liveWordCount,
                liveTranscriptLagged: item.liveTranscriptLagged
            )
            onQueuedTranscriptionReady(transcription, stateMachine.state == .idle)

        case .failure(let item, let error):
            Telemetry.send(
                .meetingRecordingFailed(
                    errorType: TelemetryErrorClassifier.classify(error),
                    errorDetail: TelemetryErrorClassifier.errorDetail(error)
                ))
            sendMeetingOperation(
                operationContext: item.operationContext,
                outcome: .failure,
                trigger: item.trigger,
                output: item.recording,
                stage: .transcription,
                liveWordCount: item.liveWordCount,
                liveTranscriptLagged: item.liveTranscriptLagged,
                errorType: TelemetryErrorClassifier.classify(error)
            )
        }
    }

    private func persistLiveAskConversationIfNeeded(transcriptionID: UUID) {
        guard let chatViewModel = panelViewModel?.chatViewModel else { return }
        chatViewModel.cancelStreaming()
        chatViewModel.bindPersistedConversation(
            transcriptionId: transcriptionID,
            transcriptionRepo: transcriptionRepo,
            conversationRepo: conversationRepo
        )
    }

    private func sendMeetingOperation(
        outcome: ObservabilityOutcome,
        trigger: TelemetryMeetingOperationTrigger? = nil,
        output: MeetingRecordingOutput? = nil,
        stage: TelemetryMeetingOperationStage? = nil,
        durationSeconds: Double? = nil,
        liveWordCount: Int? = nil,
        liveTranscriptLagged: Bool? = nil,
        errorType: String? = nil
    ) {
        sendMeetingOperation(
            operationContext: currentMeetingOperationContext,
            outcome: outcome,
            trigger: trigger ?? currentMeetingTrigger,
            output: output,
            stage: stage,
            durationSeconds: durationSeconds,
            liveWordCount: liveWordCount,
            liveTranscriptLagged: liveTranscriptLagged,
            errorType: errorType
        )
    }

    private func sendMeetingOperation(
        operationContext: ObservabilityOperationContext?,
        outcome: ObservabilityOutcome,
        trigger: TelemetryMeetingOperationTrigger? = nil,
        output: MeetingRecordingOutput? = nil,
        stage: TelemetryMeetingOperationStage? = nil,
        durationSeconds: Double? = nil,
        liveWordCount: Int? = nil,
        liveTranscriptLagged: Bool? = nil,
        errorType: String? = nil
    ) {
        guard let operationContext else { return }
        let notes = output?.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        Telemetry.send(
            .meetingOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                outcome: outcome,
                trigger: trigger,
                stage: stage,
                durationSeconds: output?.durationSeconds ?? durationSeconds,
                liveWordCount: liveWordCount,
                liveTranscriptLagged: liveTranscriptLagged,
                microphoneTrackPresent: output.map { $0.sourceAlignment.microphone != nil },
                systemTrackPresent: output.map { $0.sourceAlignment.system != nil },
                notesUsed: notes.map { !$0.isEmpty },
                notesLengthBucket: output.map { Observability.textLengthBucket($0.userNotes) },
                errorType: errorType
            ))
    }
}

/// Hooks for unit tests. These stay internal and are not `#if DEBUG`-gated so
/// `swift test -c release` links the same as the auto-start coordinator tests.
extension MeetingRecordingFlowCoordinator {
    func testHook_enterRecording(
        operationContext: ObservabilityOperationContext = ObservabilityOperationContext(
            operationID: "test-meeting-operation",
            startedAt: Date(timeIntervalSince1970: 0)
        )
    ) {
        stateMachine = MeetingRecordingFlowStateMachine()
        currentMeetingOperationContext = operationContext
        currentMeetingTrigger = nil
        pendingTrigger = nil
        pendingTitle = nil
        pendingAudioSourceMode = nil
        _ = stateMachine.handle(.startRequested)
        _ = stateMachine.handle(.permissionsGranted(generation: stateMachine.generation))
        _ = stateMachine.handle(.recordingStarted(generation: stateMachine.generation))
    }

    var testHook_state: MeetingRecordingFlowState {
        stateMachine.state
    }

    func testHook_waitForActionTask() async {
        await actionTask?.value
    }

    func testHook_waitForMeetingTranscriptionQueue() async {
        await meetingTranscriptionQueue.waitUntilIdle()
    }

    var testHook_panelChatViewModel: TranscriptChatViewModel? {
        panelViewModel?.chatViewModel
    }
}
