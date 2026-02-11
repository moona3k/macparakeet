import SwiftUI
import MacParakeetCore

struct TranscriptResultView: View {
    let transcription: Transcription
    var onBack: (() -> Void)?

    @State private var showExportDialog = false
    @State private var backHovered = false
    @State private var copied = false
    @State private var exported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: DesignSystem.Spacing.sm) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(backHovered ? .primary : .secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(backHovered ? Color.primary.opacity(0.08) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(DesignSystem.Animation.hoverTransition) {
                            backHovered = hovering
                        }
                    }
                }

                Text(transcription.fileName)
                    .font(DesignSystem.Typography.headline)

                Spacer()

                if let durationMs = transcription.durationMs {
                    Text(durationMs.formattedDuration)
                        .font(DesignSystem.Typography.duration)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.05))
                        )
                }
            }
            .padding(DesignSystem.Spacing.lg)

            SacredGeometryDivider()
                .padding(.horizontal, DesignSystem.Spacing.lg)

            // Transcript with timestamps
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
                        timestampedView(words: timestamps)
                    } else if let text = transcription.rawTranscript {
                        Text(text)
                            .font(DesignSystem.Typography.body)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    } else {
                        Text("No transcript available")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider()

            // Export bar
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    exportTxt()
                } label: {
                    Label(
                        exported ? "Exported!" : "Export .txt",
                        systemImage: exported ? "checkmark" : "arrow.down.doc"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    copyToClipboard()
                } label: {
                    Label(
                        copied ? "Copied!" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.clipboard"
                    )
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    // MARK: - Timestamped View

    @ViewBuilder
    private func timestampedView(words: [WordTimestamp]) -> some View {
        let segments = groupIntoSegments(words: words)
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Text("[\(formatTimestamp(ms: segment.startMs))]")
                    .font(DesignSystem.Typography.timestamp)
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.03))
                    )

                Text(segment.text)
                    .font(DesignSystem.Typography.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
    }

    private struct Segment {
        let startMs: Int
        let text: String
    }

    private func groupIntoSegments(words: [WordTimestamp]) -> [Segment] {
        guard !words.isEmpty else { return [] }

        var segments: [Segment] = []
        var currentWords: [String] = []
        var segmentStart = words[0].startMs

        for (i, word) in words.enumerated() {
            currentWords.append(word.word)

            let isLast = i == words.count - 1
            let hasGap = i + 1 < words.count && (words[i + 1].startMs - word.endMs) > 500
            let tooLong = currentWords.count >= 15

            if isLast || hasGap || tooLong {
                segments.append(Segment(
                    startMs: segmentStart,
                    text: currentWords.joined(separator: " ")
                ))
                currentWords = []
                if !isLast {
                    segmentStart = words[i + 1].startMs
                }
            }
        }

        return segments
    }

    // MARK: - Actions

    private func copyToClipboard() {
        let text = transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation(DesignSystem.Animation.hoverTransition) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(DesignSystem.Animation.hoverTransition) { copied = false }
        }
    }

    private func exportTxt() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = transcription.fileName
            .replacingOccurrences(of: ".\(URL(fileURLWithPath: transcription.fileName).pathExtension)", with: ".txt")

        if panel.runModal() == .OK, let url = panel.url {
            let exportService = ExportService()
            try? exportService.exportToTxt(transcription: transcription, url: url)

            withAnimation(DesignSystem.Animation.hoverTransition) { exported = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(DesignSystem.Animation.hoverTransition) { exported = false }
            }
        }
    }

    private func formatTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
