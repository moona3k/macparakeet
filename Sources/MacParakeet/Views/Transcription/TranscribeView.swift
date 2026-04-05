import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

struct TranscribeView: View {
    @Bindable var viewModel: TranscriptionViewModel
    var chatViewModel: TranscriptChatViewModel
    @Bindable var promptResultsViewModel: PromptResultsViewModel
    @Bindable var promptsViewModel: PromptsViewModel
    @Binding var showingProgressDetail: Bool
    var onNavigateBack: (() -> Void)?
    @State private var showCancelConfirmation = false
    private enum PipelineStep: CaseIterable {
        case download
        case convert
        case transcribe

        var title: String {
            switch self {
            case .download:
                return "Fetch"
            case .convert:
                return "Normalize"
            case .transcribe:
                return "Transcribe"
            }
        }

        var icon: String {
            switch self {
            case .download:
                return "arrow.down.circle"
            case .convert:
                return "waveform.path.ecg"
            case .transcribe:
                return "waveform"
            }
        }
    }

    private enum PipelineStepState {
        case pending
        case active
        case complete
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let transcription = viewModel.currentTranscription {
                    TranscriptResultView(
                        transcription: transcription,
                        viewModel: viewModel,
                        chatViewModel: chatViewModel,
                        promptResultsViewModel: promptResultsViewModel,
                        promptsViewModel: promptsViewModel,
                        onBack: {
                            viewModel.currentTranscription = nil
                            onNavigateBack?()
                        },
                        onRetranscribe: { original in
                            viewModel.retranscribe(original)
                        }
                    )
                } else if viewModel.isTranscribing {
                    transcribingView
                } else {
                    dropZoneView
                }
            }

