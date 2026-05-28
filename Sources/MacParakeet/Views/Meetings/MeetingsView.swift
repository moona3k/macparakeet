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
                MeetingsStatusChip(
                    icon: headerStatusIcon,
                    title: headerStatusTitle,
                    tint: headerStatusTint
                )
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
                    meetingPromptsSection
                }
                .frame(minWidth: 280, maxWidth: 340, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                upcomingSection
                recentMeetingsSection
                attentionSection
                intelligenceSection
                meetingPromptsSection
            }
        }
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if AppFeatures.calendarEnabled {
            MeetingsSection(title: "Upcoming", icon: "calendar.badge.clock") {
                switch viewModel.calendarStatus {
                case .unavailable:
                    unavailableCalendarState
                case .off:
                    MeetingsInlineState(
                        icon: "calendar",
                        title: "Calendar reminders are off",
                        detail: "Open Settings to turn on meeting reminders.",
                        actionTitle: "Open Settings",
                        actionIcon: "gearshape",
                        action: onOpenCalendarSettings
                    )
                case .permissionNeeded:
                    MeetingsInlineState(
                        icon: "calendar.badge.exclamationmark",
                        title: "Calendar access needed",
                        detail: "Open Settings to connect macOS Calendar.",
                        actionTitle: "Open Settings",
                        actionIcon: "gearshape",
                        action: onOpenCalendarSettings
                    )
                case .permissionDenied:
                    MeetingsInlineState(
                        icon: "lock.shield",
                        title: "Calendar is blocked",
                        detail: "Re-enable Calendar access in macOS Settings.",
                        actionTitle: "Open Settings",
                        actionIcon: "gearshape",
                        action: onOpenCalendarSettings
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
                        : "\(displayName) may receive transcript text when you run AI actions.",
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

    private var headerStatusIcon: String {
        switch viewModel.recordingStatus {
        case .recording:
            return "record.circle.fill"
        case .paused:
            return "pause.fill"
        case .finishing, .transcribing:
            return "waveform"
        case .error:
            return "exclamationmark.triangle"
        case .ready:
            return "checkmark.circle"
        }
    }

    private var headerStatusTitle: String {
        switch viewModel.recordingStatus {
        case .ready:
            return "Ready"
        case .recording:
            return "Recording \(viewModel.meetingPillViewModel.formattedElapsed)"
        case .paused:
            return "Paused \(viewModel.meetingPillViewModel.formattedElapsed)"
        case .finishing:
            return "Finishing"
        case .transcribing:
            return "Transcribing"
        case .error:
            return "Needs Attention"
        }
    }

    private var headerStatusTint: Color {
        switch viewModel.recordingStatus {
        case .recording:
            return DesignSystem.Colors.recordingRed
        case .paused, .finishing, .transcribing:
            return DesignSystem.Colors.warningAmber
        case .error:
            return DesignSystem.Colors.errorRed
        case .ready:
            return DesignSystem.Colors.successGreen
        }
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
    let detail: String
    let tint: Color
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
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

                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .parakeetAction(.secondary)
            .help("Open AI Settings")
            .accessibilityLabel("Open AI Settings")
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
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
