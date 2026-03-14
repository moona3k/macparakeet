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
    @State private var summaryCopied = false
    @State private var copiedMessageId: UUID?
    @State private var hoveredMessageId: UUID?
    @State private var exportConfirmation: ExportConfirmation?
    @State private var exportErrorMessage: String?
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?
    @State private var editingSpeakerId: String?
    @State private var editingSpeakerLabel: String = ""
    @FocusState private var chatInputFocused: Bool
    @FocusState private var speakerRenameFocused: Bool

    private let suggestedPrompts = [
        "Summarize the key points",
        "What are the main takeaways?",
        "List any action items mentioned",
    ]

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

            if viewModel.showTabs {
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
            viewModel.resetSummaryState()
            viewModel.loadPersistedContent()
            let text = viewModel.currentTranscription?.cleanTranscript ?? viewModel.currentTranscription?.rawTranscript ?? ""
            chatViewModel.loadTranscript(text, transcriptionId: viewModel.currentTranscription?.id, chatMessages: viewModel.currentTranscription?.chatMessages)
        }
        .onChange(of: transcription.id) {
            editingSpeakerId = nil
            editingSpeakerLabel = ""
            viewModel.selectedTab = .transcript
            viewModel.resetSummaryState()
            viewModel.loadPersistedContent()
            let text = viewModel.currentTranscription?.cleanTranscript ?? viewModel.currentTranscription?.rawTranscript ?? ""
            chatViewModel.loadTranscript(text, transcriptionId: viewModel.currentTranscription?.id, chatMessages: viewModel.currentTranscription?.chatMessages)
        }
    }

    @ViewBuilder
    private func contentArea(availableWidth: CGFloat) -> some View {
        Group {
            if viewModel.showTabs {
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
                if let speakers = transcription.speakers, !speakers.isEmpty {
                    speakerSummaryPanel(speakers: speakers)
                }

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
                    // Focus is handled by onAppear in chatPane with async delay
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
                    VStack(spacing: DesignSystem.Spacing.md) {
                        Image(systemName: "text.document")
                            .font(.system(size: 28))
                            .foregroundStyle(.quaternary)
                        Text("No summary yet")
                            .foregroundStyle(.secondary)
                            .font(DesignSystem.Typography.body)

                        if viewModel.canGenerateSummary {
                            Text("Summaries are generated automatically after transcription, or you can generate one manually.")
                                .foregroundStyle(.tertiary)
                                .font(DesignSystem.Typography.caption)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)

                            Button {
                                let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
                                viewModel.generateSummary(text: text)
                            } label: {
                                Label("Generate Summary", systemImage: "sparkles")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        } else {
                            Text("Configure an LLM provider in Settings to generate summaries.")
                                .foregroundStyle(.tertiary)
                                .font(DesignSystem.Typography.caption)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DesignSystem.Spacing.xl)
                case .streaming:
                    if viewModel.summary.isEmpty {
                        SummarySkeletonView()
                    } else {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                SpinnerRingView(
                                    size: 18,
                                    revolutionDuration: 3.0,
                                    tintColor: DesignSystem.Colors.accent
                                )
                                AIStreamingIndicator()
                            }

                            MarkdownText(viewModel.summary, font: DesignSystem.Typography.bodyLarge)
                        }
                    }
                case .complete:
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        MarkdownText(viewModel.summary, font: DesignSystem.Typography.bodyLarge)

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(viewModel.summary, forType: .string)
                                Telemetry.send(.copyToClipboard(source: .transcription))
                                summaryCopied = true
                                copiedResetTask?.cancel()
                                copiedResetTask = Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    summaryCopied = false
                                }
                            } label: {
                                Label(
                                    summaryCopied ? "Copied" : "Copy",
                                    systemImage: summaryCopied ? "checkmark" : "doc.on.doc"
                                )
                                .font(DesignSystem.Typography.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(summaryCopied ? DesignSystem.Colors.successGreen : .primary)

                            if viewModel.canGenerateSummary {
                                Button {
                                    let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
                                    viewModel.generateSummary(text: text)
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                        .font(DesignSystem.Typography.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                case .error(let message):
                    VStack(spacing: DesignSystem.Spacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(DesignSystem.Colors.errorRed.opacity(0.6))
                        Text(message)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
                            viewModel.generateSummary(text: text)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DesignSystem.Spacing.xl)
                }
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
    }

    // MARK: - Chat Pane

    @ViewBuilder
    private func chatPane(viewModel chatVM: TranscriptChatViewModel) -> some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                        if chatVM.messages.isEmpty {
                            VStack(spacing: DesignSystem.Spacing.lg) {
                                MeditativeMerkabaView(
                                    size: 64,
                                    revolutionDuration: 6.0,
                                    tintColor: DesignSystem.Colors.accent
                                )
                                
                                VStack(spacing: DesignSystem.Spacing.xs) {
                                    Text("Ask a question about this transcript")
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .font(DesignSystem.Typography.pageTitle)

                                    Text("Or try one of these:")
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                        .font(DesignSystem.Typography.body)
                                }

                                VStack(spacing: DesignSystem.Spacing.sm) {
                                    ForEach(suggestedPrompts, id: \.self) { prompt in
                                        Button {
                                            chatVM.inputText = prompt
                                            chatVM.sendMessage()
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "sparkle")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(DesignSystem.Colors.accent.opacity(0.7))
                                                Text(prompt)
                                                    .font(DesignSystem.Typography.bodySmall)
                                            }
                                            .padding(.horizontal, DesignSystem.Spacing.md)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule()
                                                    .fill(DesignSystem.Colors.surfaceElevated)
                                                    .overlay(
                                                        Capsule()
                                                            .stroke(DesignSystem.Colors.border.opacity(0.8), lineWidth: 1)
                                                    )
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, DesignSystem.Spacing.hero)
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
                    .padding(DesignSystem.Spacing.lg)
                }
                .onChange(of: chatVM.messages.count) {
                    if let lastID = chatVM.messages.last?.id {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: chatVM.messages.last?.content) {
                    if let lastID = chatVM.messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
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
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.bodyLarge)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 12)
                    .focused($chatInputFocused)
                    .onSubmit {
                        if !chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chatVM.canSendMessage && !chatVM.isStreaming {
                            chatVM.sendMessage()
                        }
                        chatInputFocused = true
                    }
                    .disabled(chatVM.isStreaming || !chatVM.canSendMessage)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            chatInputFocused = true
                        }
                    }
                    .onChange(of: chatVM.isStreaming) { _, isStreaming in
                        if !isStreaming { chatInputFocused = true }
                    }

                if chatVM.isStreaming {
                    Button {
                        chatVM.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .contentShape(Circle())
                } else {
                    let canSend = !chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chatVM.canSendMessage
                    Button {
                        chatVM.sendMessage()
                        chatInputFocused = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.3))
                    .disabled(!canSend)
                    .contentShape(Circle())
                }

                if !chatVM.messages.isEmpty {
                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 4)
                    
                    Button {
                        chatVM.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .help("Clear Chat History")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 1)
            )
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.xs)
            .padding(.horizontal, DesignSystem.Spacing.xs)
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatDisplayMessage) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            if message.role == .user { Spacer(minLength: 60) }

            if message.role == .assistant {
                // AI Avatar — merkaba persists for all assistant messages
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

                    SpinnerRingView(size: 16, revolutionDuration: 4.0, tintColor: DesignSystem.Colors.accent)
                }
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.content.isEmpty && message.isStreaming {
                    // Light sweep loading bar
                    ChatLoadingSweep()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if message.role == .assistant {
                            MarkdownText(message.content)
                        } else {
                            Text(message.content)
                                .font(DesignSystem.Typography.bodyLarge)
                                .foregroundStyle(DesignSystem.Colors.onAccent)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.role == .user
                                  ? DesignSystem.Colors.accent
                                  : DesignSystem.Colors.surfaceElevated.opacity(0.7))
                            .shadow(color: .black.opacity(message.role == .user ? 0.15 : 0.05), radius: 4, y: 2)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        // Copy button for assistant messages — appears on hover
                        if message.role == .assistant && !message.isStreaming && !message.content.isEmpty {
                            if hoveredMessageId == message.id || copiedMessageId == message.id {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                    copiedMessageId = message.id
                                    copiedResetTask?.cancel()
                                    copiedResetTask = Task {
                                        try? await Task.sleep(for: .seconds(2))
                                        copiedMessageId = nil
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedMessageId == message.id ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 10))
                                        if copiedMessageId == message.id {
                                            Text("Copied")
                                                .font(DesignSystem.Typography.micro)
                                        }
                                    }
                                    .foregroundStyle(copiedMessageId == message.id ? DesignSystem.Colors.successGreen : DesignSystem.Colors.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.8))
                                    )
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity)
                                .padding(4)
                            }
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            hoveredMessageId = hovering ? message.id : nil
                        }
                    }
                }
            }

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
        let hasSpeakers = words.contains { $0.speakerId != nil }
        let speakerColorMap = buildSpeakerColorMap()
        let segments = groupIntoSegments(words: words)

        if hasSpeakers {
            // Speaker-aware layout: group segments into speaker turns
            let turns = groupIntoSpeakerTurns(segments: segments)
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    // Speaker label
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(speakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textTertiary)
                            .frame(width: 8, height: 8)

                        Text(turn.speakerLabel)
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(speakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textSecondary)
                    }
                    .padding(.top, DesignSystem.Spacing.sm)

                    // Segments within this turn
                    ForEach(Array(turn.segments.enumerated()), id: \.offset) { _, segment in
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
            }
        } else {
            // No speakers — original layout
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
    }

    // MARK: - Speaker Summary Panel

    @ViewBuilder
    private func speakerSummaryPanel(speakers: [SpeakerInfo]) -> some View {
        let colorMap = buildSpeakerColorMap()
        let speakerStats = computeSpeakerStats()

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ForEach(speakers, id: \.id) { speaker in
                let stats = speakerStats[speaker.id]
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(colorMap[speaker.id] ?? DesignSystem.Colors.textTertiary)
                        .frame(width: 8, height: 8)

                    speakerLabelView(speaker: speaker, color: colorMap[speaker.id] ?? DesignSystem.Colors.textSecondary)

                    if let stats {
                        Text(formatSpeakingTime(ms: stats.speakingTimeMs))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.tertiary)

                        Text("·")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.quaternary)

                        Text("\(stats.wordCount) words")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    @ViewBuilder
    private func speakerLabelView(speaker: SpeakerInfo, color: Color) -> some View {
        if editingSpeakerId == speaker.id {
            TextField("Name", text: $editingSpeakerLabel)
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(color)
                .textFieldStyle(.plain)
                .frame(minWidth: 60, maxWidth: 200)
                .focused($speakerRenameFocused)
                .task { speakerRenameFocused = true }
                .onSubmit {
                    commitSpeakerRename()
                }
                .onExitCommand {
                    editingSpeakerId = nil
                }
                .onChange(of: speakerRenameFocused) {
                    if !speakerRenameFocused {
                        commitSpeakerRename()
                    }
                }
        } else {
            Text(speaker.label)
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(color)
                .onTapGesture {
                    // Commit any in-flight rename before switching
                    if editingSpeakerId != nil {
                        commitSpeakerRename()
                    }
                    editingSpeakerId = speaker.id
                    editingSpeakerLabel = speaker.label
                }
                .help("Click to rename")
        }
    }

    private func commitSpeakerRename() {
        guard let speakerId = editingSpeakerId else { return }
        viewModel.renameSpeaker(id: speakerId, to: editingSpeakerLabel)
        editingSpeakerId = nil
    }

    private struct SpeakerStats {
        var speakingTimeMs: Int = 0
        var wordCount: Int = 0
    }

    private func computeSpeakerStats() -> [String: SpeakerStats] {
        var stats: [String: SpeakerStats] = [:]

        // Speaking time from diarization segments
        if let segments = transcription.diarizationSegments {
            for segment in segments {
                stats[segment.speakerId, default: SpeakerStats()].speakingTimeMs += (segment.endMs - segment.startMs)
            }
        }

        // Word count from word timestamps
        if let words = transcription.wordTimestamps {
            for word in words {
                if let speakerId = word.speakerId {
                    stats[speakerId, default: SpeakerStats()].wordCount += 1
                }
            }
        }

        return stats
    }

    private func formatSpeakingTime(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    // MARK: - Speaker Helpers

    private func buildSpeakerColorMap() -> [String: Color] {
        guard let speakers = transcription.speakers else { return [:] }
        var map: [String: Color] = [:]
        for (i, speaker) in speakers.enumerated() {
            map[speaker.id] = DesignSystem.Colors.speakerColor(for: i)
        }
        return map
    }

    private func speakerLabel(for speakerId: String?) -> String {
        guard let id = speakerId,
              let speakers = transcription.speakers,
              let info = speakers.first(where: { $0.id == id }) else {
            return "Unknown"
        }
        return info.label
    }

    private struct SpeakerTurn {
        let speakerId: String
        let speakerLabel: String
        let segments: [Segment]
    }

    private func groupIntoSpeakerTurns(segments: [Segment]) -> [SpeakerTurn] {
        guard !segments.isEmpty else { return [] }

        var turns: [SpeakerTurn] = []
        var currentSpeaker = segments[0].speakerId ?? ""
        var currentSegments: [Segment] = []

        for segment in segments {
            let segSpeaker = segment.speakerId ?? currentSpeaker
            if segSpeaker != currentSpeaker && !currentSegments.isEmpty {
                turns.append(SpeakerTurn(
                    speakerId: currentSpeaker,
                    speakerLabel: speakerLabel(for: currentSpeaker),
                    segments: currentSegments
                ))
                currentSegments = []
                currentSpeaker = segSpeaker
            }
            currentSpeaker = segSpeaker
            currentSegments.append(segment)
        }

        if !currentSegments.isEmpty {
            turns.append(SpeakerTurn(
                speakerId: currentSpeaker,
                speakerLabel: speakerLabel(for: currentSpeaker),
                segments: currentSegments
            ))
        }

        return turns
    }

    // MARK: - Segment Grouping

    private struct Segment {
        let startMs: Int
        let text: String
        let speakerId: String?
    }

    private func groupIntoSegments(words: [WordTimestamp]) -> [Segment] {
        guard !words.isEmpty else { return [] }

        var segments: [Segment] = []
        var currentWords: [String] = []
        var segmentStart = words[0].startMs
        var segmentSpeaker = words[0].speakerId

        for (i, word) in words.enumerated() {
            let isLast = i == words.count - 1
            let speakerChanged = word.speakerId != nil && word.speakerId != segmentSpeaker

            // Flush current segment on speaker change before adding this word
            if speakerChanged && !currentWords.isEmpty {
                segments.append(Segment(
                    startMs: segmentStart,
                    text: currentWords.joined(separator: " "),
                    speakerId: segmentSpeaker
                ))
                currentWords = []
                segmentStart = word.startMs
                segmentSpeaker = word.speakerId
            }

            currentWords.append(word.word)
            // Track speaker (nil words inherit current speaker)
            if word.speakerId != nil {
                segmentSpeaker = word.speakerId
            }

            let endsWithPunctuation = word.word.last.map { ".!?".contains($0) } ?? false
            let hasLongGap = i + 1 < words.count && (words[i + 1].startMs - word.endMs) > 1500
            let tooLong = currentWords.count >= 40

            if isLast || (endsWithPunctuation && currentWords.count >= 3) || hasLongGap || tooLong {
                segments.append(Segment(
                    startMs: segmentStart,
                    text: currentWords.joined(separator: " "),
                    speakerId: segmentSpeaker
                ))
                currentWords = []
                if !isLast {
                    segmentStart = words[i + 1].startMs
                    segmentSpeaker = words[i + 1].speakerId
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
        Telemetry.send(.copyToClipboard(source: .transcription))
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
        // Use the ViewModel's copy which reflects any in-flight renames
        let source = viewModel.currentTranscription ?? transcription
        let stem = sanitizedExportStem(from: source.fileName)
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
            case .txt: try exportService.exportToTxt(transcription: source, url: fileURL)
            case .md: try exportService.exportToMarkdown(transcription: source, url: fileURL)
            case .srt: try exportService.exportToSRT(transcription: source, url: fileURL)
            case .vtt: try exportService.exportToVTT(transcription: source, url: fileURL)
            case .docx: try exportService.exportToDocx(transcription: source, url: fileURL)
            case .pdf: try exportService.exportToPDF(transcription: source, url: fileURL)
            case .json: try exportService.exportToJSON(transcription: source, url: fileURL)
            }
            Telemetry.send(.exportUsed(format: format.rawValue))
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
