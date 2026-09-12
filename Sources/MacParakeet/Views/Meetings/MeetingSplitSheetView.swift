import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Native "Split and transcribe" sheet (issue #895 U3). Presented for a
/// single saved meeting; the shared `MeetingSplitViewModel` it binds to is
/// app-owned, so processing started here keeps running after this sheet is
/// dismissed — see `MeetingSplitViewModel`.
struct MeetingSplitSheetView: View {
    let transcription: Transcription
    @Bindable var viewModel: MeetingSplitViewModel
    let onDismiss: () -> Void
    var onOpenRecording: (Transcription) -> Void = { _ in }
    var initialOperationId: UUID? = nil

    @State private var player = MediaPlayerViewModel()
    @State private var navigationError: String?
    @State private var isConfirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(DesignSystem.Spacing.lg)
            }
            Divider()
            actionBar
        }
        .frame(width: 600)
        .frame(minHeight: 360, maxHeight: 640)
        .task(id: transcription.id) {
            await viewModel.present(
                sourceId: initialOperationId == nil ? transcription.id : (transcription.splitProvenance?.sourceId ?? transcription.id),
                sourceTitle: initialOperationId == nil ? transcription.effectiveDisplayTitle : (transcription.splitProvenance?.sourceTitle ?? transcription.effectiveDisplayTitle),
                operationId: initialOperationId
            )
            if !isShowingProcessing { await player.load(for: transcription) }
        }
        .onDisappear { player.cleanup() }
        .confirmationDialog("Discard unfinished split?", isPresented: $isConfirmingDiscard) {
            Button("Discard unfinished split", role: .destructive) {
                guard let operation = viewModel.operation else { return }
                Task {
                    do {
                        try await viewModel.discardPreparing(operationId: operation.id)
                        onDismiss()
                    } catch {
                        navigationError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This removes only this unfinished split's temporary audio. Your original recording stays unchanged.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Split and transcribe")
                .font(DesignSystem.Typography.sectionTitle)
            Text(viewModel.activeSourceTitle.isEmpty ? transcription.effectiveDisplayTitle : viewModel.activeSourceTitle)
                .font(DesignSystem.Typography.bodyLarge)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.lg)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isShowingProcessing {
            processingView
        } else {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView("Inspecting recording…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let message):
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Label("Couldn't open this recording", systemImage: "exclamationmark.triangle")
                        .font(DesignSystem.Typography.body)
                    Text(message)
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            case .ready:
                editingForm
            }
        }
    }

    private var isShowingProcessing: Bool {
        viewModel.isProcessingActive || viewModel.operation != nil
    }

    @ViewBuilder
    private var editingForm: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if let errorMessage = viewModel.processingErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .parakeetAction(.secondary)
                .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")
                Slider(value: Binding(
                    get: { Double(player.currentTimeMs) },
                    set: { player.seek(toMs: Int($0)) }
                ), in: 0...Double(max(1, player.durationMs)))
                .accessibilityLabel("Recording playback position")
                Text("\(MeetingSplitTimecode.format(player.currentTimeMs)) / \(MeetingSplitTimecode.format(viewModel.editing?.totalDurationMs ?? player.durationMs))")
                    .monospacedDigit()
            }

            if let editing = viewModel.editing {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(Array(editing.partTitles.enumerated()), id: \.offset) { index, title in
                        partRow(index: index, title: title, editing: editing)
                        if index < editing.cutPointsMs.count {
                            boundaryRow(cutIndex: index, editing: editing)
                        }
                    }
                }

                Button {
                    viewModel.addSplit()
                } label: {
                    Label("Add split", systemImage: "plus")
                }
                .parakeetAction(.secondary)

                if let validationError = viewModel.validationError {
                    Label(validationError, systemImage: "exclamationmark.circle")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .accessibilityLabel("Error: \(validationError)")
                }

                explanationText
            }
        }
    }

    private func partRow(index: Int, title: String, editing: MeetingSplitViewModel.EditingState) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Part \(index + 1)")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 56, alignment: .leading)
            TextField(
                "Part \(index + 1) title",
                text: Binding(
                    get: {
                        guard let titles = viewModel.editing?.partTitles, titles.indices.contains(index) else { return title }
                        return titles[index]
                    },
                    set: { viewModel.updateTitle(at: index, to: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Title for part \(index + 1)")
            if editing.partTitles.count > 2 {
                Button {
                    if index < editing.cutPointsMs.count {
                        viewModel.removeCut(at: index)
                    } else {
                        viewModel.removeCut(at: index - 1)
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .parakeetAction(.subtle)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .accessibilityLabel("Remove part \(index + 1), merging it with the adjacent part")
            }
        }
    }

    private func boundaryRow(cutIndex: Int, editing: MeetingSplitViewModel.EditingState) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Split at")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 56, alignment: .leading)
            TextField("m:ss", text: Binding(
                get: { viewModel.boundaryText.indices.contains(cutIndex) ? viewModel.boundaryText[cutIndex] : "" },
                set: { viewModel.updateCutText(at: cutIndex, to: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(minWidth: 100, maxWidth: 180)
            .accessibilityLabel("Start time for part \(cutIndex + 2)")
            Spacer()
            Button("Use current position") {
                viewModel.updateCut(at: cutIndex, toMs: player.currentTimeMs)
            }
            .parakeetAction(.subtle)
            .accessibilityHint("Sets this boundary to the current playback position")
        }
    }

    private var explanationText: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("What happens next")
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
            Text(
                """
                Your original stays unchanged. Each part is saved separately, then gets a new transcript \
                and new speaker labels. Enabled summaries and other automation run afterward. \
                Processing takes time. Speaker corrections, notes, and previous results are not copied.
                """
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("The separate audio uses additional storage and keeps the original recording's retention age.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    // MARK: - Processing

    @ViewBuilder
    private var processingView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let notice = viewModel.presentationNotice {
                Text(notice).foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            if viewModel.isExternallyOwned {
                Label("Processing is unavailable or owned by another process", systemImage: "arrow.triangle.2.circlepath")
                    .font(DesignSystem.Typography.body)
            } else if let progress = viewModel.progress {
                Text("Processing part \(progress.childIndex + 1) of \(progress.childCount)")
                    .font(DesignSystem.Typography.body)
                Text(stageDescription(progress.stage))
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                ProgressView()
                    .accessibilityLabel("Processing part \(progress.childIndex + 1) of \(progress.childCount): \(stageDescription(progress.stage))")
            } else if viewModel.isProcessingActive {
                Text(viewModel.operation?.status == .committed ? "Continuing processing…" : "Saving recordings…")
                    .font(DesignSystem.Typography.body)
                ProgressView()
            }

            if let operation = viewModel.operation {
                completedSummary(operation)
            }

            if let errorMessage = viewModel.processingErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }
            if let navigationError {
                Text(navigationError).foregroundStyle(DesignSystem.Colors.errorRed)
            }
            if viewModel.operation?.status == .committed {
                Text("You can close this window while processing continues. Stopping keeps the saved recordings and completed work.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private func completedSummary(_ operation: MeetingSplitOperation) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(operation.status == .committed ? "Recordings saved" : "Recording preparation unfinished")
                .font(DesignSystem.Typography.body.weight(.semibold))
            ForEach(Array(operation.childProgress.enumerated()), id: \.element.childId) { index, childProgress in
                HStack {
                    Image(systemName: statusIcon(for: childProgress))
                        .foregroundStyle(statusColor(for: childProgress))
                    Text(operation.request.children[index].title)
                        .font(DesignSystem.Typography.bodySmall)
                    Spacer()
                    Text(childStatus(childProgress, operation: operation))
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    if operation.status == .committed {
                        Button("Open") {
                            Task { await openRecording(childProgress.childId) }
                        }
                        .parakeetAction(.secondary)
                        .disabled(!viewModel.availableChildIds.contains(childProgress.childId))
                        .accessibilityLabel("Open part \(index + 1)")
                    }
                }
            }
        }
    }

    private func statusIcon(for progress: MeetingSplitChildProgress) -> String {
        if progress.outcome == .failed { return "exclamationmark.circle" }
        return progress.stage == .automationCompleted ? "checkmark.circle.fill" : "clock"
    }

    private func childStatus(_ child: MeetingSplitChildProgress, operation: MeetingSplitOperation) -> String {
        if operation.status != .committed { return "Not yet saved" }
        if !viewModel.availableChildIds.contains(child.childId) { return "Recording unavailable" }
        if child.outcome == .failed {
            return child.stage == .transcribed || child.stage == .automationPending
                ? "Transcript saved; automation needs retry" : "Transcription needs retry"
        }
        if child.outcome == .cancelled { return "Stopped; ready to continue" }
        return stageDescription(child.stage)
    }

    private func statusColor(for progress: MeetingSplitChildProgress) -> Color {
        if progress.outcome == .failed { return DesignSystem.Colors.errorRed }
        return progress.stage == .automationCompleted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.textSecondary
    }

    private func stageDescription(_ stage: MeetingSplitChildStage) -> String {
        switch stage {
        case .pendingTranscription: return "Waiting to transcribe"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .automationPending: return "Running automation"
        case .automationCompleted: return "Done"
        }
    }

    // MARK: - Actions

    private func openRecording(_ id: UUID) async {
        do {
            guard let recording = try await viewModel.savedRecording(id: id) else {
                navigationError = "This recording is no longer in the library."
                return
            }
            player.cleanup()
            onDismiss()
            onOpenRecording(recording)
        } catch {
            navigationError = error.localizedDescription
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Close") {
                player.cleanup()
                onDismiss()
            }
            .parakeetAction(.secondary)
            .keyboardShortcut(.cancelAction)

            if viewModel.operation?.status == .preparing, !viewModel.isProcessingActive, !viewModel.isExternallyOwned {
                Button("Discard unfinished split…") { isConfirmingDiscard = true }
                    .parakeetAction(.subtle)
            }

            Spacer()

            if isShowingProcessing {
                if viewModel.isExternallyOwned {
                    Button("Refresh status") {
                        Task {
                            await viewModel.present(sourceId: viewModel.activeSourceId ?? transcription.id,
                                                    sourceTitle: viewModel.activeSourceTitle,
                                                    operationId: viewModel.operation?.id)
                        }
                    }
                    .parakeetAction(.secondary)
                } else if viewModel.isProcessingActive {
                    Button(viewModel.isStopping ? "Stopping…" : "Stop processing", role: .destructive) {
                        viewModel.stop()
                    }
                    .parakeetAction(.destructive)
                    .disabled(viewModel.isStopping)
                } else if let operation = viewModel.operation, !viewModel.isExternallyOwned,
                          operation.childProgress.contains(where: { $0.stage != .automationCompleted }) {
                    Button(operation.status == .preparing ? "Continue creation" : "Continue processing") {
                        _ = viewModel.resume(operationId: operation.id, sourceTitle: viewModel.activeSourceTitle)
                    }
                    .parakeetAction(.primaryProminent)
                }
            } else {
                Button("Split and transcribe") {
                    player.cleanup()
                    _ = viewModel.submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSubmit)
                .parakeetAction(.primaryProminent)
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

}
