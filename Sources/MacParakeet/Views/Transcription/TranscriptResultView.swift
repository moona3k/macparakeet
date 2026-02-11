import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore

struct TranscriptResultView: View {
    let transcription: Transcription
    var onBack: (() -> Void)?
    var onRetranscribe: ((Transcription) -> Void)?

    @State private var showExportDialog = false
    @State private var backHovered = false
    @State private var copied = false
    @State private var exported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with sonic mandala hero
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(backHovered ? .primary : .secondary)
                                .frame(width: 28, height: 28)
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

                    Spacer()

                    // Sonic mandala — hero element
                    SonicMandalaView(
                        data: mandalaData,
                        size: 56,
                        style: .fullColor
                    )

                    Spacer()

                    // Duration badge
                    if let durationMs = transcription.durationMs {
                        Text(durationMs.formattedDuration)
                            .font(DesignSystem.Typography.duration)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }

                // Title + source URL
                VStack(spacing: 4) {
                    Text(transcription.fileName)
                        .font(DesignSystem.Typography.headline)
                        .multilineTextAlignment(.center)

                    if let sourceURL = transcription.sourceURL,
                       let url = URL(string: sourceURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.youtubeRed.opacity(0.7))
                                Text(sourceURL.count > 50 ? String(sourceURL.prefix(47)) + "..." : sourceURL)
                                    .font(DesignSystem.Typography.caption)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
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
                            .font(DesignSystem.Typography.bodyLarge)
                            .textSelection(.enabled)
                            .lineSpacing(4)
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
                Menu {
                    Button {
                        exportFile(format: .txt)
                    } label: {
                        Label("Plain Text (.txt)", systemImage: "doc.text")
                    }

                    if hasTimestamps {
                        Divider()

                        Button {
                            exportFile(format: .srt)
                        } label: {
                            Label("Subtitles (.srt)", systemImage: "captions.bubble")
                        }

                        Button {
                            exportFile(format: .vtt)
                        } label: {
                            Label("Web Subtitles (.vtt)", systemImage: "captions.bubble.fill")
                        }
                    }
                } label: {
                    Label(
                        exported ? "Exported!" : "Export",
                        systemImage: exported ? "checkmark" : "arrow.down.doc"
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(width: exported ? 110 : 85)

                Button {
                    copyToClipboard()
                } label: {
                    Label(
                        copied ? "Copied!" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.clipboard"
                    )
                }
                .buttonStyle(.bordered)

                if let onRetranscribe, let filePath = transcription.filePath,
                   FileManager.default.fileExists(atPath: filePath) {
                    Button {
                        onRetranscribe(transcription)
                    } label: {
                        Label("Retranscribe", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    // MARK: - Mandala Data

    private var mandalaData: MandalaData {
        if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
            return .from(wordTimestamps: timestamps)
        }
        return .from(text: transcription.rawTranscript ?? transcription.fileName,
                     durationMs: transcription.durationMs ?? 1000)
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
                    .font(DesignSystem.Typography.bodyLarge)
                    .textSelection(.enabled)
                    .lineSpacing(4)
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
            let endsWithPunctuation = word.word.last.map { ".!?".contains($0) } ?? false
            let hasLongGap = i + 1 < words.count && (words[i + 1].startMs - word.endMs) > 1500
            let tooLong = currentWords.count >= 40

            if isLast || (endsWithPunctuation && currentWords.count >= 3) || hasLongGap || tooLong {
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
        SoundManager.shared.play(.copyClick)

        withAnimation(DesignSystem.Animation.hoverTransition) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(DesignSystem.Animation.hoverTransition) { copied = false }
        }
    }

    private var hasTimestamps: Bool {
        guard let words = transcription.wordTimestamps else { return false }
        return !words.isEmpty
    }

    private enum ExportFormat {
        case txt, srt, vtt

        var fileExtension: String {
            switch self {
            case .txt: return "txt"
            case .srt: return "srt"
            case .vtt: return "vtt"
            }
        }

        var contentType: UTType {
            switch self {
            case .txt: return .plainText
            case .srt: return UTType(filenameExtension: "srt") ?? .plainText
            case .vtt: return UTType(filenameExtension: "vtt") ?? .plainText
            }
        }
    }

    private func exportFile(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]

        let stem = (transcription.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"

        if panel.runModal() == .OK, let url = panel.url {
            let exportService = ExportService()
            do {
                switch format {
                case .txt: try exportService.exportToTxt(transcription: transcription, url: url)
                case .srt: try exportService.exportToSRT(transcription: transcription, url: url)
                case .vtt: try exportService.exportToVTT(transcription: transcription, url: url)
                }
            } catch {
                return
            }

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
