import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

struct TranscribeView: View {
    @Bindable var viewModel: TranscriptionViewModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let transcription = viewModel.currentTranscription {
                    TranscriptResultView(
                        transcription: transcription,
                        onBack: { viewModel.currentTranscription = nil },
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
            .animation(DesignSystem.Animation.contentSwap, value: viewModel.isTranscribing)
            .animation(DesignSystem.Animation.contentSwap, value: viewModel.currentTranscription?.id)

            if !viewModel.transcriptions.isEmpty && viewModel.currentTranscription == nil && !viewModel.isTranscribing {
                Divider()
                recentTranscriptionsList
            }
        }
    }

    // MARK: - Drop Zone (Portal)

    private var dropZoneView: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
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

                // Error banner
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                }
            }
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    // MARK: - YouTube Card

    private var youTubeCard: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isValidURL ? "checkmark.circle.fill" : "play.rectangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(viewModel.isValidURL ? DesignSystem.Colors.successGreen : DesignSystem.Colors.accent.opacity(0.4))
                        .contentTransition(.symbolEffect(.replace))

                    TextField("Paste a YouTube link", text: $viewModel.urlInput)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.body)
                        .onSubmit {
                            if viewModel.isValidURL {
                                viewModel.transcribeURL()
                            }
                        }

                    if viewModel.urlInput.isEmpty {
                        Button {
                            if let clip = NSPasteboard.general.string(forType: .string) {
                                viewModel.urlInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Paste from clipboard")
                        .accessibilityLabel("Paste URL from clipboard")
                        .accessibilityHint("Pastes clipboard text into the YouTube link field")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(
                            viewModel.isValidURL ? DesignSystem.Colors.successGreen.opacity(0.3) : DesignSystem.Colors.border,
                            lineWidth: 0.5
                        )
                )

                Button {
                    viewModel.transcribeURL()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(viewModel.isValidURL ? DesignSystem.Colors.accent : Color.primary.opacity(0.15))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isValidURL)
                .accessibilityLabel("Start transcription")
                .accessibilityHint("Starts transcribing the YouTube link")
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(error)
                .font(DesignSystem.Typography.caption)
                .lineLimit(2)
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
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
    }

    // MARK: - Transcribing

    private var isDownloadPhase: Bool {
        viewModel.progress.localizedCaseInsensitiveContains("download")
    }

    private var transcribingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            ZStack {
                // Phase icon behind the spinner
                Image(systemName: isDownloadPhase ? "arrow.down.circle" : "waveform")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.accent.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))

                SpinnerRingView(size: 48, revolutionDuration: isDownloadPhase ? 3.5 : 2.0, tintColor: DesignSystem.Colors.accent)
            }

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text(viewModel.progress)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: viewModel.progress)

                if let fraction = viewModel.transcriptionProgress {
                    ProgressView(value: fraction)
                        .tint(DesignSystem.Colors.accent)
                        .frame(width: 200)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                } else if isDownloadPhase {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(DesignSystem.Colors.accent)
                            .frame(width: 200)
                        Text("This may take a moment for longer videos")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .padding(.horizontal, DesignSystem.Spacing.xl)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    // MARK: - Recent List

    private var recentTranscriptionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(DesignSystem.Typography.sectionHeader)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.transcriptions.count)")
                    .font(DesignSystem.Typography.duration)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.xs)

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
            .frame(maxHeight: 280)
        }
    }

    // MARK: - Helpers

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
            VStack(alignment: .leading, spacing: 3) {
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

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(relativeTime(transcription.createdAt))
                        .font(DesignSystem.Typography.timestamp)
                        .foregroundStyle(.tertiary)

                    if let bytes = transcription.fileSizeBytes {
                        Text(formatFileSize(bytes))
                            .font(DesignSystem.Typography.duration)
                            .foregroundStyle(.tertiary)
                    }

                    if let duration = transcription.durationMs {
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
            RoundedRectangle(cornerRadius: 8)
                .fill(iconColor.opacity(0.1))
            Image(systemName: isYouTube ? "play.rectangle.fill" : "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor.opacity(0.7))
        }
        .frame(width: 36, height: 36)
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
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.1)))
        case .error:
            VStack(alignment: .trailing, spacing: 2) {
                pillLabel("Failed", icon: "xmark", color: DesignSystem.Colors.errorRed)
                if let msg = transcription.errorMessage {
                    Text(msg.count > 30 ? String(msg.prefix(27)) + "..." : msg)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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
                .font(.caption2)
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
