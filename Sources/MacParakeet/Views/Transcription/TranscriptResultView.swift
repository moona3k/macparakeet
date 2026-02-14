import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct TranscriptResultView: View {
    let transcription: Transcription
    @Bindable var viewModel: TranscriptionViewModel
    var onBack: (() -> Void)?
    var onRetranscribe: ((Transcription) -> Void)?

    private enum ContentPane: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case chat = "Chat"
        var id: String { rawValue }
    }

    @State private var backHovered = false
    @State private var copied = false
    @State private var selectedPane: ContentPane = .transcript
    @State private var showExportConfirmation = false
    @State private var lastExportedURL: URL?
    @State private var lastExportedFormat: String?
    @State private var exportErrorMessage: String?
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?

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
                        .accessibilityLabel("Back")
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

            GeometryReader { proxy in
                contentArea(availableWidth: proxy.size.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Action bar
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    copyToClipboard()
                } label: {
                    Label(
                        copied ? "Copied!" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.clipboard"
                    )
                    .foregroundStyle(copied ? DesignSystem.Colors.successGreen : .primary)
                }
                .buttonStyle(.bordered)

                Menu {
                    Section("Document") {
                        Button { exportToDownloads(format: .txt) } label: {
                            Label("Plain Text (.txt)", systemImage: "doc.text")
                        }
                        Button { exportToDownloads(format: .md) } label: {
                            Label("Markdown (.md)", systemImage: "text.document")
                        }
                    }

                    if hasTimestamps {
                        Section("Subtitles") {
                            Button { exportToDownloads(format: .srt) } label: {
                                Label("SRT (.srt)", systemImage: "captions.bubble")
                            }
                            Button { exportToDownloads(format: .vtt) } label: {
                                Label("WebVTT (.vtt)", systemImage: "captions.bubble.fill")
                            }
                        }
                    }
                } label: {
                    Label("Export", systemImage: "arrow.down.doc")
                }
                .menuStyle(.borderedButton)
                .popover(isPresented: $showExportConfirmation, arrowEdge: .top) {
                    exportConfirmationPopover
                }

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
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "Unable to export transcript.")
        }
        .onDisappear {
            copiedResetTask?.cancel()
            copiedResetTask = nil
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    @ViewBuilder
    private func contentArea(availableWidth: CGFloat) -> some View {
        if availableWidth >= 980 {
            HStack(spacing: DesignSystem.Spacing.md) {
                transcriptPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                TranscriptChatPanel(transcription: transcription, viewModel: viewModel)
                    .frame(width: max(360, min(460, availableWidth * 0.38)))
            }
            .padding(DesignSystem.Spacing.lg)
        } else {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Picker("Pane", selection: $selectedPane) {
                    ForEach(ContentPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)

                if selectedPane == .transcript {
                    transcriptPane
                } else {
                    TranscriptChatPanel(transcription: transcription, viewModel: viewModel)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var transcriptPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
                    timestampedView(words: timestamps)
                } else if let text = transcription.cleanTranscript ?? transcription.rawTranscript {
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
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.75), lineWidth: 0.5)
        )
    }

    // MARK: - Mandala Data

    private var mandalaData: MandalaData {
        if let timestamps = transcription.wordTimestamps, !timestamps.isEmpty {
            return .from(wordTimestamps: timestamps)
        }
        return .from(text: transcription.cleanTranscript ?? transcription.rawTranscript ?? transcription.fileName,
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
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SoundManager.shared.play(.copyClick)

        copiedResetTask?.cancel()
        withAnimation(DesignSystem.Animation.hoverTransition) { copied = true }
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.Animation.hoverTransition) { copied = false }
        }
    }

    private var hasTimestamps: Bool {
        guard let words = transcription.wordTimestamps else { return false }
        return !words.isEmpty
    }

    private enum ExportFormat: String {
        case txt, md, srt, vtt
    }

    // MARK: - Export Confirmation Popover

    @ViewBuilder
    private var exportConfirmationPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.successGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Exported \(lastExportedFormat?.uppercased() ?? "")")
                        .font(DesignSystem.Typography.body.bold())
                    Text(lastExportedURL?.lastPathComponent ?? "")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    dismissTask?.cancel()
                    dismissTask = nil
                    showExportConfirmation = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close export confirmation")
                .accessibilityHint("Dismisses the export confirmation popover")
            }

            if let url = lastExportedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    dismissTask?.cancel()
                    dismissTask = nil
                    showExportConfirmation = false
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(minWidth: 220)
    }

    private func exportToDownloads(format: ExportFormat) {
        let stem = sanitizedExportStem(from: transcription.fileName)
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            exportErrorMessage = "Your Downloads folder could not be found."
            SoundManager.shared.play(.errorSoft)
            return
        }
        var fileURL = downloadsURL.appendingPathComponent("\(stem).\(format.rawValue)")

        // Avoid overwriting — append (1), (2), etc.
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = downloadsURL.appendingPathComponent("\(stem) (\(counter)).\(format.rawValue)")
            counter += 1
        }

        let exportService = ExportService()
        do {
            switch format {
            case .txt: try exportService.exportToTxt(transcription: transcription, url: fileURL)
            case .md: try exportService.exportToMarkdown(transcription: transcription, url: fileURL)
            case .srt: try exportService.exportToSRT(transcription: transcription, url: fileURL)
            case .vtt: try exportService.exportToVTT(transcription: transcription, url: fileURL)
            }
        } catch {
            exportErrorMessage = error.localizedDescription
            SoundManager.shared.play(.errorSoft)
            return
        }

        exportErrorMessage = nil
        SoundManager.shared.play(.transcriptionComplete)

        // Cancel any pending auto-dismiss from a previous export
        dismissTask?.cancel()

        lastExportedURL = fileURL
        lastExportedFormat = format.rawValue
        showExportConfirmation = true

        // Auto-dismiss after 5 seconds
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.0))
            guard !Task.isCancelled else { return }
            showExportConfirmation = false
        }
    }

    private func sanitizedExportStem(from fileName: String) -> String {
        let rawStem = (fileName as NSString).deletingPathExtension
        let disallowed = CharacterSet(charactersIn: "/:\\\0")
        let parts = rawStem.components(separatedBy: disallowed)
        let normalized = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "transcript" : normalized
    }

    private func formatTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
