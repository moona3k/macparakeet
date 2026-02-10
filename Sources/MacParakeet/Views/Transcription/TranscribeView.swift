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
            Text("Recent Transcriptions")
                .font(DesignSystem.Typography.sectionHeader)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.sm)

            List(viewModel.transcriptions) { transcription in
                Button {
                    viewModel.currentTranscription = transcription
                } label: {
                    RecentTranscriptionRow(transcription: transcription)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .frame(maxHeight: 200)
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
        HStack {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(transcription.fileName)
                .lineLimit(1)
            Spacer()
            if let duration = transcription.durationMs {
                Text(duration.formattedDuration)
                    .font(DesignSystem.Typography.duration)
                    .foregroundStyle(.tertiary)
            }
            statusBadge
        }
        .padding(.vertical, 2)
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

    @ViewBuilder
    private var statusBadge: some View {
        switch transcription.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.successGreen)
                .font(.caption)
        case .processing:
            SpinnerRingView(size: 14, revolutionDuration: 2.0, tintColor: .secondary)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.statusDenied)
                .font(.caption)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
