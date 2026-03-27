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
    @State private var showConversationPopover = false
    @State private var hoveredConversationId: UUID?
    @FocusState private var chatInputFocused: Bool
    @FocusState private var speakerRenameFocused: Bool

    private let suggestedPrompts = [
        "Summarize the key points",
        "What are the main takeaways?",
        "List any action items mentioned",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeaderCard
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)

            if viewModel.showTabs {
                tabBar
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.md)
            }

            contentArea
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
            chatViewModel.loadTranscript(text, transcriptionId: viewModel.currentTranscription?.id)
        }
        .onChange(of: transcription.id) {
            editingSpeakerId = nil
            editingSpeakerLabel = ""
            showConversationPopover = false
            hoveredConversationId = nil
            viewModel.hasConversations = false
            viewModel.selectedTab = .transcript
            viewModel.resetSummaryState()
            viewModel.loadPersistedContent()
            let text = viewModel.currentTranscription?.cleanTranscript ?? viewModel.currentTranscription?.rawTranscript ?? ""
            chatViewModel.loadTranscript(text, transcriptionId: viewModel.currentTranscription?.id)
        }
    }

    private var transcriptText: String {
        transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
    }

    private var transcriptWordCount: Int {
        if let wordTimestamps = transcription.wordTimestamps, !wordTimestamps.isEmpty {
            return wordTimestamps.count
        }
        return transcriptText.split(whereSeparator: \.isWhitespace).count
    }

    private var speakerCountValue: Int {
        transcription.speakers?.count ?? transcription.speakerCount ?? 0
    }

    private var resultHeaderCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(backHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(backHovered ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surface)
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

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(transcription.fileName)
                                .font(DesignSystem.Typography.pageTitle)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(3)

                            Text("Transcript ready for review, summary, and chat.")
                                .font(DesignSystem.Typography.bodySmall)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }

                        Spacer(minLength: DesignSystem.Spacing.md)

                        SonicMandalaView(
                            data: mandalaData,
                            size: 64,
                            style: .fullColor
                        )
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        metadataChip(
                            icon: transcription.sourceURL != nil ? "play.rectangle.fill" : "waveform",
                            text: transcription.sourceURL != nil ? "YouTube source" : "Local file",
                            tint: transcription.sourceURL != nil ? DesignSystem.Colors.youtubeRed : DesignSystem.Colors.accent
                        )

                        if let durationMs = transcription.durationMs {
                            metadataChip(
                                icon: "clock",
                                text: durationMs.formattedDuration,
                                tint: DesignSystem.Colors.textSecondary
                            )
                        }

                        if transcriptWordCount > 0 {
                            metadataChip(
                                icon: "text.word.spacing",
                                text: "\(transcriptWordCount.formatted()) words",
                                tint: DesignSystem.Colors.textSecondary
                            )
                        }

                        if speakerCountValue > 0 {
                            metadataChip(
                                icon: "person.2.fill",
                                text: "\(speakerCountValue) speaker\(speakerCountValue == 1 ? "" : "s")",
                                tint: DesignSystem.Colors.textSecondary
                            )
                        }
                    }

                    if let sourceURL = transcription.sourceURL,
                       let url = URL(string: sourceURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(sourceURL)
                                    .font(DesignSystem.Typography.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(DesignSystem.Colors.surface)
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
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.75), lineWidth: 0.5)
        )
    }

    private func metadataChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(DesignSystem.Typography.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(tint.opacity(0.10))
        )
    }

    @ViewBuilder
    private var contentArea: some View {
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
                } else if !transcriptText.isEmpty {
                    Text(transcriptText)
                        .font(DesignSystem.Typography.bodyLarge)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(6)
                        .padding(DesignSystem.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        )
                } else {
                    Text("No transcript available")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
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
                    HStack(spacing: 6) {
                        Image(systemName: tabIcon(tab))
                            .font(.system(size: 11, weight: .semibold))
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
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(viewModel.selectedTab == tab
                                  ? DesignSystem.Colors.accent.opacity(0.12)
                                  : .clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.selectedTab == tab ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
            }
            Spacer()
        }
    }

    private func tabIcon(_ tab: TranscriptionViewModel.TranscriptTab) -> String {
        switch tab {
        case .transcript:
            return "text.alignleft"
        case .summary:
            return "sparkles.rectangle.stack"
        case .chat:
            return "bubble.left.and.text.bubble.right"
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
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                        Text("No summary yet")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .font(DesignSystem.Typography.body)

                        if viewModel.canGenerateSummary {
                            Text("Summaries are generated automatically after transcription, or you can generate one manually.")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .font(DesignSystem.Typography.caption)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)

                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Button {
                                    let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
                                    viewModel.generateSummary(text: text)
                                } label: {
                                    Label("Generate Summary", systemImage: "sparkles")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                if !viewModel.availableModels.isEmpty {
                                    ModelSelectorView(
                                        currentModel: viewModel.currentModelName,
                                        displayName: viewModel.modelDisplayName,
                                        availableModels: viewModel.availableModels,
                                        onSelect: { viewModel.selectModel($0) }
                                    )
                                }
                            }
                        } else {
                            Text("Configure an LLM provider in Settings to generate summaries.")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .font(DesignSystem.Typography.caption)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DesignSystem.Spacing.xl)
                case .streaming:
                    summaryContentCard(isStreaming: true)
                case .complete:
                    summaryContentCard(isStreaming: false)
                case .error(let message):
                    VStack(spacing: DesignSystem.Spacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(DesignSystem.Colors.errorRed.opacity(0.6))
                        Text(message)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                        Button {
                            let text = transcriptText
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

    private func summaryContentCard(isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isStreaming ? "Generating summary" : "AI summary")
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(isStreaming ? "Reading the transcript and assembling a concise overview." : "A readable brief you can copy, refine, or regenerate.")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                if !viewModel.availableModels.isEmpty {
                    ModelSelectorView(
                        currentModel: viewModel.currentModelName,
                        displayName: viewModel.modelDisplayName,
                        availableModels: viewModel.availableModels,
                        disabled: viewModel.summaryState == .streaming,
                        onSelect: { viewModel.selectModel($0) }
                    )
                }
            }

            if viewModel.summary.isEmpty && isStreaming {
                SummarySkeletonView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownContentView(viewModel.summary, font: DesignSystem.Typography.bodyLarge)
                        .padding(DesignSystem.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isStreaming {
                        AIStreamingIndicator()
                            .padding(.leading, DesignSystem.Spacing.lg)
                            .padding(.bottom, DesignSystem.Spacing.md)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.65))
                )
            }

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
                        viewModel.generateSummary(text: transcriptText)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                            .font(DesignSystem.Typography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isStreaming)
                }

                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    // MARK: - Chat Pane

    @ViewBuilder
    private func chatPane(viewModel chatVM: TranscriptChatViewModel) -> some View {
        VStack(spacing: 0) {
            // Chat header with conversation switcher
            if !chatVM.conversations.isEmpty || !chatVM.messages.isEmpty {
                chatPaneHeader(chatVM: chatVM)
                Divider()
            }

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                            if !chatVM.canSendMessage {
                                chatConfigurationBanner
                            } else if chatVM.messages.isEmpty {
                                chatEmptyState(chatVM: chatVM)
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
                    .defaultScrollAnchor(.bottom)
                    .background(DesignSystem.Colors.surface)

                    Divider()

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            TextField("Ask about this transcript...", text: Bindable(chatVM).inputText)
                                .textFieldStyle(.plain)
                                .font(DesignSystem.Typography.bodyLarge)
                                .padding(.horizontal, DesignSystem.Spacing.md)
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
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(DesignSystem.Colors.surfaceElevated)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 1)
                                )

                            if chatVM.isStreaming {
                                Button {
                                    chatVM.cancelStreaming()
                                } label: {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 26))
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
                                        .font(.system(size: 26))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(canSend ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.3))
                                .disabled(!canSend)
                                .contentShape(Circle())
                            }
                        }

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            if chatVM.canSendMessage && !chatVM.availableModels.isEmpty {
                                ModelSelectorView(
                                    currentModel: chatVM.currentModelName,
                                    displayName: chatVM.modelDisplayName,
                                    availableModels: chatVM.availableModels,
                                    disabled: chatVM.isStreaming,
                                    onSelect: { chatVM.selectModel($0) }
                                )
                            }

                            if chatVM.isStreaming {
                                Text("Streaming response…")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }

                            Spacer()
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                    .background(DesignSystem.Colors.cardBackground)
                }
                .onChange(of: chatVM.messages.count) {
                    if let lastID = chatVM.messages.last?.id {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
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
    }

    @ViewBuilder
    private func chatPaneHeader(chatVM: TranscriptChatViewModel) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                showConversationPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(chatVM.currentConversation?.title ?? "New Chat")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showConversationPopover, arrowEdge: .bottom) {
                conversationListPopover(chatVM: chatVM)
            }

            Spacer()

            Button {
                chatVM.newChat()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .font(DesignSystem.Typography.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
    }

    @ViewBuilder
    private func conversationListPopover(chatVM: TranscriptChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chatVM.conversations) { conversation in
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if hoveredConversationId == conversation.id {
                        Button {
                            chatVM.deleteConversation(conversation)
                            if chatVM.conversations.isEmpty {
                                showConversationPopover = false
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    chatVM.currentConversation?.id == conversation.id
                        ? DesignSystem.Colors.accent.opacity(0.1)
                        : Color.clear
                )
                .contentShape(Rectangle())
                .onHover { isHovered in
                    if isHovered {
                        hoveredConversationId = conversation.id
                    } else if hoveredConversationId == conversation.id {
                        hoveredConversationId = nil
                    }
                }
                .onTapGesture {
                    chatVM.switchConversation(conversation)
                    showConversationPopover = false
                }
            }
        }
        .frame(minWidth: 200, maxWidth: 300)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatDisplayMessage) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            if message.role == .user { Spacer(minLength: 60) }

            if message.role == .assistant {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

                    if message.isStreaming {
                        SpinnerRingView(size: 16, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.content.isEmpty && message.isStreaming {
                    // Light sweep loading bar
                    ChatLoadingSweep()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if message.role == .assistant {
                            MarkdownContentView(message.content)
                        } else {
                            Text(message.content)
                                .font(DesignSystem.Typography.bodyLarge)
                                .foregroundStyle(DesignSystem.Colors.onAccent)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.role == .user
                                  ? DesignSystem.Colors.accent
                                  : DesignSystem.Colors.surfaceElevated.opacity(0.9))
                            .shadow(color: .black.opacity(message.role == .user ? 0.15 : 0.05), radius: 4, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                message.role == .user ? DesignSystem.Colors.accent.opacity(0.25) : DesignSystem.Colors.border.opacity(0.45),
                                lineWidth: 0.5
                            )
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

    private var chatConfigurationBanner: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "brain")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Chat needs an AI provider")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Configure Gemini, OpenAI, Anthropic, or another provider in Settings to ask follow-up questions about this transcript.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.accentLight)
        )
    }

    private func chatEmptyState(chatVM: TranscriptChatViewModel) -> some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            MeditativeMerkabaView(
                size: 60,
                revolutionDuration: 6.0,
                tintColor: DesignSystem.Colors.accent
            )

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Ask a question about this transcript")
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .font(DesignSystem.Typography.pageTitle)

                Text("Start with a quick prompt, then keep drilling down.")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .font(DesignSystem.Typography.body)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        chatVM.inputText = prompt
                        chatVM.sendMessage()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
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
        .padding(.vertical, DesignSystem.Spacing.hero)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
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
        let hasSpeakers = words.contains { $0.speakerId != nil }
        let speakerColorMap = buildSpeakerColorMap()
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)

        if hasSpeakers {
            // Speaker-aware layout: group segments into speaker turns
            let turns = TranscriptSegmenter.groupIntoSpeakerTurns(segments: segments, speakerLabelProvider: speakerLabel(for:))
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                transcriptTurnCard(
                    speakerLabel: turn.speakerLabel,
                    speakerColor: speakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textTertiary,
                    segments: turn.segments.map { ($0.startMs, $0.text) }
                )
            }
        } else {
            // No speakers — render as clean transcript segments instead of a flat log.
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    timestampChip(segment.startMs)

                    Text(segment.text)
                        .font(DesignSystem.Typography.bodyLarge)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.45))
                )
            }
        }
    }

    // MARK: - Speaker Summary Panel

    @ViewBuilder
    private func speakerSummaryPanel(speakers: [SpeakerInfo]) -> some View {
        let colorMap = buildSpeakerColorMap()
        let speakerStats = TranscriptSegmenter.computeSpeakerStats(
            diarizationSegments: transcription.diarizationSegments,
            wordTimestamps: transcription.wordTimestamps
        )

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Speaker overview")
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            ForEach(speakers, id: \.id) { speaker in
                let stats = speakerStats[speaker.id]
                HStack(spacing: DesignSystem.Spacing.md) {
                    Circle()
                        .fill(colorMap[speaker.id] ?? DesignSystem.Colors.textTertiary)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 6) {
                        speakerLabelView(speaker: speaker, color: colorMap[speaker.id] ?? DesignSystem.Colors.textSecondary)

                        if let stats {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                metadataChip(icon: "clock", text: formatSpeakingTime(ms: stats.speakingTimeMs), tint: DesignSystem.Colors.textSecondary)
                                metadataChip(icon: "text.word.spacing", text: "\(stats.wordCount.formatted()) words", tint: DesignSystem.Colors.textSecondary)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.45))
                )
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.25))
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


    private func formatSpeakingTime(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func transcriptTurnCard(
        speakerLabel: String,
        speakerColor: Color,
        segments: [(startMs: Int, text: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 10, height: 10)

                Text(speakerLabel)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(speakerColor)

                if let firstStart = segments.first?.startMs {
                    metadataChip(icon: "clock", text: formatTimestamp(ms: firstStart), tint: DesignSystem.Colors.textSecondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        timestampChip(segment.startMs)

                        Text(segment.text)
                            .font(DesignSystem.Typography.bodyLarge)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(speakerColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(speakerColor.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func timestampChip(_ startMs: Int) -> some View {
        Text(formatTimestamp(ms: startMs))
            .font(DesignSystem.Typography.timestamp)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surface)
            )
            .frame(width: 72, alignment: .leading)
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
        let stem = TranscriptSegmenter.sanitizedExportStem(from: source.fileName)
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


    private func formatTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
