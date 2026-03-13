import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Data-driven model for the export confirmation popover.
/// Using a single `Identifiable` value with `.popover(item:)` ensures
/// the popover content always has the correct URL and format — no race
/// between separate presentation and data states.
private struct ExportConfirmation: Identifiable {
    let id = UUID()
    let url: URL
    let format: String
}

struct TranscriptResultView: View {
    let transcription: Transcription
    @Bindable var viewModel: TranscriptionViewModel
    var chatViewModel: TranscriptChatViewModel
    var onBack: (() -> Void)?
    var onRetranscribe: ((Transcription) -> Void)?

    @State private var backHovered = false
    @State private var copied = false
    @State private var exportConfirmation: ExportConfirmation?
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
                        .lineLimit(3)

                    if let sourceURL = transcription.sourceURL,
                       let url = URL(string: sourceURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.youtubeRed.opacity(0.7))
                                Text(sourceURL)
                                    .font(DesignSystem.Typography.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
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

            if viewModel.llmAvailable {
                tabBar
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.sm)
            }

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
                        Button { exportToDownloads(format: .docx) } label: {
                            Label("Word Document (.docx)", systemImage: "doc.richtext")
                        }
                        Button { exportToDownloads(format: .pdf) } label: {
                            Label("PDF Document (.pdf)", systemImage: "doc.viewfinder")
                        }
                    }

                    Section("Data") {
                        Button { exportToDownloads(format: .json) } label: {
                            Label("Raw Data (.json)", systemImage: "curlybraces")
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
                .popover(item: $exportConfirmation, arrowEdge: .top) { confirmation in
                    exportConfirmationPopover(confirmation)
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
        .onAppear {
            let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
            chatViewModel.cancelStreaming()
            chatViewModel.updateTranscript(text)
        }
        .onChange(of: transcription.id) {
            let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
            chatViewModel.cancelStreaming()
            chatViewModel.updateTranscript(text)
            viewModel.selectedTab = .transcript
            viewModel.dismissSummary()
        }
    }

    @ViewBuilder
    private func contentArea(availableWidth: CGFloat) -> some View {
        Group {
            if viewModel.llmAvailable {
                switch viewModel.selectedTab {
                case .transcript:
                    transcriptPane
                case .summary:
                    summaryPane
                case .chat:
                    chatPane(viewModel: chatViewModel)
                }
            } else {
                transcriptPane
            }
        }
        .padding(DesignSystem.Spacing.lg)
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

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(TranscriptionViewModel.TranscriptTab.allCases, id: \.self) { tab in
                Button {
                    viewModel.selectedTab = tab
                    if tab == .summary { viewModel.summaryBadge = false }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue.capitalized)
                            .font(DesignSystem.Typography.bodySmall.weight(
                                viewModel.selectedTab == tab ? .semibold : .regular
                            ))

                        if tab == .summary && viewModel.summaryBadge {
                            Circle()
                                .fill(DesignSystem.Colors.accent)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(viewModel.selectedTab == tab
                                  ? DesignSystem.Colors.accent.opacity(0.12)
                                  : .clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.selectedTab == tab ? DesignSystem.Colors.accent : .secondary)
            }
            Spacer()
        }
    }

    // MARK: - Summary Pane

    private var summaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                switch viewModel.summaryState {
                case .idle:
                    Text("No summary yet.")
                        .foregroundStyle(.secondary)
                        .font(DesignSystem.Typography.body)
                case .streaming:
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(viewModel.summary)
                            .font(DesignSystem.Typography.bodyLarge)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                        PulsingCursor()
                    }
                case .complete:
                    Text(viewModel.summary)
                        .font(DesignSystem.Typography.bodyLarge)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                case .error(let message):
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignSystem.Colors.errorRed)
                            Text(message)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.errorRed)
                        }
                        Button("Retry") {
                            let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
                            viewModel.generateSummary(text: text)
                        }
                        .buttonStyle(.bordered)
                    }
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

    // MARK: - Chat Pane

    @ViewBuilder
    private func chatPane(viewModel chatVM: TranscriptChatViewModel) -> some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        if chatVM.messages.isEmpty {
                            Text("Ask a question about this transcript.")
                                .foregroundStyle(.secondary)
                                .font(DesignSystem.Typography.body)
                                .padding(DesignSystem.Spacing.lg)
                        }

                        ForEach(chatVM.messages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }

                        if let error = chatVM.errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(DesignSystem.Colors.errorRed)
                                Text(error)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.errorRed)
                            }
                            .padding(.horizontal, DesignSystem.Spacing.md)
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                }
                .onChange(of: chatVM.messages.count) {
                    if let lastID = chatVM.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.75), lineWidth: 0.5)
            )

            // Input bar
            HStack(spacing: DesignSystem.Spacing.sm) {
                TextField("Ask about this transcript...", text: Bindable(chatVM).inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { chatVM.sendMessage() }
                    .disabled(chatVM.isStreaming)

                if chatVM.isStreaming {
                    Button {
                        chatVM.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                } else {
                    Button {
                        chatVM.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .disabled(chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !chatVM.messages.isEmpty {
                    Button {
                        chatVM.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, DesignSystem.Spacing.sm)
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatDisplayMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(message.content)
                        .font(DesignSystem.Typography.body)
                        .textSelection(.enabled)
                    if message.isStreaming {
                        PulsingCursor()
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(message.role == .user
                          ? DesignSystem.Colors.accent.opacity(0.12)
                          : DesignSystem.Colors.surfaceElevated)
            )

            if message.role == .assistant { Spacer(minLength: 60) }
        }
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
        case txt, md, srt, vtt, docx, pdf, json
    }

    // MARK: - Export Confirmation Popover

    @ViewBuilder
    private func exportConfirmationPopover(_ confirmation: ExportConfirmation) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.successGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Exported \(confirmation.format.uppercased())")
                        .font(DesignSystem.Typography.body.bold())
                    Text(confirmation.url.lastPathComponent)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    dismissTask?.cancel()
                    dismissTask = nil
                    exportConfirmation = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close export confirmation")
                .accessibilityHint("Dismisses the export confirmation popover")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([confirmation.url])
                dismissTask?.cancel()
                dismissTask = nil
                exportConfirmation = nil
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(DesignSystem.Typography.caption)
            }
            .buttonStyle(.bordered)
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
            case .docx: try exportService.exportToDocx(transcription: transcription, url: fileURL)
            case .pdf: try exportService.exportToPDF(transcription: transcription, url: fileURL)
            case .json: try exportService.exportToJSON(transcription: transcription, url: fileURL)
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

        // Single atomic state drives the popover via .popover(item:),
        // so presentation and data are never out of sync.
        exportConfirmation = ExportConfirmation(url: fileURL, format: format.rawValue)

        // Auto-dismiss after 5 seconds
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.0))
            guard !Task.isCancelled else { return }
            exportConfirmation = nil
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