            // Bottom bar now rendered globally in MainWindowView
        }
        .onChange(of: viewModel.isTranscribing) { _, isTranscribing in
            if !isTranscribing {
                showingProgressDetail = false
            }
        }
    }

    // MARK: - Drop Zone (Portal)

    private var dropZoneView: some View {
        VStack(spacing: 0) {
            // Centered two-card layout
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: DesignSystem.Spacing.xl) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                        youTubeCard
                        PortalDropZone(
                            isDragging: $viewModel.isDragging,
                            onDrop: { providers in
                                viewModel.handleFileDrop(providers: providers) {
                                    SoundManager.shared.play(.fileDropped)
                                }
                            },
                            onBrowse: { openFilePicker() }
                        )
                    }
                    .padding(.horizontal, DesignSystem.Spacing.xl)

                    // Error banner
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                            .padding(.horizontal, DesignSystem.Spacing.xl)
                    }

                    // Privacy tagline
                    Text("Everything stays on your Mac.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $viewModel.isDragging) { providers in
                viewModel.handleFileDrop(providers: providers) {
                    SoundManager.shared.play(.fileDropped)
                }
            }
        }
    }

    // MARK: - YouTube Card

    private var youTubeCard: some View {
        ZStack {
            // Card background — matches PortalDropZone styling
            RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
                .cardShadow(DesignSystem.Shadows.cardRest)

            VStack(spacing: DesignSystem.Spacing.md) {
                // YouTube icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.youtubeRed.opacity(0.1))
                        .frame(width: 56, height: 56)

                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.youtubeRed.opacity(0.7))
                }

                Text("Transcribe a YouTube video")
                    .font(DesignSystem.Typography.pageTitle)

                // URL input row
                HStack(spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isValidURL ? "checkmark.circle.fill" : "link")
                            .font(.system(size: 14))
                            .foregroundStyle(viewModel.isValidURL ? DesignSystem.Colors.successGreen : .secondary)
                            .contentTransition(.symbolEffect(.replace))

                        TextField("Paste a YouTube link", text: $viewModel.urlInput)
                            .textFieldStyle(.plain)
                            .font(DesignSystem.Typography.body)
                            .onSubmit {
                                if viewModel.isValidURL {
                                    viewModel.transcribeURL()
                                }
                            }

                        Button {
                            if let clip = NSPasteboard.general.string(forType: .string) {
                                viewModel.urlInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Text("Paste")
                                .font(DesignSystem.Typography.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(DesignSystem.Colors.cardBackground)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Paste from clipboard")
                        .accessibilityLabel("Paste URL from clipboard")
                        .accessibilityHint("Pastes clipboard text into the YouTube link field")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.cardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .strokeBorder(
                                viewModel.isValidURL ? DesignSystem.Colors.successGreen.opacity(0.35) : DesignSystem.Colors.border,
                                lineWidth: 0.8
                            )
                    )

                    Button {
                        viewModel.transcribeURL()
                    } label: {
                        Label("Transcribe", systemImage: "arrow.right")
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.onAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                                    .fill(viewModel.isValidURL ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.35))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.isValidURL)
                    .accessibilityLabel("Start transcription")
                    .accessibilityHint("Starts transcribing the YouTube link")
                }
                .padding(.horizontal, DesignSystem.Spacing.md)

                Text("Downloads from YouTube, then transcribes entirely on your Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, DesignSystem.Spacing.xl)
        }
        .frame(minHeight: 220)
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                Text(truncateErrorMessage(error))
                    .font(DesignSystem.Typography.caption)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Copy full error")
                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(DesignSystem.Colors.errorRed)

            Text("Click copy icon for full error. Report persistent issues via **Feedback** in the sidebar.")
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
    }

    // MARK: - Transcribing

    private var isDownloadPhase: Bool {
        viewModel.progressPhase == .downloading
    }

    private var transcribingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        Image(systemName: phaseSymbol)
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(DesignSystem.Colors.accent.opacity(0.25))
                            .contentTransition(.symbolEffect(.replace))

                        SpinnerRingView(size: 46, revolutionDuration: isDownloadPhase ? 3.2 : 2.0, tintColor: DesignSystem.Colors.accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcription In Progress")
                            .font(DesignSystem.Typography.sectionTitle)
                        if !viewModel.transcribingFileName.isEmpty {
                            Text(viewModel.transcribingFileName)
                                .font(DesignSystem.Typography.bodySmall)
                                .foregroundStyle(.primary.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(viewModel.progressHeadline)
                            .font(DesignSystem.Typography.bodySmall)
                            .foregroundStyle(.secondary)

                        if let subline = viewModel.progressSubline {
                            Text(subline)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()
                }

                phaseTimeline

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Text(viewModel.progress.isEmpty ? "Preparing..." : viewModel.progress)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.25), value: viewModel.progress)
                        Spacer()
                        if let fraction = viewModel.transcriptionProgress {
                            Text("\(Int((fraction * 100).rounded()))%")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fraction = viewModel.transcriptionProgress {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(DesignSystem.Colors.accent)
                            .animation(.easeInOut(duration: 0.2), value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(DesignSystem.Colors.accent)
                    }
                }

                Text("Processing remains local to this Mac. You can keep working while this runs.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)

                Button("Cancel Transcription", role: .destructive) {
                    showCancelConfirmation = true
                }
                .buttonStyle(.bordered)
                .padding(.top, DesignSystem.Spacing.sm)
                .alert("Cancel Transcription?", isPresented: $showCancelConfirmation) {
                    Button("Cancel Transcription", role: .destructive) {
                        viewModel.cancelTranscription()
                    }
                    Button("Continue", role: .cancel) {}
                } message: {
                    Text("This will stop the current transcription. Any progress will be lost.")
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: 620)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(DesignSystem.Colors.cardBackground)
                    .cardShadow(DesignSystem.Shadows.cardRest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
            )
            .padding(.horizontal, DesignSystem.Spacing.lg)

            Spacer()
        }
    }

    // MARK: - Helpers

    private var phaseSymbol: String {
        switch viewModel.progressPhase {
        case .preparing:
            return "hourglass"
        case .downloading:
            return "arrow.down.circle"
        case .converting:
            return "waveform.path.ecg"
        case .transcribing:
            return "waveform"
        case .identifyingSpeakers:
            return "person.2"
        case .finalizing:
            return "checkmark.circle"
        }
    }

    private var pipelineSteps: [PipelineStep] {
        switch viewModel.sourceKind {
        case .youtubeURL:
            return [.download, .convert, .transcribe]
        case .localFile:
            return [.convert, .transcribe]
        }
    }

    private var activePipelineStep: PipelineStep? {
        switch viewModel.progressPhase {
        case .preparing:
            return nil
        case .downloading:
            return .download
        case .converting:
            return .convert
        case .transcribing, .identifyingSpeakers, .finalizing:
            return .transcribe
        }
    }

    private var phaseTimeline: some View {
        HStack(spacing: 0) {
            ForEach(Array(pipelineSteps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    phaseNode(step: step, state: pipelineStepState(for: step))
                    if index < pipelineSteps.count - 1 {
                        Capsule()
                            .fill(connectorColor(before: step))
                            .frame(width: 32, height: 2)
                    }
                }
            }
        }
    }

    private func phaseNode(step: PipelineStep, state: PipelineStepState) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(nodeFillColor(for: state))
                    .frame(width: 24, height: 24)
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.onAccent)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(nodeIconColor(for: state))
                }
            }
            Text(step.title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(state == .pending ? .tertiary : .secondary)
        }
        .frame(width: 84)
    }

    private func pipelineStepState(for step: PipelineStep) -> PipelineStepState {
        guard let activePipelineStep else {
            return .pending
        }
        guard let stepIndex = pipelineSteps.firstIndex(of: step),
              let activeIndex = pipelineSteps.firstIndex(of: activePipelineStep) else {
            return .pending
        }
        if stepIndex < activeIndex { return .complete }
        if stepIndex == activeIndex { return .active }
        return .pending
    }

    private func nodeFillColor(for state: PipelineStepState) -> Color {
        switch state {
        case .pending:
            return DesignSystem.Colors.surfaceElevated
        case .active:
            return DesignSystem.Colors.accent.opacity(0.2)
        case .complete:
            return DesignSystem.Colors.accent
        }
    }

    private func nodeIconColor(for state: PipelineStepState) -> Color {
        switch state {
        case .pending:
            return .secondary
        case .active:
            return DesignSystem.Colors.accent
        case .complete:
            return DesignSystem.Colors.onAccent
        }
    }

    private func connectorColor(before step: PipelineStep) -> Color {
        switch pipelineStepState(for: step) {
        case .complete, .active:
            return DesignSystem.Colors.accent.opacity(0.35)
        case .pending:
            return DesignSystem.Colors.border
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioFileConverter.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, let url = panel.url {
            SoundManager.shared.play(.fileDropped)
            viewModel.transcribeFile(url: url)
        }
    }
}
