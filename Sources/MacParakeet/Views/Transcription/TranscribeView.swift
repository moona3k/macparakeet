import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

struct TranscribeView: View {
    @Bindable var viewModel: TranscriptionViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let transcription = viewModel.currentTranscription {
                TranscriptResultView(
                    transcription: transcription,
                    onBack: { viewModel.currentTranscription = nil }
                )
            } else if viewModel.isTranscribing {
                transcribingView
            } else {
                dropZoneView
            }

            if !viewModel.transcriptions.isEmpty && viewModel.currentTranscription == nil && !viewModel.isTranscribing {
                Divider()
                recentTranscriptionsList
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            // Premium drop zone with double-border treatment
            ZStack {
                // Outer thin solid border
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cornerRadius + 2)
                    .strokeBorder(
                        viewModel.isDragging ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06),
                        lineWidth: 0.5
                    )
                    .padding(-4)

                // Inner dashed border
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cornerRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                    .foregroundStyle(viewModel.isDragging ? Color.accentColor : Color.primary.opacity(0.15))

                // Accent glow on drag-over
                if viewModel.isDragging {
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.cornerRadius)
                        .fill(Color.accentColor.opacity(0.04))
                }

                VStack(spacing: DesignSystem.Spacing.md) {
                    MeditativeMerkabaView(
                        size: 48,
                        revolutionDuration: viewModel.isDragging ? 2.0 : 6.0,
                        tintColor: viewModel.isDragging ? .accentColor : nil
                    )
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isDragging)

                    Text("Drop audio or video file here")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(viewModel.isDragging ? Color.accentColor : .secondary)

                    Text("MP3, WAV, M4A, FLAC, MP4, MOV, MKV")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: DesignSystem.Layout.dropZoneHeight)
            .onDrop(of: [.fileURL], isTargeted: $viewModel.isDragging) { providers in
                viewModel.handleFileDrop(providers: providers)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)

            Button("Browse Files") {
                openFilePicker()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(DesignSystem.Spacing.xl)
    }

    // MARK: - Transcribing

    private var transcribingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            SpinnerRingView(size: 40, revolutionDuration: 2.5, tintColor: .accentColor)

            Text(viewModel.progress)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

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
            .frame(maxHeight: 260)
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
            // Audio icon with status tint
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconBackgroundColor)
                    .frame(width: 32, height: 32)
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(iconForegroundColor)
            }

            // Content: filename + metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(transcription.fileName)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

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
        .padding(.vertical, DesignSystem.Spacing.xs)
        .padding(.horizontal, DesignSystem.Spacing.xs)
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

    // MARK: - Icon

    private var iconName: String {
        switch transcription.status {
        case .completed: return "waveform"
        case .processing: return "arrow.trianglehead.2.clockwise"
        case .error: return "exclamationmark.triangle"
        case .cancelled: return "xmark"
        }
    }

    private var iconBackgroundColor: Color {
        switch transcription.status {
        case .completed: return DesignSystem.Colors.successGreen.opacity(0.1)
        case .processing: return Color.accentColor.opacity(0.1)
        case .error: return DesignSystem.Colors.statusDenied.opacity(0.1)
        case .cancelled: return Color.primary.opacity(0.05)
        }
    }

    private var iconForegroundColor: Color {
        switch transcription.status {
        case .completed: return DesignSystem.Colors.successGreen
        case .processing: return .accentColor
        case .error: return DesignSystem.Colors.statusDenied
        case .cancelled: return .secondary
        }
    }

    // MARK: - Status Pill

    @ViewBuilder
    private var statusPill: some View {
        switch transcription.status {
        case .completed:
            pillLabel("Done", icon: "checkmark", color: DesignSystem.Colors.successGreen)
        case .processing:
            HStack(spacing: 4) {
                SpinnerRingView(size: 10, revolutionDuration: 2.0, tintColor: .accentColor)
                Text("Processing")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
        case .error:
            VStack(alignment: .trailing, spacing: 2) {
                pillLabel("Failed", icon: "xmark", color: DesignSystem.Colors.statusDenied)
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
