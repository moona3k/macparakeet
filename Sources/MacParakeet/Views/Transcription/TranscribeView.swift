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

            RoundedRectangle(cornerRadius: DesignSystem.Layout.cornerRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(viewModel.isDragging ? Color.accentColor : .secondary)
                .frame(height: DesignSystem.Layout.dropZoneHeight)
                .overlay {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 36))
                            .foregroundStyle(viewModel.isDragging ? Color.accentColor : .secondary)
                        Text("Drop audio or video file here")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(.secondary)
                        Text("MP3, WAV, M4A, FLAC, MP4, MOV, MKV")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
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

            ProgressView()
                .controlSize(.large)

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
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.sm)

            List(viewModel.transcriptions) { transcription in
                Button {
                    viewModel.currentTranscription = transcription
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(transcription.fileName)
                            .lineLimit(1)
                        Spacer()
                        if let duration = transcription.durationMs {
                            Text(duration.formattedDuration)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        statusBadge(for: transcription.status)
                    }
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

    @ViewBuilder
    private func statusBadge(for status: Transcription.TranscriptionStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.successGreen)
                .font(.caption)
        case .processing:
            ProgressView()
                .controlSize(.mini)
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
