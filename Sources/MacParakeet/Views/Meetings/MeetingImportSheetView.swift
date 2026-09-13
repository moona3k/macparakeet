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
                        text: Binding(get: { viewModel.draft?.title ?? "" }, set: viewModel.updateTitle)
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
                            set: viewModel.updateStartedAt
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .accessibilityLabel("Meeting date and time")
                }
                if let message = viewModel.validationMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                }
                ownershipNotice
            }
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if let message = viewModel.validationMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
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
                Text("Transcript, search, and playback are ready. Your original recording was not changed.")
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

    private func chooseSource() {
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
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
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
        let minutes = durationMs / 60_000
        let seconds = durationMs / 1_000 % 60
        return "\(date) · \(minutes):\(String(format: "%02d", seconds))"
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
