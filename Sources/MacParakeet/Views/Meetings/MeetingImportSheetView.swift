import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import UniformTypeIdentifiers

/// A compact native utility sheet for adding one existing recording. The
/// app-owned view model keeps processing after this view has been dismissed.
struct MeetingImportSheetView: View {
    @Bindable var viewModel: MeetingImportViewModel
    let onDismiss: () -> Void
    let onOpenMeeting: (Transcription) -> Void

    @FocusState private var titleFocused: Bool
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityFocusTarget?
    @State private var announcedProgressStage: MeetingImportViewModel.Stage?
    @State private var announcedTerminal: TerminalAnnouncement?
    @State private var announcedValidationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(DesignSystem.Spacing.lg)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 360, maxHeight: 640)
        .background(DesignSystem.Colors.background)
        .onAppear {
            if viewModel.draft != nil, !viewModel.isProcessing, viewModel.terminalResult == nil {
                titleFocused = true
            }
            if let validationMessage = viewModel.validationMessage {
                announceValidationIfNeeded(validationMessage)
            }
            if let stage = viewModel.stage, viewModel.isProcessing {
                announceProgressStageIfNeeded(stage)
            }
            announceTerminalIfNeeded()
        }
        .onChange(of: viewModel.validationMessage) { _, validationMessage in
            guard let validationMessage else {
                announcedValidationMessage = nil
                return
            }
            announceValidationIfNeeded(validationMessage)
        }
        .onChange(of: viewModel.stage) { _, stage in
            guard let stage, viewModel.isProcessing else {
                announcedProgressStage = nil
                return
            }
            announceProgressStageIfNeeded(stage)
        }
        .onChange(of: viewModel.isProcessing) { _, isProcessing in
            guard !isProcessing else { return }
            announcedProgressStage = nil
            announceTerminalIfNeeded()
        }
        .onChange(of: terminalAnnouncement) { _, terminalAnnouncement in
            guard terminalAnnouncement != nil else {
                announcedTerminal = nil
                return
            }
            announceTerminalIfNeeded()
        }
        .onExitCommand(perform: dismissSheet)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Import recording")
                .font(DesignSystem.Typography.pageTitle)
            Text(headerSubtitle)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.lg)
    }

    private var headerSubtitle: String {
        if let draft = viewModel.draft { return draft.sourceURL.lastPathComponent }
        return "Create a searchable meeting from an existing recording."
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isProcessing {
            progressContent
        } else if let terminal = viewModel.terminalResult {
            terminalContent(terminal)
        } else {
            formContent
        }
    }

    @ViewBuilder
    private var formContent: some View {
        if let draft = viewModel.draft {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                formRow("Recording") {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "waveform")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(draft.sourceURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Choose Another…", action: chooseSource)
                            .parakeetAction(.secondary)
                            .controlSize(.small)
                    }
                }
                formRow("Meeting title") {
                    TextField(
                        "Meeting title",
                        text: Binding(
                            get: { viewModel.draft?.title ?? "" },
                            set: { viewModel.updateTitle($0) }
                        )
                    )
                    .focused($titleFocused)
                    .accessibilityLabel("Meeting title")
                    .onSubmit { _ = viewModel.startImport() }
                }
                formRow("Date and time") {
                    DatePicker(
                        "Meeting date and time",
                        selection: Binding(
                            get: { viewModel.draft?.startedAt ?? Date() },
                            set: { viewModel.updateStartedAt($0) }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .accessibilityLabel("Meeting date and time")
                }
                if let message = viewModel.validationMessage {
                    validationLabel(message, systemImage: "exclamationmark.circle")
                }
                ownershipNotice
            }
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if let message = viewModel.validationMessage {
                    validationLabel(message, systemImage: "exclamationmark.triangle")
                }
                Text("Choose one audio or video file to add as a meeting.")
                    .font(DesignSystem.Typography.body)
                Button("Choose Recording…", action: chooseSource)
                    .parakeetAction(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        }
    }

    private var ownershipNotice: some View {
        Label {
            Text(
                "MacParakeet makes its own audio copy. Your original stays where it is and won’t be changed. The new copy follows your meeting-audio retention setting today."
            )
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(DesignSystem.Typography.bodySmall)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ParakeetSpinner(.inline, tint: DesignSystem.Colors.textSecondary)
                Text(viewModel.stage?.message ?? "Preparing audio")
                    .font(DesignSystem.Typography.body)
            }
            Text(progressDescription)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if viewModel.hasPublishedMeeting {
                Label(
                    "Meeting saved. You can close this sheet while processing continues.",
                    systemImage: "checkmark.circle"
                )
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.successGreen)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var progressDescription: String {
        switch viewModel.stage {
        case .preparing: "Making a private managed copy of the recording."
        case .published: "The meeting is available while its transcript is prepared."
        case .transcribing: "Creating a searchable, speaker-aware transcript."
        case .finishing: "Saving speakers, search, and meeting files."
        case .automating: "Saving enabled meeting notes and related details."
        case nil: "Preparing the recording."
        }
    }

    private func terminalContent(_ terminal: MeetingImportViewModel.TerminalResult) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label(terminalTitle(for: terminal), systemImage: terminalIcon(for: terminal))
                .font(DesignSystem.Typography.sectionTitle)
                .foregroundStyle(terminalColor(for: terminal))
                .accessibilityAddTraits(.isHeader)
            if let errorMessage = terminal.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            if let transcription = terminal.transcription {
                Text(transcription.effectiveDisplayTitle)
                    .font(DesignSystem.Typography.bodyLarge)
                Text(meetingMetadata(for: transcription))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            if terminal.outcome == .completed || terminal.outcome == .partial {
                Text(completionAvailabilityMessage(for: terminal))
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            ForEach(Array(terminal.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            if terminal.outcome == .partial {
                Text("The meeting is saved. Importing the same file again would create another meeting.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else if terminal.outcome == .needsRetry {
                Text(
                    "The meeting and its audio are saved. Open it and choose Retry Transcription; don’t import the file again."
                )
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityFocused($accessibilityFocus, equals: .terminalSummary)
    }

    private var footer: some View {
        HStack {
            if viewModel.isProcessing {
                Button("Close", action: onDismiss)
                    .parakeetAction(.secondary)
                Spacer()
                Button(viewModel.isStopping ? "Stopping…" : "Stop", role: .destructive) {
                    viewModel.stop()
                }
                .parakeetAction(.destructive)
                .disabled(viewModel.isStopping)
            } else if let terminal = viewModel.terminalResult {
                Button("Dismiss") {
                    viewModel.acknowledgeResult()
                    onDismiss()
                }
                .parakeetAction(.secondary)
                Spacer()
                if let transcription = terminal.transcription {
                    Button("Import Another…") {
                        viewModel.acknowledgeResult()
                        chooseSource()
                    }
                    .parakeetAction(.secondary)
                    Button("Open Meeting") {
                        viewModel.acknowledgeResult()
                        onOpenMeeting(transcription)
                        onDismiss()
                    }
                    .parakeetAction(.primary)
                } else {
                    Button("Import Another…") {
                        viewModel.acknowledgeResult()
                        chooseSource()
                    }
                    .parakeetAction(.primary)
                }
            } else {
                Button("Cancel", action: onDismiss)
                    .parakeetAction(.secondary)
                Spacer()
                Button("Import") { _ = viewModel.startImport() }
                    .parakeetAction(.primary)
                    .disabled(!viewModel.canImport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
            Text(label)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 104, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum AccessibilityFocusTarget: Hashable {
        case validation
        case terminalSummary
    }

    private struct TerminalAnnouncement: Equatable {
        let transcriptionID: UUID?
        let outcome: MeetingImportViewModel.Outcome
    }

    private var terminalAnnouncement: TerminalAnnouncement? {
        guard let terminal = viewModel.terminalResult else { return nil }
        return TerminalAnnouncement(
            transcriptionID: terminal.transcription?.id,
            outcome: terminal.outcome
        )
    }

    private func validationLabel(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(DesignSystem.Typography.bodySmall)
            .foregroundStyle(DesignSystem.Colors.errorRed)
            .accessibilityFocused($accessibilityFocus, equals: .validation)
    }

    private func announceValidationIfNeeded(_ message: String) {
        guard announcedValidationMessage != message else { return }
        announcedValidationMessage = message
        scheduleAccessibilityUpdate {
            guard viewModel.validationMessage == message else { return }
            accessibilityFocus = .validation
            postAccessibilityAnnouncement(message)
        }
    }

    private func announceProgressStageIfNeeded(_ stage: MeetingImportViewModel.Stage) {
        guard announcedProgressStage != stage else { return }
        announcedProgressStage = stage
        postAccessibilityAnnouncement("Import progress: \(stage.message)")
    }

    private func announceTerminalIfNeeded() {
        guard !viewModel.isProcessing,
            let terminalAnnouncement,
            announcedTerminal != terminalAnnouncement,
            let terminal = viewModel.terminalResult
        else { return }
        announcedTerminal = terminalAnnouncement
        scheduleAccessibilityUpdate {
            guard self.terminalAnnouncement == terminalAnnouncement else { return }
            accessibilityFocus = .terminalSummary
            postAccessibilityAnnouncement(terminalTitle(for: terminal))
        }
    }

    private func scheduleAccessibilityUpdate(_ update: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            await Task.yield()
            update()
        }
    }

    private func postAccessibilityAnnouncement(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high,
            ]
        )
    }

    private func chooseSource() {
        guard let sourceURL = MeetingImportSourcePicker.chooseURL() else { return }
        _ = viewModel.select(sourceURL: sourceURL)
        if viewModel.draft != nil { titleFocused = true }
    }

    private func dismissSheet() {
        if !viewModel.isProcessing, viewModel.terminalResult != nil {
            viewModel.acknowledgeResult()
        }
        onDismiss()
    }

    private func meetingMetadata(for transcription: Transcription) -> String {
        let date = transcription.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let durationMs = transcription.durationMs else { return date }
        let totalSeconds = durationMs / 1_000
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds / 60 % 60
        let seconds = totalSeconds % 60
        let duration =
            hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return "\(date) · \(duration)"
    }

    private func completionAvailabilityMessage(for terminal: MeetingImportViewModel.TerminalResult) -> String {
        if terminal.transcription?.filePath == nil {
            return
                "Transcript and search are ready. Managed audio was removed by your meeting-audio retention setting. Your original recording was not changed."
        }
        return "Transcript, search, and playback are ready. Your original recording was not changed."
    }

    private func terminalTitle(for terminal: MeetingImportViewModel.TerminalResult) -> String {
        switch terminal.outcome {
        case .completed: "Meeting ready"
        case .partial: "Meeting ready with warnings"
        case .needsRetry: "Transcription needs another try"
        case .failed: "Couldn’t import recording"
        }
    }

    private func terminalIcon(for terminal: MeetingImportViewModel.TerminalResult) -> String {
        switch terminal.outcome {
        case .completed: "checkmark.circle"
        case .partial, .needsRetry: "exclamationmark.triangle"
        case .failed: "xmark.circle"
        }
    }

    private func terminalColor(for terminal: MeetingImportViewModel.TerminalResult) -> Color {
        switch terminal.outcome {
        case .completed: DesignSystem.Colors.successGreen
        case .partial, .needsRetry: DesignSystem.Colors.warningAmber
        case .failed: DesignSystem.Colors.errorRed
        }
    }
}

enum MeetingImportSourcePicker {
    @MainActor
    static func chooseURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Recording"
        panel.message = "Choose one audio or video file to add as a meeting."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AudioFileConverter.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
