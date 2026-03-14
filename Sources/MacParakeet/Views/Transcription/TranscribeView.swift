import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

/// Extract a short, meaningful summary from a potentially long error message.
/// For dyld/library errors shows "Library loading failed", for other errors
/// takes the first line, truncated to fit the status pill.
private func truncateErrorMessage(_ msg: String) -> String {
    if msg.contains("dyld") || msg.contains("Library not loaded") {
        return "Library loading failed"
    }
    let firstLine = msg.prefix(while: { $0 != "\n" })
    if firstLine.count > 40 {
        return String(firstLine.prefix(37)) + "..."
    }
    return String(firstLine)
}

struct TranscribeView: View {
    @Bindable var viewModel: TranscriptionViewModel
    var chatViewModel: TranscriptChatViewModel
    @Binding var showingProgressDetail: Bool
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
                        onBack: { viewModel.currentTranscription = nil },
                        onRetranscribe: { original in
                            viewModel.retranscribe(original)
                        }
                    )
                } else if showingProgressDetail && viewModel.isTranscribing {
                    transcribingView
                } else {
                    dropZoneView
                }
            }
            .animation(DesignSystem.Animation.contentSwap, value: viewModel.isTranscribing)
            .animation(DesignSystem.Animation.contentSwap, value: viewModel.currentTranscription?.id)
            .animation(DesignSystem.Animation.contentSwap, value: showingProgressDetail)

            if !viewModel.transcriptions.isEmpty && viewModel.currentTranscription == nil && !showingProgressDetail {
                Divider()
                recentTranscriptionsList
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
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
                if viewModel.isTranscribing {
                    activeTranscriptionCard
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.top, DesignSystem.Spacing.lg)
                }

                if !viewModel.isTranscribing {
                    // Portal drop zone — the hero
                    PortalDropZone(
                        isDragging: $viewModel.isDragging,
                        onDrop: { providers in
                            viewModel.handleFileDrop(providers: providers) {
                                SoundManager.shared.play(.fileDropped)
                            }
                        },
                        onBrowse: { openFilePicker() }
                    )
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.lg)

                    // YouTube URL card — separate warm card below
                    youTubeCard
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                }

                // Error banner
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                }
            }
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    private var activeTranscriptionCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("Active Transcription")
                    .font(DesignSystem.Typography.sectionTitle)

                statusCapsule(
                    title: "On-device",
                    systemImage: "bolt.badge.a.fill",
                    tint: DesignSystem.Colors.successGreen
                )

                Spacer()
            }

            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                        .frame(width: 52, height: 52)

                    Image(systemName: phaseSymbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.transcribingFileName.isEmpty ? "Preparing transcription..." : viewModel.transcribingFileName)
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(viewModel.progressHeadline)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)

                    Text(viewModel.progress.isEmpty ? "Preparing..." : viewModel.progress)
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                VStack(alignment: .trailing, spacing: 8) {
                    if let fraction = viewModel.transcriptionProgress {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(DesignSystem.Typography.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Button("View Details") {
                        showingProgressDetail = true
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let fraction = viewModel.transcriptionProgress {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(DesignSystem.Colors.accent)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(DesignSystem.Colors.accent)
                }

                Text("Safe to browse elsewhere — this keeps running in the background.")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - YouTube Card

    private var youTubeCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("YouTube Transcription")
                    .font(DesignSystem.Typography.sectionTitle)
                Text("On-device")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.14)))
                Spacer()
            }

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
                                    .fill(DesignSystem.Colors.surfaceElevated)
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
                        .fill(DesignSystem.Colors.background)
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

            Text("Downloads from YouTube, then transcribes entirely on your Mac.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.5)
        )
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
                    .help(error)
                Spacer()
                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(DesignSystem.Colors.errorRed)

            Text("Hover for details. Report persistent issues via **Feedback** in the sidebar.")
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
            HStack {
                Button {
                    showingProgressDetail = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(DesignSystem.Typography.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)
                Spacer()
            }

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
                    viewModel.cancelTranscription()
                }
                .buttonStyle(.bordered)
                .padding(.top, DesignSystem.Spacing.sm)
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

    // MARK: - Recent List

    private var recentTranscriptionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Transcriptions")
                    .font(DesignSystem.Typography.sectionHeader)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.transcriptions.count)")
                    .font(DesignSystem.Typography.duration)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                Spacer()
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)

            List(viewModel.transcriptions) { transcription in
                Button {
                    viewModel.currentTranscription = transcription
                } label: {
                    RecentTranscriptionRow(transcription: transcription)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .frame(maxHeight: 320)
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

    private func statusCapsule(title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
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

// MARK: - Recent Transcription Row

private struct RecentTranscriptionRow: View {
    let transcription: Transcription
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Contextual icon thumbnail
            transcriptionIcon

            // Content: filename + metadata
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(DesignSystem.Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if transcription.sourceURL != nil {
                        Text("YouTube")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.youtubeRed.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DesignSystem.Colors.youtubeRed.opacity(0.08))
                            )
                    }
                }

                HStack(spacing: 0) {
                    Text(relativeTime(transcription.createdAt))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)

                    if let bytes = transcription.fileSizeBytes {
                        metadataDot
                        Text(formatFileSize(bytes))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let duration = transcription.durationMs {
                        metadataDot
                        Text(duration.formattedDuration)
                            .font(DesignSystem.Typography.duration)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Status pill
            statusPill
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(isHovered ? DesignSystem.Colors.rowHoverBackground : .clear)
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
    }

    private var metadataDot: some View {
        Text("\u{2009}\u{00B7}\u{2009}")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(.quaternary)
    }

    // MARK: - Display Name

    private var displayName: String {
        let name = transcription.fileName
        // If filename looks like a UUID (with or without extension), show transcript preview instead
        let stem = (name as NSString).deletingPathExtension
        if UUID(uuidString: stem) != nil, let text = transcription.rawTranscript, !text.isEmpty {
            let preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
            return preview
        }
        return name
    }

    // MARK: - Icon Thumbnail

    private var isYouTube: Bool { transcription.sourceURL != nil }

    @ViewBuilder
    private var transcriptionIcon: some View {
        let iconColor = isYouTube ? DesignSystem.Colors.youtubeRed : DesignSystem.Colors.accent
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(iconColor.opacity(0.1))
            Image(systemName: isYouTube ? "play.rectangle.fill" : "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor.opacity(0.7))
        }
        .frame(width: 40, height: 40)
    }

    // MARK: - Status Pill

    @ViewBuilder
    private var statusPill: some View {
        switch transcription.status {
        case .completed:
            pillLabel("Done", icon: "checkmark", color: DesignSystem.Colors.successGreen)
        case .processing:
            HStack(spacing: 4) {
                SpinnerRingView(size: 10, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)
                Text("Processing")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.1)))
        case .error:
            VStack(alignment: .trailing, spacing: 2) {
                pillLabel("Failed", icon: "xmark", color: DesignSystem.Colors.errorRed)
                if let msg = transcription.errorMessage {
                    Text(truncateErrorMessage(msg))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(msg)
                }
            }
        case .cancelled:
            pillLabel("Cancelled", icon: "minus", color: .secondary)
        }
    }

    private func pillLabel(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.1)))
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
