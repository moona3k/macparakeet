import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Tab content for one translated version of a transcript: the saved
/// translation, or the live progress of a running translation job.
struct TranscriptTranslationPane: View {
    let language: TranslationLanguage
    let transcription: Transcription
    var viewModel: TranscriptTranslationViewModel
    var onSeek: ((Int) -> Void)?
    var onExport: (TranscriptTranslation, TranscriptExportFormat) -> Void

    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var confirmingDelete = false

    private struct Row: Identifiable {
        let id: Int
        let segment: TranslatedSegment
        let speakerLabel: String?
    }

    private var saved: TranscriptTranslation? {
        viewModel.translation(for: language)
    }

    private var job: TranscriptTranslationViewModel.Job? {
        viewModel.job(for: language)
    }

    /// A running job shows its own partial output; otherwise the saved one.
    private var visibleSegments: [TranslatedSegment] {
        if let job, job.isRunning { return job.segments }
        return saved?.segments ?? job?.segments ?? []
    }

    private var rows: [Row] {
        var previousSpeaker: String?
        return visibleSegments.enumerated().map { index, segment in
            let speakerChanged = index == 0 || segment.speakerId != previousSpeaker
            previousSpeaker = segment.speakerId
            return Row(
                id: index,
                segment: segment,
                speakerLabel: speakerChanged ? speakerLabel(for: segment.speakerId) : nil
            )
        }
    }

    private func speakerLabel(for speakerId: String?) -> String? {
        guard let speakerId, let speakers = transcription.speakers, !speakers.isEmpty else { return nil }
        return speakers.first(where: { $0.id == speakerId })?.label ?? speakerId
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                toolbar

                if let job {
                    if job.isRunning {
                        progressBanner(job)
                    } else if let message = job.errorMessage {
                        errorBanner(message)
                    }
                } else if let saved, viewModel.isStale(saved) {
                    staleBanner
                }

                segmentList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.75), lineWidth: 0.5)
        )
        .confirmationDialog(
            "Delete the \(language.displayName) translation?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) { viewModel.delete(language) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original transcript is not affected. You can translate again at any time.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(language.displayName) · \(language.nativeName)")
                    .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                if let modelName = saved?.modelName, !modelName.isEmpty {
                    Text("Translated with \(modelName)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            Spacer()

            if let saved, !viewModel.isTranslating(language) {
                Button {
                    viewModel.translate(to: language)
                } label: {
                    toolbarLabel("Re-translate", systemImage: "arrow.clockwise")
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
                .disabled(!viewModel.canTranslate)

                Button {
                    TranscriptResultActions.copyText(
                        ExportService().formatPlainText(translation: saved, speakers: transcription.speakers)
                    )
                    copied = true
                    copiedResetTask?.cancel()
                    copiedResetTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        copied = false
                    }
                } label: {
                    toolbarLabel(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? DesignSystem.Colors.successGreen : .primary)
                }
                .parakeetAction(.secondary)
                .controlSize(.small)

                Menu {
                    Button("Plain Text (.txt)") { onExport(saved, .txt) }
                    if saved.hasTimedSegments {
                        Button("Subtitles (.srt)") { onExport(saved, .srt) }
                    }
                } label: {
                    toolbarLabel("Export", systemImage: "arrow.down.doc")
                }
                .menuStyle(.borderedButton)
                .tint(DesignSystem.Colors.tintNeutral)
                .controlSize(.small)
                .fixedSize()

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    toolbarLabel("Delete", systemImage: "trash")
                }
                .parakeetAction(.destructive)
                .controlSize(.small)
            }
        }
    }

    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(DesignSystem.Typography.caption)
    }

    // MARK: - Banners

    private func progressBanner(_ job: TranscriptTranslationViewModel.Job) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ProgressView(value: job.fractionCompleted)
                .frame(maxWidth: 220)
            Text("Translating… \(job.segments.count) of \(job.totalSegments) lines")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button("Cancel") { viewModel.cancel(language) }
                .parakeetAction(.secondary)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
        .background(bannerBackground)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry") {
                viewModel.cancel(language)
                viewModel.translate(to: language)
            }
            .parakeetAction(.secondary)
            .controlSize(.small)
            .disabled(!viewModel.canTranslate)
            Button("Dismiss") { viewModel.cancel(language) }
                .parakeetAction(.secondary)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
        .background(bannerBackground)
    }

    private var staleBanner: some View {
        Label(
            "The transcript changed after this translation was made. Re-translate to bring it up to date.",
            systemImage: "info.circle"
        )
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerBackground)
    }

    private var bannerBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
    }

    // MARK: - Segments

    private var segmentList: some View {
        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    if let speakerLabel = row.speakerLabel {
                        Text(speakerLabel)
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .padding(.top, row.id == 0 ? 0 : DesignSystem.Spacing.sm)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
                        if let startMs = row.segment.startMs {
                            timestampButton(startMs)
                        }
                        Text(row.segment.text)
                            .font(DesignSystem.Typography.bodyLarge)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        // Persian reads right-to-left: mirror the rows so timestamps sit on
        // the right and text aligns to the right edge.
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private func timestampButton(_ startMs: Int) -> some View {
        Button {
            onSeek?(startMs)
        } label: {
            Text(Self.timestamp(ms: startMs))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(onSeek == nil)
        .help("Play from here")
        // Timestamps stay left-to-right digits even in a mirrored row.
        .environment(\.layoutDirection, .leftToRight)
    }

    private static func timestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// Globe menu in the transcript tab bar: open an existing translation or
/// start a new one.
struct TranscriptTranslateMenu: View {
    var viewModel: TranscriptTranslationViewModel
    var onSelect: (TranslationLanguage) -> Void
    var onSetUpAI: (() -> Void)?

    var body: some View {
        Menu {
            ForEach(TranslationLanguage.allCases) { language in
                let exists =
                    viewModel.translation(for: language) != nil
                    || viewModel.job(for: language) != nil
                Button {
                    if !exists { viewModel.translate(to: language) }
                    onSelect(language)
                } label: {
                    if exists {
                        Label("\(language.displayName) · \(language.nativeName)", systemImage: "checkmark")
                    } else {
                        Text("Translate to \(language.displayName) · \(language.nativeName)")
                    }
                }
                .disabled(!exists && !viewModel.canTranslate)
            }

            if !viewModel.canTranslate {
                Divider()
                if let onSetUpAI {
                    Button("Set Up an AI Provider…", action: onSetUpAI)
                } else {
                    Text("Translation needs an AI provider (Settings → AI)")
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityLabel("Translate transcript")
        .help("Translate this transcript")
    }
}
