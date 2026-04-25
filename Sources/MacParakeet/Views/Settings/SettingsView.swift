import Foundation
import Sparkle
import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var llmSettingsViewModel: LLMSettingsViewModel
    let updater: SPUUpdater

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    @State private var showClearAllAlert = false
    @State private var showClearYouTubeAudioAlert = false
    @State private var showResetLifetimeStatsAlert = false
    @State private var copiedBuildIdentity = false

    init(viewModel: SettingsViewModel, llmSettingsViewModel: LLMSettingsViewModel, updater: SPUUpdater) {
        self.viewModel = viewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.updater = updater
        self._automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        self._automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerCard
                audioInputCard
                dictationCard
                if AppFeatures.meetingRecordingEnabled {
                    meetingRecordingCard
                    calendarCard
                }
                transcriptionCard
                aiProviderCard
                storageCard
                generalCard
                updatesCard
                localModelsCard
                privacyCard
                permissionsCard
                onboardingCard
                aboutCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .alert("Clear All Dictations?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                viewModel.clearAllDictations()
            }
        } message: {
            Text("This will permanently delete all \(viewModel.dictationCount) dictation\(viewModel.dictationCount == 1 ? "" : "s"), their audio files, and any private metric-only entries. Lifetime stats are not affected. This cannot be undone.")
        }
        .alert("Reset Lifetime Stats?", isPresented: $showResetLifetimeStatsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                viewModel.resetLifetimeStats()
            }
        } message: {
            Text("This will zero your total words, total time, total dictation count, and longest dictation. Your dictation history is not affected. This cannot be undone.")
        }
        .alert("Clear Downloaded YouTube Audio?", isPresented: $showClearYouTubeAudioAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Audio", role: .destructive) {
                viewModel.clearDownloadedYouTubeAudio()
            }
        } message: {
            Text("This will permanently delete all downloaded YouTube audio files and detach them from existing transcriptions.")
        }
        .onAppear {
            viewModel.refreshLaunchAtLoginStatus()
            viewModel.startPermissionPolling()
            viewModel.refreshStats()
            viewModel.refreshEntitlements()
            viewModel.refreshModelStatus()
        }
        .onDisappear {
            viewModel.stopPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        settingsCard(
            title: "Workspace Controls",
            subtitle: "Everything runs locally on your Mac.",
            icon: "slider.horizontal.3"
        ) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DesignSystem.Spacing.md), count: 4),
                spacing: DesignSystem.Spacing.md
            ) {
                statChip(
                    title: "Dictations",
                    value: "\(viewModel.dictationCount)"
                )

                statChip(
                    title: "YouTube Cache",
                    value: viewModel.formattedYouTubeStorage
                )

                statChip(
                    title: "Microphone",
                    value: viewModel.microphoneGranted ? "Granted" : "Missing",
                    isHealthy: viewModel.microphoneGranted
                )

                statChip(
                    title: "Accessibility",
                    value: viewModel.accessibilityGranted ? "Granted" : "Missing",
                    isHealthy: viewModel.accessibilityGranted
                )
            }
        }
    }

    // MARK: - Audio Input

    private var audioInputCard: some View {
        settingsCard(
            title: "Audio Input",
            subtitle: "Choose the microphone used for dictation and meetings.",
            icon: "mic"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Microphone",
                        detail: viewModel.selectedMicrophoneStatusText
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Picker("Microphone", selection: $viewModel.selectedMicrophoneDeviceUID) {
                            Text("System Default").tag(SettingsViewModel.systemDefaultMicrophoneSelection)
                            ForEach(viewModel.microphoneDeviceOptions) { device in
                                Text(device.displayName).tag(device.uid)
                                    .disabled(!device.isAvailable)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                        Button {
                            viewModel.refreshMicrophoneDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("Refresh microphones")
                        .accessibilityLabel("Refresh microphones")
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                    microphoneTestStatus
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Button {
                        switch viewModel.microphoneTestState {
                        case .testing:
                            viewModel.cancelMicrophoneTest()
                        default:
                            viewModel.testSelectedMicrophone()
                        }
                    } label: {
                        Label(
                            viewModel.microphoneTestState == .testing ? "Stop Test" : "Test Input",
                            systemImage: viewModel.microphoneTestState == .testing ? "stop.fill" : "waveform"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(!viewModel.microphoneGranted && viewModel.microphoneTestState != .testing)
                }
            }
        }
    }

    private var microphoneTestStatus: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            microphoneLevelMeter(level: viewModel.microphoneTestLevel)
            VStack(alignment: .leading, spacing: 2) {
                Text(microphoneTestTitle)
                    .font(DesignSystem.Typography.body)
                Text(microphoneTestDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(microphoneTestDetailColor)
                    .lineLimit(2)
            }
        }
    }

    private var microphoneTestTitle: String {
        switch viewModel.microphoneTestState {
        case .idle:
            return "Input test"
        case .testing:
            return "Listening..."
        case .succeeded:
            return "Input detected"
        case .failed:
            return "Input test failed"
        }
    }

    private var microphoneTestDetail: String {
        switch viewModel.microphoneTestState {
        case .idle:
            return viewModel.microphoneGranted ? "Run a short level check before recording." : "Grant microphone permission before testing."
        case .testing:
            return "Speak into the selected microphone."
        case .succeeded:
            return "This microphone is producing audio."
        case .failed(let message):
            return message
        }
    }

    private var microphoneTestDetailColor: Color {
        switch viewModel.microphoneTestState {
        case .failed:
            return DesignSystem.Colors.errorRed
        default:
            return .secondary
        }
    }

    private func microphoneLevelMeter(level: Float) -> some View {
        GeometryReader { proxy in
            let clamped = CGFloat(max(0, min(1, level)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated)
                Capsule()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: max(6, proxy.size.width * clamped))
                    .animation(.easeOut(duration: 0.12), value: clamped)
            }
        }
        .frame(width: 96, height: 8)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(max(0, min(1, level)) * 100)) percent")
    }

    // MARK: - General

    private var generalCard: some View {
        settingsCard(
            title: "General",
            subtitle: "How MacParakeet shows up on your Mac.",
            icon: "gearshape"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Show dictation pill at all times",
                    detail: "When off, the pill hides until you press the hotkey.",
                    isOn: $viewModel.showIdlePill
                )

                Divider()

                settingsToggleRow(
                    title: "Launch at login",
                    detail: "Start MacParakeet automatically when you sign in.",
                    isOn: $viewModel.launchAtLogin
                )

                if !viewModel.launchAtLoginDetail.isEmpty || viewModel.launchAtLoginError != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if !viewModel.launchAtLoginDetail.isEmpty {
                            Text(viewModel.launchAtLoginDetail)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let error = viewModel.launchAtLoginError {
                            Text(error)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.errorRed)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                settingsToggleRow(
                    title: "Menu bar only mode",
                    detail: "Hide the Dock icon and run from the menu bar only.",
                    isOn: $viewModel.menuBarOnlyMode
                )
            }
        }
    }

    // MARK: - Dictation

    private var dictationCard: some View {
        settingsCard(
            title: "Dictation",
            subtitle: "Global hotkey and silence behavior.",
            icon: "waveform"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Hotkey",
                        detail: "System-wide key used to start and stop dictation."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(trigger: $viewModel.hotkeyTrigger) { candidate in
                            guard AppFeatures.meetingRecordingEnabled else { return .allowed }
                            guard !candidate.isDisabled, candidate == viewModel.meetingHotkeyTrigger else { return .allowed }
                            return .blocked("Already used by meeting recording.")
                        }

                        if AppFeatures.meetingRecordingEnabled,
                           !viewModel.hotkeyTrigger.isDisabled,
                           viewModel.hotkeyTrigger == viewModel.meetingHotkeyTrigger {
                            hotkeyConflictText
                        }
                    }
                }

                if !viewModel.hotkeyTrigger.isDisabled {
                    Divider()

                    dictationModeGuide
                }

                Divider()

                settingsToggleRow(
                    title: "Auto-stop after silence",
                    detail: "Stops recording when speech pauses for the selected delay.",
                    isOn: $viewModel.silenceAutoStop
                )

                if viewModel.silenceAutoStop {
                    Divider()
                    HStack(alignment: .center) {
                        rowText(
                            title: "Silence delay",
                            detail: "How long silence must persist before dictation stops."
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Picker("Silence delay", selection: $viewModel.silenceDelay) {
                            Text("1 sec").tag(1.0)
                            Text("1.5 sec").tag(1.5)
                            Text("2 sec").tag(2.0)
                            Text("3 sec").tag(3.0)
                            Text("5 sec").tag(5.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
            }
        }
    }

    // MARK: - Transcription

    private var meetingRecordingCard: some View {
        settingsCard(
            title: "Meeting Recording",
            subtitle: "Dedicated controls for system-audio + mic capture.",
            icon: "record.circle"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Meeting hotkey",
                        detail: "Global shortcut that immediately starts or stops meeting recording."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(
                            trigger: $viewModel.meetingHotkeyTrigger,
                            defaultTrigger: .defaultMeetingRecording
                        ) { candidate in
                            guard !candidate.isDisabled, candidate == viewModel.hotkeyTrigger else { return .allowed }
                            return .blocked("Already used by dictation.")
                        }

                        if !viewModel.meetingHotkeyTrigger.isDisabled, viewModel.hotkeyTrigger == viewModel.meetingHotkeyTrigger {
                            hotkeyConflictText
                        }
                    }
                }

                Divider()

                settingsToggleRow(
                    title: "Auto-save meetings to disk",
                    detail: "Automatically write a file to the chosen folder after every meeting recording completes.",
                    isOn: $viewModel.meetingAutoSave
                )

                if viewModel.meetingAutoSave {
                    meetingAutoSaveOptionsView
                }
            }
        }
    }

    private var meetingAutoSaveOptionsView: some View {
        autoSaveOptions(
            format: $viewModel.meetingAutoSaveFormat,
            folderPath: viewModel.meetingAutoSaveFolderPath,
            formatDetail: "File format for saved meetings.",
            panelMessage: "Select a folder for auto-saved meeting recordings",
            onChooseFolder: { viewModel.chooseMeetingAutoSaveFolder(url: $0) },
            onClearFolder: { viewModel.clearMeetingAutoSaveFolder() }
        )
    }

    // MARK: - Calendar Auto-Start

    private var calendarCard: some View {
        settingsCard(
            title: "Calendar",
            subtitle: "Reminders before scheduled meetings, powered by your macOS calendar.",
            icon: "calendar"
        ) {
            CalendarSettingsView(viewModel: viewModel)
        }
    }

    private var transcriptionCard: some View {
        settingsCard(
            title: "Transcription",
            subtitle: "Options for file and YouTube transcription.",
            icon: "doc.text"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                transcriptionHotkeyRow(
                    title: "File transcription hotkey",
                    detail: "Opens the file picker from anywhere on macOS.",
                    trigger: $viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "YouTube transcription"
                )

                Divider()

                transcriptionHotkeyRow(
                    title: "YouTube transcription hotkey",
                    detail: "Opens the YouTube URL panel from anywhere on macOS.",
                    trigger: $viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "file transcription"
                )

                Divider()

                settingsToggleRow(
                    title: "Speaker detection",
                    detail: "Identify who said what using Pyannote community-1. Typically ~85% accurate — best with clear audio and distinct voices.",
                    isOn: $viewModel.speakerDiarization
                )

                Divider()

                settingsToggleRow(
                    title: "Auto-save transcripts to disk",
                    detail: "Automatically write a file to the chosen folder after every transcription completes.",
                    isOn: $viewModel.autoSaveTranscripts
                )

                if viewModel.autoSaveTranscripts {
                    autoSaveOptionsView
                }
            }
        }
    }

    /// A transcription-hotkey row with a recorder and an inline conflict
    /// warning when the trigger collides with dictation, meeting, or the
    /// other transcription hotkey. Default trigger is `.disabled` — users opt
    /// in by recording a key.
    private func transcriptionHotkeyRow(
        title: String,
        detail: String,
        trigger: Binding<HotkeyTrigger>,
        otherTranscriptionTrigger: HotkeyTrigger,
        otherTranscriptionName: String
    ) -> some View {
        HStack(alignment: .center) {
            rowText(title: title, detail: detail)
            Spacer(minLength: DesignSystem.Spacing.md)
            VStack(alignment: .trailing, spacing: 4) {
                HotkeyRecorderView(
                    trigger: trigger,
                    defaultTrigger: .disabled
                ) { candidate in
                    guard !candidate.isDisabled else { return .allowed }
                    if candidate == viewModel.hotkeyTrigger {
                        return .blocked("Already used by dictation.")
                    }
                    if AppFeatures.meetingRecordingEnabled, candidate == viewModel.meetingHotkeyTrigger {
                        return .blocked("Already used by meeting recording.")
                    }
                    if candidate == otherTranscriptionTrigger {
                        return .blocked("Already used by \(otherTranscriptionName).")
                    }
                    return .allowed
                }

                if let conflict = conflictMessage(
                    trigger: trigger.wrappedValue,
                    otherTranscription: otherTranscriptionTrigger,
                    otherTranscriptionName: otherTranscriptionName
                ) {
                    transcriptionHotkeyConflictText(conflict)
                }
            }
        }
    }

    private func conflictMessage(
        trigger: HotkeyTrigger,
        otherTranscription: HotkeyTrigger,
        otherTranscriptionName: String
    ) -> String? {
        guard !trigger.isDisabled else { return nil }
        if trigger == viewModel.hotkeyTrigger {
            return "Disabled — conflicts with dictation hotkey."
        }
        if AppFeatures.meetingRecordingEnabled, trigger == viewModel.meetingHotkeyTrigger {
            return "Disabled — conflicts with meeting recording hotkey."
        }
        if trigger == otherTranscription {
            return "Disabled — conflicts with \(otherTranscriptionName) hotkey."
        }
        return nil
    }

    private func transcriptionHotkeyConflictText(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    private var hotkeyConflictText: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
            Text("Dictation and meeting recording cannot use the same shortcut.")
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    private var autoSaveOptionsView: some View {
        autoSaveOptions(
            format: $viewModel.autoSaveFormat,
            folderPath: viewModel.autoSaveFolderPath,
            formatDetail: "File format for saved transcripts.",
            panelMessage: "Select a folder for auto-saved transcripts",
            onChooseFolder: { viewModel.chooseAutoSaveFolder(url: $0) },
            onClearFolder: { viewModel.clearAutoSaveFolder() }
        )
    }

    private func autoSaveOptions(
        format: Binding<AutoSaveFormat>,
        folderPath: String?,
        formatDetail: String,
        panelMessage: String,
        onChooseFolder: @escaping (URL) -> Void,
        onClearFolder: @escaping () -> Void
    ) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack {
                rowText(title: "Format", detail: formatDetail)
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("", selection: format) {
                    ForEach(AutoSaveFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(DesignSystem.Typography.body)
                    if let path = folderPath {
                        Text(path)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder selected")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                if folderPath != nil {
                    Button("Clear") { onClearFolder() }
                        .buttonStyle(.bordered)
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Choose"
                    panel.message = panelMessage
                    if panel.runModal() == .OK, let url = panel.url {
                        onChooseFolder(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    // MARK: - AI Provider

    private var aiProviderCard: some View {
        settingsCard(
            title: "AI Provider",
            subtitle: "Optional. Powers transcript summaries and chat.",
            icon: "brain"
        ) {
            LLMSettingsView(viewModel: llmSettingsViewModel)
        }
    }

    // MARK: - Storage

    private var storageCard: some View {
        settingsCard(
            title: "Storage",
            subtitle: "Manage recordings and disk usage.",
            icon: "internaldrive"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Save dictation history",
                    detail: "When off, dictations are transcribed and pasted but not saved. Voice stats still tracked.",
                    isOn: $viewModel.saveDictationHistory
                )

                Divider()

                settingsToggleRow(
                    title: "Save audio recordings",
                    detail: "Keep audio alongside your dictation history.",
                    isOn: $viewModel.saveAudioRecordings
                )

                Divider()

                settingsToggleRow(
                    title: "Keep downloaded YouTube audio",
                    detail: "Turn off to auto-delete downloaded audio after transcription.",
                    isOn: $viewModel.saveTranscriptionAudio
                )

                Divider()

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: DesignSystem.Spacing.md)],
                    spacing: DesignSystem.Spacing.md
                ) {
                    metricTile(
                        title: "Dictation Records",
                        value: "\(viewModel.dictationCount)",
                        detail: viewModel.dictationCount == 1 ? "entry" : "entries"
                    )

                    metricTile(
                        title: "YouTube Downloads",
                        value: "\(viewModel.youtubeDownloadCount)",
                        detail: viewModel.formattedYouTubeStorage
                    )
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    maintenanceGroup(
                        label: "Delete data",
                        detail: "Removes rows from your library. Lifetime stats are preserved."
                    ) {
                        Button("Clear All Dictations...", role: .destructive) {
                            showClearAllAlert = true
                        }
                        .buttonStyle(.bordered)

                        Button("Clear Downloaded YouTube Audio...", role: .destructive) {
                            showClearYouTubeAudioAlert = true
                        }
                        .buttonStyle(.bordered)
                    }

                    maintenanceGroup(
                        label: "Reset counters",
                        detail: "Zeros lifetime stats. Your dictation history is untouched."
                    ) {
                        Button("Reset Lifetime Stats...", role: .destructive) {
                            showResetLifetimeStatsAlert = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.errorRed.opacity(0.06))
                )
            }
        }
    }

    // MARK: - Permissions

    private var localModelsCard: some View {
        settingsCard(
            title: "Speech Model",
            subtitle: "Parakeet powers all speech recognition on your Mac.",
            icon: "cpu"
        ) {
            modelStatusRow(
                title: "Parakeet (Speech)",
                detail: viewModel.parakeetStatusDetail,
                status: viewModel.parakeetStatus,
                isRepairing: viewModel.parakeetRepairing
            ) {
                viewModel.repairParakeetModel()
            }
        }
    }

    private var permissionsCard: some View {
        let permissionsSubtitle = AppFeatures.meetingRecordingEnabled
            ? "Microphone and Accessibility are required. Screen Recording is optional for meetings."
            : "Microphone and Accessibility are required."

        return settingsCard(
            title: "Permissions",
            subtitle: permissionsSubtitle,
            icon: "lock.shield"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack {
                    rowText(title: "Microphone", detail: "Required for voice capture.")
                    Spacer()
                    permissionPill(granted: viewModel.microphoneGranted)
                }

                Divider()

                HStack {
                    rowText(title: "Accessibility", detail: "Required for global hotkey and paste.")
                    Spacer()
                    permissionPill(granted: viewModel.accessibilityGranted)
                }

                if AppFeatures.meetingRecordingEnabled {
                    Divider()

                    HStack {
                        rowText(
                            title: "Screen & System Audio Recording",
                            detail: "Optional. Only used for meeting audio capture. MacParakeet never records your screen."
                        )
                        Spacer()
                        permissionPill(granted: viewModel.screenRecordingGranted)
                    }
                }

                let needsScreenRecordingAction = AppFeatures.meetingRecordingEnabled && !viewModel.screenRecordingGranted
                if !viewModel.accessibilityGranted || needsScreenRecordingAction {
                    Divider()
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if !viewModel.accessibilityGranted {
                            Button("Open Accessibility Settings") {
                                openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.accent)
                        }

                        if needsScreenRecordingAction {
                            Button("Enable meeting recording") {
                                viewModel.requestScreenRecordingAccess()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.accent)

                            Button("Open Screen Recording Settings") {
                                viewModel.openScreenRecordingSystemSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        settingsCard(
            title: "Privacy",
            subtitle: "Your audio and transcriptions never leave your device.",
            icon: "hand.raised"
        ) {
            settingsToggleRow(
                title: "Help improve MacParakeet",
                detail: "Send non-identifying usage statistics like feature popularity and performance metrics. No personal data is collected.",
                isOn: $viewModel.telemetryEnabled
            )
        }
    }

    // MARK: - Updates

    private var updatesCard: some View {
        settingsCard(
            title: "Updates",
            subtitle: "Keep MacParakeet up to date.",
            icon: "arrow.triangle.2.circlepath"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                            updater.automaticallyChecksForUpdates = newValue
                        }
                        .font(DesignSystem.Typography.body)
                }

                HStack {
                    Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                        .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                            updater.automaticallyDownloadsUpdates = newValue
                        }
                        .font(DesignSystem.Typography.body)
                        .disabled(!automaticallyChecksForUpdates)
                }

                Divider()

                HStack {
                    rowText(
                        title: "Manual check",
                        detail: "Check for a new version right now."
                    )
                    Spacer()
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        settingsCard(
            title: "Setup",
            subtitle: "Re-run the guided setup if something isn't working.",
            icon: "arrow.counterclockwise"
        ) {
            HStack {
                rowText(
                    title: "Run setup again",
                    detail: "Re-opens guided setup for permissions and model download."
                )
                Spacer()
                Button("Open Setup...") {
                    NotificationCenter.default.post(name: .macParakeetOpenOnboarding, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
            }
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        let identity = BuildIdentity.current
        return settingsCard(
            title: "About",
            subtitle: "Version info and diagnostics.",
            icon: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    SpinnerRingView(size: 18, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                        .opacity(0.6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet \(identity.version) (\(identity.buildNumber))")
                            .font(DesignSystem.Typography.body)
                        Text("Fast, private voice for Mac")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(copiedBuildIdentity ? "Copied" : "Copy Build Info") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildIdentityReport(identity), forType: .string)
                        copiedBuildIdentity = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedBuildIdentity = false
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                aboutRow(label: "Source", value: identity.buildSource)
                aboutRow(label: "Commit", value: identity.gitCommit)
                aboutRow(label: "Built", value: identity.buildDateUTC)
                aboutRow(label: "Executable", value: identity.executablePath)
            }
        }
    }

    // MARK: - Reusable UI

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsCardContainer(title: title, subtitle: subtitle, icon: icon, content: content)
    }

    private func settingsToggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            rowText(title: title, detail: detail)
            Spacer(minLength: DesignSystem.Spacing.md)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.body)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statChip(title: String, value: String, isHealthy: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.sectionTitle)
                .foregroundStyle(isHealthy ? .primary : DesignSystem.Colors.errorRed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    @ViewBuilder
    private func maintenanceGroup<Buttons: View>(
        label: String,
        detail: String,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(label)
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: DesignSystem.Spacing.sm) {
                buttons()
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.sectionTitle)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modelStatusRow(
        title: String,
        detail: String,
        status: SettingsViewModel.LocalModelStatus,
        isRepairing: Bool,
        onRepair: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            modelStatusPill(status)

            Button(isRepairing ? "Repairing..." : "Repair") {
                onRepair()
            }
            .buttonStyle(.bordered)
            .disabled(isRepairing)
        }
    }

    // MARK: - Dictation Mode Guide

    private var dictationModeGuide: some View {
        VStack(spacing: 0) {
            modeShortcutRow(
                keys: [viewModel.hotkeyTrigger.shortSymbol, viewModel.hotkeyTrigger.shortSymbol],
                separator: "·",
                action: "Persistent dictation",
                detail: "Tap again to stop"
            )

            Divider()
                .padding(.leading, 88)

            modeShortcutRow(
                keys: [viewModel.hotkeyTrigger.shortSymbol],
                separator: nil,
                action: "Push-to-talk",
                detail: "Release to stop"
            )
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modeShortcutRow(keys: [String], separator: String?, action: String, detail: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 3) {
                if keys.count == 2, let sep = separator {
                    miniSettingsKeyCap(keys[0])
                    Text(sep)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    miniSettingsKeyCap(keys[1])
                } else {
                    Text("Hold")
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.secondary)
                    miniSettingsKeyCap(keys[0])
                }
            }
            .frame(width: 80, alignment: .center)

            Text(action)
                .font(DesignSystem.Typography.bodySmall.weight(.medium))

            Spacer()

            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func miniSettingsKeyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignSystem.Colors.cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 0.5, x: 0, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
            )
    }

    // MARK: - Helpers

    private func aboutRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func buildIdentityReport(_ identity: BuildIdentity) -> String {
        [
            "MacParakeet Build Identity",
            "Version: \(identity.version)",
            "Build: \(identity.buildNumber)",
            "Source: \(identity.buildSource)",
            "Commit: \(identity.gitCommit)",
            "Built: \(identity.buildDateUTC)",
            "Executable: \(identity.executablePath)",
            "Bundle: \(identity.bundlePath)",
        ]
        .joined(separator: "\n")
    }

    @ViewBuilder
    private func permissionPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(granted ? "Granted" : "Not Granted")
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(granted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.errorRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(granted ? DesignSystem.Colors.successGreen.opacity(0.1) : DesignSystem.Colors.errorRed.opacity(0.1))
        )
    }

    @ViewBuilder
    private func modelStatusPill(_ status: SettingsViewModel.LocalModelStatus) -> some View {
        let (icon, text, color): (String, String, Color) = switch status {
        case .unknown:
            ("questionmark.circle.fill", "Unknown", .secondary)
        case .checking:
            ("clock.fill", "Checking", DesignSystem.Colors.warningAmber)
        case .ready:
            ("checkmark.circle.fill", "Ready", DesignSystem.Colors.successGreen)
        case .notLoaded:
            ("pause.circle.fill", "Not Loaded", .secondary)
        case .notDownloaded:
            ("arrow.down.circle.fill", "Not Downloaded", DesignSystem.Colors.errorRed)
        case .repairing:
            ("wrench.and.screwdriver.fill", "Repairing", DesignSystem.Colors.warningAmber)
        case .failed:
            ("xmark.circle.fill", "Failed", DesignSystem.Colors.errorRed)
        }

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings Card with Hover

private struct SettingsCardContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
    }
}
