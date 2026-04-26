import AppKit
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class MeetingRecordingFlowCoordinator {
    var isMeetingRecordingActive: Bool {
        switch stateMachine.state {
        case .idle, .finishing:
            return false
        case .checkingPermissions, .starting, .recording, .stopping, .transcribing:
            return true
        }
    }

    private let meetingRecordingService: MeetingRecordingServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let transcriptionRepo: TranscriptionRepositoryProtocol
    private let conversationRepo: ChatConversationRepositoryProtocol
    private let configStore: LLMConfigStoreProtocol
    private let cliConfigStore: LocalCLIConfigStore
    private var llmService: LLMServiceProtocol?
    private let onMenuBarIconUpdate: (BreathWaveIcon.MenuBarState) -> Void
    private let onTranscriptionReady: (Transcription) -> Void
    private let onRecordingBegan: () -> Void
    private let onFlowReturnedToIdle: () -> Void

    private var stateMachine = MeetingRecordingFlowStateMachine()
    private var pillController: MeetingRecordingPillController?
    private var pillViewModel: MeetingRecordingPillViewModel?
    private var panelController: MeetingRecordingPanelController?
    private var panelViewModel: MeetingRecordingPanelViewModel?
    private var actionTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var pillPollingTask: Task<Void, Never>?
    private var transcriptObservationTask: Task<Void, Never>?
    private var completedTranscription: Transcription?

    init(
        meetingRecordingService: MeetingRecordingServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        permissionService: PermissionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        conversationRepo: ChatConversationRepositoryProtocol,
        configStore: LLMConfigStoreProtocol,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore(),
        llmService: LLMServiceProtocol?,
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onTranscriptionReady: @escaping (Transcription) -> Void,
        onRecordingBegan: @escaping () -> Void = {},
        onFlowReturnedToIdle: @escaping () -> Void = {}
    ) {
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionService = transcriptionService
        self.permissionService = permissionService
        self.transcriptionRepo = transcriptionRepo
        self.conversationRepo = conversationRepo
        self.configStore = configStore
        self.cliConfigStore = cliConfigStore
        self.llmService = llmService
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onTranscriptionReady = onTranscriptionReady
        self.onRecordingBegan = onRecordingBegan
        self.onFlowReturnedToIdle = onFlowReturnedToIdle
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
    /// hop. Manual / hotkey starts leave it nil and the service falls back
    /// to its date-based default.
    private var pendingTitle: String?

    /// Optional callback fired when an auto-start attempt couldn't actually
    /// start a recording — either because the state machine wasn't idle
    /// (back-to-back meeting, previous wrap-up still in progress) or the
    /// underlying `startRecording()` threw. The auto-start coordinator
    /// uses this to clear its `autoStartedEventId` binding so a stale id
    /// doesn't suppress the *next* meeting's auto-stop.
    var onAutoStartFailed: (() -> Void)?

    func toggleRecording() {
        switch stateMachine.state {
        case .idle:
            sendEvent(.startRequested)
        case .recording, .starting, .stopping:
            sendEvent(.stopRequested)
        case .checkingPermissions, .transcribing, .finishing:
            break
        }
    }

    /// Calendar-driven entry point. Marks the next start as auto-start so
    /// telemetry distinguishes it and pre-names the recording with the
    /// event title, then enters the normal start flow. No-op if a recording
    /// is already in progress (manual recording wins by arriving first —
    /// see ADR-017 §10). When non-idle, fires `onAutoStartFailed` so the
    /// calendar coordinator can drop its binding, and emits
    /// `calendar_auto_start_failed{reason=state_busy}` so we can see how
    /// often back-to-back meetings actually collide in the wild.
    func startFromCalendar(title: String? = nil) {
        guard stateMachine.state == .idle else {
            Telemetry.send(.calendarAutoStartFailed(reason: "state_busy"))
            onAutoStartFailed?()
            return
        }
        pendingTrigger = .calendarAutoStart
        pendingTitle = title
        sendEvent(.startRequested)
    }

    /// Discard the pending start context (trigger + title) when the start
    /// sequence exits without ever reaching the `.startRecording` effect —
    /// today, only the permissions-denied path. The `.startRecording`
    /// effect handler clears these inline because it needs to snapshot
    /// them first to fire telemetry; this helper is for the paths that
    /// bail out earlier. If the bailing-out start was calendar-driven,
    /// emits `calendar_auto_start_failed{reason}` and notifies the
    /// calendar coordinator so its `autoStartedEventId` binding doesn't
    /// strand (it self-heals on the next poll, but notifying immediately
    /// keeps the two coordinators in lockstep).
    private func clearPendingStartContext(failureReason: String) {
        let wasCalendarTriggered = pendingTrigger == .calendarAutoStart
        pendingTrigger = nil
        pendingTitle = nil
        if wasCalendarTriggered {
            Telemetry.send(.calendarAutoStartFailed(reason: failureReason))
            onAutoStartFailed?()
        }
    }

    private func sendEvent(_ event: MeetingRecordingFlowEvent) {
        let effects = stateMachine.handle(event)
        executeEffects(effects)
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
                let microphoneStatus = await permissionService.checkMicrophonePermission()
                let microphoneGranted: Bool
                switch microphoneStatus {
                case .granted:
                    microphoneGranted = true
                case .denied:
                    microphoneGranted = false
                case .notDetermined:
                    Telemetry.send(.permissionPrompted(permission: .microphone))
                    microphoneGranted = await permissionService.requestMicrophonePermission()
                }

                if !microphoneGranted {
                    Telemetry.send(.permissionDenied(permission: .microphone))
                    self.clearPendingStartContext(failureReason: "permission_denied")
                    self.sendEvent(.permissionsDenied(generation: gen, reason: .microphone))
                    return
                }
                Telemetry.send(.permissionGranted(permission: .microphone))

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
                Telemetry.send(.permissionGranted(permission: .screenRecording))
                self.sendEvent(.permissionsGranted(generation: gen))
            }

        case .showRecordingPill:
            let vm = pillViewModel ?? MeetingRecordingPillViewModel()
            vm.onStop = { [weak self] in self?.toggleRecording() }
            vm.state = .recording
            pillViewModel = vm
            let panelVM = panelViewModel ?? MeetingRecordingPanelViewModel()
            panelVM.state = .recording
            panelVM.elapsedSeconds = 0
            panelVM.micLevel = 0
            panelVM.systemLevel = 0
            panelVM.updatePreviewLines([], isTranscriptionLagging: false)
            panelVM.onStop = { [weak self] in self?.toggleRecording() }
            panelVM.onClose = { [weak self] in self?.hideMeetingPanel() }
            // Configure live Ask: in-memory mode (no transcriptionId/conversationRepo).
            // Promotion to a persisted ChatConversation happens in .navigateToTranscription.
            panelVM.chatViewModel.configure(
                llmService: llmService,
                transcriptText: panelVM.chatTranscript,
                configStore: configStore,
                cliConfigStore: cliConfigStore
            )
            // Wire the notepad's debounced persistence target through the
            // recording service. The service serializes lock-file writes and
            // carries the latest notes into MeetingRecordingOutput.userNotes,
            // where TranscriptionService persists them onto the Transcription
            // for Memo-Steered Notes summary generation (ADR-020 §8, §10).
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
                self?.sendEvent(.stopRequested)
            }
            pillController?.onOpenApp = { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showMeetingPanel()
            }
            pillController?.onCancelRecording = { [weak self] in
                self?.confirmAndCancelRecording()
            }
            if panelController == nil {
                let controller = MeetingRecordingPanelController(viewModel: panelVM)
                controller.onCloseRequested = { [weak self] in
                    self?.hideMeetingPanel()
                }
                panelController = controller
            }
            pillController?.show()
            startPillPolling()
            startTranscriptObservation()

        case .startRecording:
            let gen = stateMachine.generation
            // Snapshot + clear before the async hop so a subsequent toggle
            // can't smuggle a stale trigger / title into this start.
            let trigger = pendingTrigger
            let title = pendingTitle
            pendingTrigger = nil
            pendingTitle = nil
            actionTask = Task { @MainActor in
                do {
                    try await meetingRecordingService.startRecording(title: title)
                    Telemetry.send(.meetingRecordingStarted(trigger: trigger))
                    self.onRecordingBegan()
                    self.sendEvent(.recordingStarted(generation: gen))
                } catch {
                    Telemetry.send(.meetingRecordingFailed(
                        errorType: TelemetryErrorClassifier.classify(error),
                        errorDetail: TelemetryErrorClassifier.errorDetail(error)
                    ))
                    // If this start was driven by calendar auto-start, tell
                    // the coordinator so it can drop the binding it set
                    // optimistically when the countdown completed, and emit
                    // the dedicated failure event so analysts can see *why*
                    // (vs just inferring "silent failure" by subtraction
                    // from `.calendarAutoStartTriggered`).
                    if trigger == .calendarAutoStart {
                        Telemetry.send(.calendarAutoStartFailed(reason: "service_threw"))
                        self.onAutoStartFailed?()
                    }
                    self.sendEvent(.startFailed(generation: gen, message: error.localizedDescription))
                }
            }

        case .showTranscribingState:
            stopPillPolling()
            stopTranscriptObservation()
            pillViewModel?.micLevel = 0
            pillViewModel?.systemLevel = 0
            pillViewModel?.state = .completing
            pillViewModel?.onCompletionAnimationFinished = { [weak self] in
                guard let self, self.pillViewModel?.state == .completing else { return }
                // Flower collapsed — show merkaba spinner (or checkmark if already done)
                if self.completedTranscription != nil {
                    self.pillViewModel?.state = .completed
                    // Auto-dismiss was skipped during collapse — start it now
                    self.autoDismissTask?.cancel()
                    let gen = self.stateMachine.generation
                    self.autoDismissTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        self?.sendEvent(.autoDismissExpired(generation: gen))
                    }
                } else {
                    self.pillViewModel?.state = .transcribing
                }
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
            actionTask = Task { @MainActor in
                do {
                    // Flush any keystrokes typed in the last < 250 ms so
                    // they make it onto the lock file and into the saved
                    // Transcription.userNotes (ADR-020 §8).
                    await notesVM?.commit()
                    let output = try await meetingRecordingService.stopRecording()
                    Telemetry.send(.meetingRecordingCompleted(
                        durationSeconds: output.durationSeconds,
                        liveWordCount: liveWordCount,
                        liveTranscriptLagged: liveTranscriptLagged
                    ))
                    let transcription = try await transcriptionService.transcribeMeeting(recording: output, onProgress: nil)
                    await meetingRecordingService.completeTranscription(for: output)
                    self.completedTranscription = transcription
                    self.sendEvent(.transcriptionCompleted(generation: gen, transcriptionID: transcription.id))
                } catch {
                    Telemetry.send(.meetingRecordingFailed(
                        errorType: TelemetryErrorClassifier.classify(error),
                        errorDetail: TelemetryErrorClassifier.errorDetail(error)
                    ))
                    self.sendEvent(.transcriptionFailed(generation: gen, message: error.localizedDescription))
                }
            }

        case .showCompleted:
            stopPillPolling()
            stopTranscriptObservation()
            // If flower is still collapsing, the callback will check completedTranscription
            // If spinner is showing, transition to checkmark now
            if pillViewModel?.state == .transcribing {
                pillViewModel?.state = .completed
            }
            panelViewModel?.state = .hidden

        case .cancelRecording:
            let durationSeconds = Double(panelViewModel?.elapsedSeconds ?? 0)
            actionTask?.cancel()
            actionTask = Task { @MainActor in
                await meetingRecordingService.cancelRecording()
                Telemetry.send(.meetingRecordingCancelled(durationSeconds: durationSeconds))
            }

        case .showError(let message):
            stopPillPolling()
            stopTranscriptObservation()
            pillViewModel?.state = .error(message)
            panelViewModel?.state = .error(message)
            hideMeetingPanel()

        case .hidePill:
            stopPillPolling()
            stopTranscriptObservation()
            pillController?.hide()
            pillController = nil
            pillViewModel = nil
            panelController?.close()
            panelController = nil
            panelViewModel = nil
            completedTranscription = nil
            onFlowReturnedToIdle()

        case .updateMenuBar(let state):
            let iconState: BreathWaveIcon.MenuBarState = switch state {
            case .idle: .idle
            case .recording: .recording
            case .processing: .processing
            }
            onMenuBarIconUpdate(iconState)

        case .navigateToTranscription(let id):
            guard completedTranscription?.id == id, let transcription = completedTranscription else { return }
            // Cancel any in-flight assistant response BEFORE binding. If the panel
            // chat VM is destroyed (.hidePill, ~2s after this) while a stream is
            // still arriving, the streamingTask's [weak self] kills it mid-write
            // and the response is lost in a non-deterministic spot. Cancelling now
            // gives a clean state to persist; the user loses an unfinished reply
            // but the data on disk is consistent.
            panelViewModel?.chatViewModel.cancelStreaming()
            // If the user chatted while recording, promote the in-memory thread to a
            // real ChatConversation linked to the finalized transcription so the live
            // conversation appears on TranscriptResultView's Chat tab unbroken.
            panelViewModel?.chatViewModel.bindPersistedConversation(
                transcriptionId: transcription.id,
                transcriptionRepo: transcriptionRepo,
                conversationRepo: conversationRepo
            )
            onTranscriptionReady(transcription)

        case .presentPermissionAlert(let reason):
            onFlowReturnedToIdle()
            presentPermissionAlert(for: reason)

        case .startAutoDismissTimer(let seconds):
            // Skip auto-dismiss when flower collapse animation is still playing
            if pillViewModel?.state == .completing {
                break
            }
            // Give checkmark time to animate in and hold before dismissing
            let adjustedSeconds = pillViewModel?.state == .completed ? 2.0 : seconds
            autoDismissTask?.cancel()
            let gen = stateMachine.generation
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(adjustedSeconds))
                guard !Task.isCancelled else { return }
                self.sendEvent(.autoDismissExpired(generation: gen))
            }

        case .cancelAutoDismissTimer:
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    private func confirmAndCancelRecording() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard Recording?"
        alert.informativeText = "This will stop the meeting recording and delete all captured audio. This cannot be undone."
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
            alert.informativeText = "Meeting recording needs Screen & System Audio Recording access to capture system audio."
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
                let micLevel = await meetingRecordingService.micLevel
                let systemLevel = await meetingRecordingService.systemLevel
                let elapsedSeconds = await meetingRecordingService.elapsedSeconds
                let captureMode = await meetingRecordingService.captureMode

                guard !Task.isCancelled else { break }
                pillViewModel?.micLevel = micLevel
                pillViewModel?.systemLevel = systemLevel
                pillViewModel?.elapsedSeconds = elapsedSeconds
                panelViewModel?.elapsedSeconds = elapsedSeconds
                panelViewModel?.micLevel = micLevel
                panelViewModel?.systemLevel = systemLevel
                if captureMode == .stopped, pillViewModel?.state == .recording {
                    pillViewModel?.micLevel = 0
                    pillViewModel?.systemLevel = 0
                    panelViewModel?.micLevel = 0
                    panelViewModel?.systemLevel = 0
                }

                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stopPillPolling() {
        pillPollingTask?.cancel()
        pillPollingTask = nil
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

    nonisolated private static func makePreviewLines(from update: MeetingTranscriptUpdate) -> [MeetingRecordingPreviewLine] {
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
        case .idle, .checkingPermissions, .stopping, .transcribing, .finishing:
            return
        }
        panelController?.show()
    }

    private func hideMeetingPanel() {
        panelController?.hide()
    }
}
