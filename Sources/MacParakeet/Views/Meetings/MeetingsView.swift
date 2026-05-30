import EventKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct MeetingsView: View {
    @Bindable var viewModel: MeetingsWorkspaceViewModel

    var onRecordMeeting: () -> Void
    var onPauseToggleMeeting: (() -> Void)?
    var onOpenCalendarSettings: () -> Void
    var onOpenAISettings: () -> Void
    var onRecoverMeetings: () -> Void
    var onSelectMeeting: (Transcription) -> Void

    @State private var audioSaveErrorMessage: String?
    @State private var showingAskPromptsSheet = false
    @State private var showingPromptLibrary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                recordingSurface
                contentColumns
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.lg)
            .padding(.bottom, DesignSystem.Spacing.xl)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignSystem.Colors.contentBackground)
        .onAppear {
            viewModel.refreshIfNeeded()
        }
        .onChange(of: viewModel.settingsViewModel.calendarAutoStartMode) { _, _ in
            viewModel.refreshUpcomingEvents()
        }
        .onChange(of: viewModel.settingsViewModel.calendarPermissionStatus) { _, _ in
            viewModel.refreshUpcomingEvents()
        }
        .onChange(of: viewModel.settingsViewModel.meetingTriggerFilter) { _, _ in
            viewModel.refreshUpcomingEvents()
        }
        .onChange(of: viewModel.settingsViewModel.calendarExcludedIdentifiers) { _, _ in
            viewModel.refreshUpcomingEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            viewModel.refreshUpcomingEvents()
        }
        .alert(
            "Save Failed",
            isPresented: Binding(
                get: { audioSaveErrorMessage != nil },
                set: { if !$0 { audioSaveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                audioSaveErrorMessage = nil
            }
        } message: {
            Text(audioSaveErrorMessage ?? "Unable to save meeting audio.")
        }
        .sheet(isPresented: $showingAskPromptsSheet, onDismiss: {
            viewModel.quickPromptsViewModel.cancelCreating()
            viewModel.quickPromptsViewModel.editingPrompt = nil
            viewModel.refreshQuickPrompts()
        }) {
            AskPromptsSheet(viewModel: viewModel.quickPromptsViewModel)
        }
        .sheet(isPresented: $showingPromptLibrary, onDismiss: {
            viewModel.promptsViewModel.editingPrompt = nil
            viewModel.refreshAutoNotes()
        }) {
            PromptLibraryView(viewModel: viewModel.promptsViewModel)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meetings")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Upcoming, live, and saved.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer(minLength: DesignSystem.Spacing.lg)

            if viewModel.recordingStatus != .ready {
                // Isolated into its own View so the per-second elapsed-time
                // update (read via `formattedElapsed`) re-renders ONLY this
                // chip — not all of `MeetingsView.body`. When the elapsed read
                // lived here inline, every 1s tick re-evaluated the whole body
                // and re-laid out the entire meetings list (a `sizeThatFits`
                // storm, ~30%+ CPU while recording — the reported "laggy
                // Meetings workspace"). `recordingStatus` derives from `state`
                // only, so the gate above stays tick-stable.
                // See plans/active/2026-05-meeting-recording-cpu-debug.md.
                MeetingsLiveStatusChip(viewModel: viewModel)
            }
        }
    }

    private var recordingSurface: some View {
        MeetingRecordingTile(
            viewModel: viewModel.meetingPillViewModel,
            permissionState: meetingPermissionState,
            onTap: onRecordMeeting,
            onPauseToggle: onPauseToggleMeeting
        )
    }

    private var contentColumns: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    upcomingSection
                    recentMeetingsSection
                }
                .frame(minWidth: 480, maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    attentionSection
                    intelligenceSection
                    autoNotesSection
                    meetingPromptsSection
                }
                .frame(minWidth: 280, maxWidth: 340, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                upcomingSection
                attentionSection
                intelligenceSection
                autoNotesSection
                meetingPromptsSection
                recentMeetingsSection
            }
        }
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if AppFeatures.calendarEnabled {
            MeetingsSection(title: "Upcoming", icon: "calendar.badge.clock") {
                CalendarInlineControlsRow(
                    settingsViewModel: viewModel.settingsViewModel,
                    onOpenCalendarSettings: onOpenCalendarSettings
                )
                MeetingsHairline()

                switch viewModel.calendarStatus {
                case .unavailable:
                    unavailableCalendarState
                case .off:
                    MeetingsInlineState(
                        icon: "calendar",
                        title: "Calendar reminders are off",
                        detail: calendarOffDetail,
                        actionTitle: nil,
                        actionIcon: nil,
                        action: nil
                    )
                case .permissionNeeded:
                    // The controls row above owns the permission CTA (inline
                    // "Connect Calendar"), so this is context-only — no second
                    // button competing with a different destination.
                    MeetingsInlineState(
                        icon: "calendar.badge.exclamationmark",
                        title: "Calendar access needed",
                        detail: "Connect Calendar above to see your upcoming meetings.",
                        actionTitle: nil,
                        actionIcon: nil,
                        action: nil
                    )
                case .permissionDenied:
                    MeetingsInlineState(
                        icon: "lock.shield",
                        title: "Calendar is blocked",
                        detail: "Re-enable Calendar access in macOS Settings to see upcoming meetings.",
                        actionTitle: nil,
                        actionIcon: nil,
                        action: nil
                    )
                case .loading:
                    MeetingsLoadingRow(title: "Loading calendar")
                case .error(let message):
                    MeetingsInlineState(
                        icon: "exclamationmark.triangle",
                        title: "Calendar unavailable",
                        detail: message,
                        actionTitle: "Try Again",
                        actionIcon: "arrow.clockwise",
                        action: { viewModel.refreshUpcomingEvents() }
                    )
                case .ready(let mode):
                    if viewModel.upcomingEvents.isEmpty {
                        MeetingsInlineState(
                            icon: "calendar",
                            title: "No upcoming meetings",
                            detail: calendarEmptyDetail(for: mode),
                            actionTitle: "Refresh",
                            actionIcon: "arrow.clockwise",
                            action: { viewModel.refreshUpcomingEvents() }
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.upcomingEvents) { event in
                                CalendarEventRow(event: event)
                                if event.id != viewModel.upcomingEvents.last?.id {
                                    MeetingsHairline()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var unavailableCalendarState: some View {
        assertionFailure("calendarStatus should not be unavailable when the calendar feature is enabled.")
        return EmptyView()
    }

    @ViewBuilder
    private var attentionSection: some View {
        if !viewModel.attentionItems.isEmpty {
            MeetingsSection(title: "Needs Attention", icon: "exclamationmark.circle") {
                VStack(spacing: 0) {
                    ForEach(viewModel.attentionItems) { item in
                        AttentionRow(item: item) {
                            performAttentionAction(item.action)
                        }
                        if item.id != viewModel.attentionItems.last?.id {
                            MeetingsHairline()
                        }
                    }
                }
            }
        }
    }

    private var intelligenceSection: some View {
        MeetingsSection(title: "Intelligence", icon: "sparkles") {
            switch viewModel.intelligenceStatus {
            case .setupNeeded:
                MeetingsInlineState(
                    icon: "sparkles",
                    title: "AI not configured",
                    detail: "Summaries and meeting chat stay off until you choose a provider.",
                    actionTitle: "Set Up AI",
                    actionIcon: "gearshape",
                    action: onOpenAISettings
                )
            case .ready(let displayName, let isLocal):
                IntelligenceReadyRow(
                    displayName: displayName,
                    locality: isLocal ? "Local" : "External",
                    localityIcon: isLocal ? "lock" : "cloud",
                    detail: isLocal
                        ? "Meeting summaries and chat use \(displayName) on this Mac."
                        : nil,
                    tint: isLocal ? DesignSystem.Colors.successGreen : DesignSystem.Colors.textSecondary,
                    onOpenSettings: onOpenAISettings
                )
            case .cannotConnect(let displayName, let message):
                MeetingsInlineState(
                    icon: "exclamationmark.triangle",
                    title: "\(displayName) unavailable",
                    detail: message,
                    actionTitle: "Open AI Settings",
                    actionIcon: "gearshape",
                    action: onOpenAISettings
                )
            }
        }
    }

    @ViewBuilder
    private var autoNotesSection: some View {
        MeetingsSection(title: "After Each Meeting", icon: "wand.and.stars") {
            if viewModel.isAutoNotesConfigured {
                autoNotesContent
            } else {
                MeetingsInlineState(
                    icon: "sparkles",
                    title: "Set up AI for auto-notes",
                    detail: "Choose an AI provider and MacParakeet will write notes for you automatically when a meeting ends.",
                    actionTitle: "Set Up AI",
                    actionIcon: "gearshape",
                    action: onOpenAISettings
                )
            }
        }
    }

    private var autoNotesContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 22)

                Text("Written automatically when a meeting ends. Click a note to turn it on or off.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: DesignSystem.Spacing.sm)
            }

            if viewModel.meetingAutoNotePrompts.isEmpty {
                Text("No note types yet. Add one in Manage.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(viewModel.meetingAutoNotePrompts) { prompt in
                        let isOn = viewModel.isMeetingAutoNote(prompt)
                        AutoNoteChip(title: prompt.name, isOn: isOn) {
                            viewModel.setMeetingAutoNote(prompt, enabled: !isOn)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                if let provider = viewModel.autoNotesProviderName {
                    Label("Uses \(provider)", systemImage: "sparkles")
                        .font(DesignSystem.Typography.micro.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    showingPromptLibrary = true
                } label: {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
                .parakeetAction(.secondary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meetingPromptsSection: some View {
        MeetingsSection(title: "Meeting Prompts", icon: "text.bubble") {
            LiveAskPromptRow(
                pinnedCount: viewModel.liveAskPromptVisiblePinnedCount,
                previewPrompts: viewModel.liveAskPromptPreviewPrompts,
                onManage: {
                    showingAskPromptsSheet = true
                },
                onCreate: {
                    viewModel.quickPromptsViewModel.startCreating()
                    showingAskPromptsSheet = true
                }
            )
        }
    }

    private var recentMeetingsSection: some View {
        MeetingsSection(title: "Recent Meetings", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 0) {
                if shouldShowRecentMeetingSearch {
                    recentMeetingSearchField
                }

                if viewModel.recentMeetingsViewModel.isLoading
                    && viewModel.recentMeetingsViewModel.filteredTranscriptions.isEmpty {
                    MeetingsLoadingRow(title: "Loading meetings")
                } else if viewModel.recentMeetingsViewModel.filteredTranscriptions.isEmpty {
                    MeetingsInlineState(
                        icon: recentMeetingsEmptyIcon,
                        title: recentMeetingsEmptyTitle,
                        detail: recentMeetingsEmptyDetail,
                        actionTitle: recentMeetingsEmptyActionTitle,
                        actionIcon: recentMeetingsEmptyActionIcon,
                        action: recentMeetingsEmptyAction
                    )
                } else {
                    ForEach(viewModel.recentMeetingsViewModel.groupedTranscriptions, id: \.group) { section in
                        MeetingDateGroupHeader(group: section.group)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, transcription in
                            MeetingRowCard(
                                transcription: transcription,
                                searchText: viewModel.recentMeetingsViewModel.searchText,
                                onTap: { onSelectMeeting(transcription) },
                                menuContent: { recentMeetingMenu(for: transcription) }
                            )
                            if idx < section.items.count - 1 {
                                MeetingRowHairline()
                            }
                        }
                    }

                    if viewModel.recentMeetingsViewModel.hasMore {
                        HStack {
                            Spacer()
                            Button {
                                viewModel.recentMeetingsViewModel.loadMoreTranscriptions()
                            } label: {
                                if viewModel.recentMeetingsViewModel.isLoading {
                                    Label("Loading…", systemImage: "arrow.clockwise")
                                } else {
                                    Label("Load More", systemImage: "ellipsis")
                                }
                            }
                            .parakeetAction(.secondary)
                            .disabled(viewModel.recentMeetingsViewModel.isLoading)
                            Spacer()
                        }
                        .padding(.vertical, DesignSystem.Spacing.md)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentMeetingMenu(for transcription: Transcription) -> some View {
        Button {
            onSelectMeeting(transcription)
        } label: {
            Label("Open", systemImage: "doc.text")
        }

        let audioAvailable = MeetingAudioFile.isAvailable(for: transcription)

        Divider()

        Button {
            MeetingAudioActions.revealInFinder(transcription)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .disabled(!audioAvailable)

        Button {
            saveMeetingAudio(transcription)
        } label: {
            Label("Save Audio As…", systemImage: "square.and.arrow.down")
        }
        .disabled(!audioAvailable)
    }

    private var recentMeetingSearchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            TextField(
                "Search meetings",
                text: Binding(
                    get: { viewModel.recentMeetingsViewModel.searchText },
                    set: { viewModel.recentMeetingsViewModel.searchText = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(DesignSystem.Typography.bodySmall)

            if !viewModel.recentMeetingsViewModel.searchText.isEmpty {
                Button {
                    viewModel.recentMeetingsViewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .help("Clear search")
                .accessibilityLabel("Clear meeting search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var meetingPermissionState: MeetingRecordingTile.PermissionState {
        MeetingRecordingTile.PermissionState(
            microphoneGranted: viewModel.settingsViewModel.microphoneGranted,
            screenRecordingGranted: viewModel.settingsViewModel.screenRecordingGranted,
            sourceMode: viewModel.settingsViewModel.meetingAudioSourceMode
        )
    }


    private var recentMeetingsSearchText: String {
        viewModel.recentMeetingsViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowRecentMeetingSearch: Bool {
        !viewModel.recentMeetingsViewModel.transcriptions.isEmpty || !recentMeetingsSearchText.isEmpty
    }

    private var recentMeetingsEmptyIcon: String {
        recentMeetingsSearchText.isEmpty ? "waveform.badge.mic" : "magnifyingglass"
    }

    private var recentMeetingsEmptyTitle: String {
        recentMeetingsSearchText.isEmpty ? "No meetings recorded yet" : "No matching meetings"
    }

    private var recentMeetingsEmptyDetail: String {
        recentMeetingsSearchText.isEmpty
            ? "Use Record Meeting above to capture system audio and transcribe locally."
            : "Try different words or clear your search."
    }

    private var recentMeetingsEmptyActionTitle: String? {
        recentMeetingsSearchText.isEmpty ? nil : "Clear"
    }

    private var recentMeetingsEmptyActionIcon: String? {
        recentMeetingsSearchText.isEmpty ? nil : "xmark.circle"
    }

    private var recentMeetingsEmptyAction: (() -> Void)? {
        guard !recentMeetingsSearchText.isEmpty else { return nil }
        return {
            viewModel.recentMeetingsViewModel.searchText = ""
        }
    }

    private func calendarEmptyDetail(for mode: CalendarAutoStartMode) -> String {
        switch mode {
        case .off:
            assertionFailure("calendarEmptyDetail should not be called when calendar reminders are off.")
            return "Calendar reminders are off."
        case .notify:
            return "Calendar reminders are on."
        case .autoStart:
            return "Calendar auto-start is on."
        }
    }

    private var calendarOffDetail: String {
        switch viewModel.settingsViewModel.calendarPermissionStatus {
        case .granted:
            return "Turn on Reminders or Auto-start above to preview matching calendar events."
        case .notDetermined:
            return "Connect Calendar above to enable reminders and auto-start."
        case .denied:
            return "Re-enable Calendar access in System Settings to use reminders and auto-start."
        }
    }

    private func performAttentionAction(_ action: MeetingsWorkspaceViewModel.AttentionAction) {
        switch action {
        case .recordMeeting:
            onRecordMeeting()
        case .recoverMeetings:
            onRecoverMeetings()
        case .openCalendarSettings:
            onOpenCalendarSettings()
        case .openAISettings:
            onOpenAISettings()
        }
    }

    private func saveMeetingAudio(_ transcription: Transcription) {
        Task { @MainActor in
            do {
                let outcome = try await MeetingAudioActions.runSaveAudioPanel(for: transcription)
                switch outcome {
                case .saved:
                    SoundManager.shared.play(.transcriptionComplete)
                case .cancelled:
                    break
                case .sourceUnavailable:
                    audioSaveErrorMessage = "The meeting audio file is no longer available."
                }
            } catch {
                audioSaveErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CalendarInlineControlsRow: View {
    @Bindable var settingsViewModel: SettingsViewModel
    var onOpenCalendarSettings: () -> Void

    @State private var isRequestingPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("Calendar")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        CalendarModeBadge(mode: settingsViewModel.calendarAutoStartMode)
                    }

                    Text(calendarDetail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.sm)

                Button(action: onOpenCalendarSettings) {
                    Label("Calendar Settings", systemImage: "gearshape")
                }
                .parakeetAction(.secondary)
                .help("Open Calendar Settings")
            }

            controlsArea
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var controlsArea: some View {
        if controlsEnabled {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    calendarModePicker
                    eventFilterPicker
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    calendarModePicker
                    eventFilterPicker
                }
            }
        } else {
            connectCalendarControls
        }
    }

    @ViewBuilder
    private var connectCalendarControls: some View {
        switch settingsViewModel.calendarPermissionStatus {
        case .notDetermined:
            Button(action: connectCalendar) {
                if isRequestingPermission {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Connect Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .parakeetAction(.secondary)
            .disabled(isRequestingPermission)
            .accessibilityLabel("Connect Calendar")
        case .denied:
            Button {
                settingsViewModel.openCalendarSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .parakeetAction(.secondary)
            .help("Calendar access is blocked — re-enable it in System Settings")
        case .granted:
            EmptyView()
        }
    }

    private func connectCalendar() {
        isRequestingPermission = true
        Task {
            _ = await settingsViewModel.requestCalendarPermission()
            isRequestingPermission = false
        }
    }

    private var calendarModePicker: some View {
        Picker("Calendar behavior", selection: $settingsViewModel.calendarAutoStartMode) {
            Text("Off").tag(CalendarAutoStartMode.off)
            Text("Reminders").tag(CalendarAutoStartMode.notify)
            Text("Auto-start").tag(CalendarAutoStartMode.autoStart)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 252)
        .accessibilityLabel("Calendar behavior")
        .accessibilityValue(calendarModeTitle)
    }

    private var eventFilterPicker: some View {
        CalendarMenuPicker(label: "Events") {
            Picker("Event filter", selection: $settingsViewModel.meetingTriggerFilter) {
                Text("With video link").tag(MeetingTriggerFilter.withLink)
                Text("With participants").tag(MeetingTriggerFilter.withParticipants)
                Text("All events").tag(MeetingTriggerFilter.allEvents)
            }
            .accessibilityLabel("Event filter")
            .accessibilityValue(eventFilterTitle)
        }
    }

    private var calendarDetail: String {
        // `controlsEnabled` is `permissionStatus == .granted`, so the not-granted
        // branch only ever sees `.notDetermined` / `.denied`.
        guard controlsEnabled else {
            if settingsViewModel.calendarPermissionStatus == .denied {
                return "Calendar access is blocked. Re-enable it in System Settings to use reminders."
            }
            return "Connect your macOS Calendar to preview meetings and enable reminders."
        }

        switch settingsViewModel.calendarAutoStartMode {
        case .off:
            return "Turn on calendar matching without leaving Meetings."
        case .notify:
            return "Preview matching events and remind before they start."
        case .autoStart:
            return "Auto-start matching meetings after a cancellable countdown."
        }
    }

    private var controlsEnabled: Bool {
        settingsViewModel.calendarPermissionStatus == .granted
    }

    private var calendarModeTitle: String {
        switch settingsViewModel.calendarAutoStartMode {
        case .off:
            return "Off"
        case .notify:
            return "Reminders"
        case .autoStart:
            return "Auto-start"
        }
    }

    private var eventFilterTitle: String {
        switch settingsViewModel.meetingTriggerFilter {
        case .withLink:
            return "With video link"
        case .withParticipants:
            return "With participants"
        case .allEvents:
            return "All events"
        }
    }
}

private struct CalendarModeBadge: View {
    let mode: CalendarAutoStartMode

    var body: some View {
        Text(title)
            .font(DesignSystem.Typography.micro.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var title: String {
        switch mode {
        case .off:
            return "Off"
        case .notify:
            return "Reminders"
        case .autoStart:
            return "Auto-start"
        }
    }

    private var tint: Color {
        switch mode {
        case .off:
            return DesignSystem.Colors.textTertiary
        case .notify:
            return DesignSystem.Colors.accent
        case .autoStart:
            return DesignSystem.Colors.warningAmber
        }
    }
}

private struct CalendarMenuPicker<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(DesignSystem.Typography.micro.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .textCase(.uppercase)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(minWidth: 128, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
        )
    }
}

private struct MeetingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label(title, systemImage: icon)
                .font(DesignSystem.Typography.sectionTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .labelStyle(.titleAndIcon)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignSystem.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(DesignSystem.Colors.border.opacity(0.65), lineWidth: 0.6)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The live recording/paused status chip in the Meetings header. Owns the read
/// of `meetingPillViewModel.formattedElapsed` so the per-second elapsed tick
/// invalidates only this small chip — keeping it out of `MeetingsView.body`,
/// which would otherwise re-lay out the whole meetings list every second while
/// recording. See `plans/active/2026-05-meeting-recording-cpu-debug.md`.
private struct MeetingsLiveStatusChip: View {
    @Bindable var viewModel: MeetingsWorkspaceViewModel

    var body: some View {
        MeetingsStatusChip(icon: icon, title: title, tint: tint)
    }

    private var icon: String {
        switch viewModel.recordingStatus {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.fill"
        case .finishing, .transcribing: return "waveform"
        case .error: return "exclamationmark.triangle"
        case .ready: return "checkmark.circle"
        }
    }

    private var title: String {
        switch viewModel.recordingStatus {
        case .ready: return "Ready"
        case .recording: return "Recording \(viewModel.meetingPillViewModel.formattedElapsed)"
        case .paused: return "Paused \(viewModel.meetingPillViewModel.formattedElapsed)"
        case .finishing: return "Finishing"
        case .transcribing: return "Transcribing"
        case .error: return "Needs Attention"
        }
    }

    private var tint: Color {
        switch viewModel.recordingStatus {
        case .recording: return DesignSystem.Colors.recordingRed
        case .paused, .finishing, .transcribing: return DesignSystem.Colors.warningAmber
        case .error: return DesignSystem.Colors.errorRed
        case .ready: return DesignSystem.Colors.successGreen
        }
    }
}

private struct MeetingsStatusChip: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(DesignSystem.Typography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.11))
            )
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(0.25), lineWidth: 0.6)
            )
            .lineLimit(1)
    }
}

private struct MeetingsInlineState: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String?
    let actionIcon: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                Text(detail)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            if let actionTitle, let actionIcon, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionIcon)
                }
                .parakeetAction(.secondary)
                .fixedSize()
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MeetingsLoadingRow: View {
    let title: String

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(eventDateText)
                    Text("·")
                    Text(event.formattedTimeRange)
                    if let calendarName = event.calendarName, !calendarName.isEmpty {
                        Text("·")
                        Text(calendarName)
                    }
                    if event.attendeeCount > 0 {
                        Text("·")
                        Text(peopleCountText)
                    }
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var peopleCountText: String {
        let count = event.attendeeCount + 1
        return "\(count) \(count == 1 ? "person" : "people")"
    }

    private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var eventDateText: String {
        Self.eventDateFormatter.string(from: event.startTime)
    }
}

private struct AttentionRow: View {
    let item: MeetingsWorkspaceViewModel.AttentionItem
    var action: () -> Void

    private var tint: Color {
        item.severity == .required ? DesignSystem.Colors.errorRed : DesignSystem.Colors.warningAmber
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: item.severity == .required ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                Text(item.detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Button(action: action) {
                Label(item.actionTitle, systemImage: actionIcon)
            }
            .parakeetAction(.secondary)
            .fixedSize()
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionIcon: String {
        switch item.action {
        case .recordMeeting:
            return "record.circle"
        case .recoverMeetings:
            return "tray.and.arrow.up"
        case .openCalendarSettings, .openAISettings:
            return "gearshape"
        }
    }
}

private struct IntelligenceReadyRow: View {
    let displayName: String
    let locality: String
    let localityIcon: String
    let detail: String?
    let tint: Color
    var onOpenSettings: () -> Void

    var body: some View {
        // Button beside the badge, vertically centered — matches the other
        // Intelligence states (MeetingsInlineState). `.fixedSize()` keeps the
        // button intact; a long provider name truncates gracefully rather than
        // leaving a dead gap below it.
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                localityBadge

                if let detail {
                    Text(detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Button(action: onOpenSettings) {
                Label("AI Settings", systemImage: "gearshape")
            }
            .parakeetAction(.secondary)
            .help("Open AI Settings")
            .fixedSize()
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localityBadge: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
            Text(locality)
                .font(DesignSystem.Typography.micro.weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: localityIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct LiveAskPromptRow: View {
    let pinnedCount: Int
    let previewPrompts: [QuickPrompt]
    var onManage: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("Live Ask")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if pinnedCount > 0 {
                            Text("\(pinnedCount) pinned")
                                .font(DesignSystem.Typography.micro.weight(.semibold))
                                .foregroundStyle(DesignSystem.Colors.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.12)))
                        }
                    }

                    Text("Quick prompts available while a meeting is live.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.sm)
            }

            promptPreview

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(action: onManage) {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
                .parakeetAction(.secondary)

                Button(action: onCreate) {
                    Label("New", systemImage: "plus")
                }
                .parakeetAction(.subtle)

                Spacer(minLength: 0)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var promptPreview: some View {
        if previewPrompts.isEmpty {
            Text("No pinned prompts yet.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        } else {
            HStack(spacing: 6) {
                ForEach(previewPrompts) { prompt in
                    Text(prompt.label)
                        .font(DesignSystem.Typography.micro.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 92, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.72))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                        )
                }

                if pinnedCount > previewPrompts.count {
                    Text("+\(pinnedCount - previewPrompts.count)")
                        .font(DesignSystem.Typography.micro.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MeetingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.divider.opacity(0.7))
            .frame(height: 0.5)
            .padding(.horizontal, DesignSystem.Spacing.md)
    }
}

/// Toggle chip for a single meeting auto-note. Tapping flips whether the
/// prompt auto-runs after a meeting finishes. On = filled accent; off =
/// neutral outline.
private struct AutoNoteChip: View {
    let title: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(DesignSystem.Typography.micro.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isOn
                          ? DesignSystem.Colors.accent.opacity(0.12)
                          : DesignSystem.Colors.surfaceElevated.opacity(0.72))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isOn
                            ? DesignSystem.Colors.accent.opacity(0.4)
                            : DesignSystem.Colors.border.opacity(0.5),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) auto-note")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .help(isOn ? "Generated automatically after meetings — click to turn off" : "Click to generate this automatically after meetings")
    }
}
