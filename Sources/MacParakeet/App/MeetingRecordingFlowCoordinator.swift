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
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onTranscriptionReady: @escaping (Transcription) -> Void,
        onRecordingBegan: @escaping () -> Void = {},
        onFlowReturnedToIdle: @escaping () -> Void = {}
    ) {
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionService = transcriptionService
        self.permissionService = permissionService
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onTranscriptionReady = onTranscriptionReady
        self.onRecordingBegan = onRecordingBegan
        self.onFlowReturnedToIdle = onFlowReturnedToIdle
    }

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
            pillController?.onOpenApp = {
                NSApp.activate(ignoringOtherApps: true)
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
            actionTask = Task { @MainActor in
                do {
                    try await meetingRecordingService.startRecording()
                    self.onRecordingBegan()
                    self.sendEvent(.recordingStarted(generation: gen))
                } catch {
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
            actionTask = Task { @MainActor in
                do {
                    let output = try await meetingRecordingService.stopRecording()
                    let transcription = try await transcriptionService.transcribeMeeting(recording: output, onProgress: nil)
                    self.completedTranscription = transcription
                    self.sendEvent(.transcriptionCompleted(generation: gen, transcriptionID: transcription.id))
                } catch {
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
            actionTask?.cancel()
            actionTask = Task { @MainActor in
                await meetingRecordingService.cancelRecording()
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
        return Array(segments.suffix(3)).map { segment in
            let source = segment.speakerId.flatMap(AudioSource.init(rawValue:))
            return MeetingRecordingPreviewLine(
                id: "\(segment.startMs)-\(segment.speakerId ?? "unknown")-\(segment.text)",
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
