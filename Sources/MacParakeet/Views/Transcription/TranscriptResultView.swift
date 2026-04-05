import AVKit
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
    @Bindable var promptResultsViewModel: PromptResultsViewModel
    @Bindable var promptsViewModel: PromptsViewModel
    var onBack: (() -> Void)?
    var onRetranscribe: ((Transcription) -> Void)?

    @State private var backHovered = false
    @State private var headerExpanded = false
    @State private var speakerOverviewExpanded = false
    @State private var copied = false
    @State private var copiedResultID: UUID?
    @State private var copiedButtonResultID: UUID?
    @State private var copiedMessageId: UUID?
    @State private var hoveredMessageId: UUID?
    @State private var exportConfirmation: ExportConfirmation?
    @State private var exportErrorMessage: String?
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var resultCopiedResetTask: Task<Void, Never>?
    @State private var resultButtonCopiedResetTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?
    @State private var editingSpeakerId: String?
    @State private var editingSpeakerLabel: String = ""
    @State private var showConversationPopover = false
    @State private var hoveredConversationId: UUID?
    @State private var playerViewModel = MediaPlayerViewModel()
    @State private var showVideoPanel = false
    @State private var lastScrolledSegmentMs: Int = -1
    // Cached transcript data — recomputed only when transcription.id changes, not on every playback tick
    @State private var cachedSegments: [TranscriptSegment] = []
    @State private var cachedTurns: [SpeakerTurn] = []
    @State private var cachedHasSpeakers: Bool = false
    @State private var cachedSpeakerColorMap: [String: Color] = [:]
    @State private var cachedSegmentStartMs: [Int] = []  // sorted, for binary search
    @State private var autoScrollPaused = false
    @State private var scrollPauseTask: Task<Void, Never>?
    @State private var scrollMonitor: Any?
    @State private var showPromptLibrary = false
    @State private var showGeneratePopover = false
    @State private var showingRetranscribeAlert = false
    @FocusState private var chatInputFocused: Bool
    @FocusState private var speakerRenameFocused: Bool

    private let suggestedPrompts = [
        "Summarize the key points",
        "What are the main takeaways?",
        "List any action items mentioned",
    ]

    var body: some View {
        adaptiveLayout
        .onAppear {
            Task {
                if showVideoPanel {
                    await playerViewModel.load(for: transcription)
                } else {
                    await playerViewModel.prepare(for: transcription)
                }
                if let words = transcription.wordTimestamps, !words.isEmpty {
                    playerViewModel.loadSubtitleCues(from: words)
                }
            }
            rebuildSegmentCache()
            viewModel.loadPersistedContent()
            promptResultsViewModel.loadVisiblePrompts()
            promptResultsViewModel.loadPromptResults(transcriptionId: transcription.id)
            let text = viewModel.currentTranscription?.cleanTranscript ?? viewModel.currentTranscription?.rawTranscript ?? ""
            chatViewModel.loadTranscript(text, transcriptionId: viewModel.currentTranscription?.id)
        }
        .onChange(of: transcription.id) {
            Task {
                playerViewModel.cleanup()
                if showVideoPanel {
                    await playerViewModel.load(for: transcription)
                } else {
                    await playerViewModel.prepare(for: transcription)
                }
                if let words = transcription.wordTimestamps, !words.isEmpty {
                    playerViewModel.loadSubtitleCues(from: words)
                }
            }
            rebuildSegmentCache()
            headerExpanded = false
            speakerOverviewExpanded = false
            editingSpeakerId = nil
            editingSpeakerLabel = ""
            showConversationPopover = false
            hoveredConversationId = nil
            lastScrolledSegmentMs = -1
            autoScrollPaused = false
            scrollPauseTask?.cancel()
            viewModel.hasConversations = false
            viewModel.selectedTab = .transcript
            viewModel.loadPersistedContent()
            promptResultsViewModel.loadPromptResults(transcriptionId: transcription.id)
            let text = viewModel.currentTranscription?.cleanTranscript ?? viewModel.currentTranscription?.rawTranscript ?? ""
            chatViewModel.loadTranscript(text, transcriptionId: viewModel.currentTranscription?.id)
        }
        .onChange(of: viewModel.selectedTab) {
            if case .result(let id) = viewModel.selectedTab {
                promptResultsViewModel.markPromptResultViewed(id)
            }
        }
        .onDisappear {
            playerViewModel.cleanup()
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
            scrollPauseTask?.cancel()
        }
        .sheet(isPresented: $showPromptLibrary, onDismiss: {
            promptsViewModel.loadPrompts()
            promptResultsViewModel.loadVisiblePrompts()
        }) {
            PromptLibraryView(viewModel: promptsViewModel)
        }
        .alert(
            "Delete Result?",
            isPresented: Binding(
                get: { promptResultsViewModel.pendingDeletePromptResult != nil },
                set: { if !$0 { promptResultsViewModel.pendingDeletePromptResult = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                promptResultsViewModel.confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                promptResultsViewModel.pendingDeletePromptResult = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    @ViewBuilder
    private var adaptiveLayout: some View {
        switch playerViewModel.playbackMode {
        case .video where showVideoPanel:
            HSplitView {
                videoInfoColumn
                    .frame(
                        minWidth: DesignSystem.Layout.videoPlayerMinWidth,
                        idealWidth: 480
                    )

                videoContentColumn
            }
        case .video, .audio:
            // Audio mode OR video with panel hidden — show scrubber bar + full-width content
            VStack(spacing: 0) {
                AudioScrubberBar(viewModel: playerViewModel)
                Divider()
                fullWidthContentColumn
            }
        case .none:
            fullWidthContentColumn
        }
    }

    // MARK: - Video Split Layout (Left Pane)

    /// Left pane in video mode: header card + video player + action bar
    private var videoInfoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeaderCard
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.top, DesignSystem.Spacing.md)

            TranscriptionVideoPanel(
                transcription: transcription,
                playerViewModel: playerViewModel
            )

            Spacer(minLength: 0)

            Divider()

            actionBar
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
    }

    // MARK: - Video Split Layout (Right Pane)

    /// Right pane in video mode: tabs + content (full height, no header/action bar)
    private var videoContentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if viewModel.showTabs {
                    tabBar
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                
                HStack {
                    Button {
                        withAnimation(DesignSystem.Animation.contentSwap) {
                            showVideoPanel = false
                        }
                    } label: {
                        Label("Hide Video", systemImage: "rectangle.lefthalf.inset.filled.arrow.left")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear {
            copiedResetTask?.cancel()
            copiedResetTask = nil
            resultCopiedResetTask?.cancel()
            resultCopiedResetTask = nil
            resultButtonCopiedResetTask?.cancel()
            resultButtonCopiedResetTask = nil
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    // MARK: - Full-Width Layout (No Video, Audio, or Hidden Video)

    /// Single-column layout: header + tabs + content + action bar
    private var fullWidthContentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeaderCard
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)

            HStack {
                if viewModel.showTabs {
                    tabBar
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                
                HStack {
                    if playerViewModel.playbackMode == .video && !showVideoPanel {
                        Button {
                            withAnimation(DesignSystem.Animation.contentSwap) {
                                showVideoPanel = true
                            }
                            // Lazy-load: extract YouTube stream only when user wants video
                            if playerViewModel.needsVideoStreamLoad {
                                Task {
                                    await playerViewModel.load(for: transcription)
                                }
                            }
                        } label: {
                            Label("Show Video", systemImage: "play.rectangle")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            actionBar
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
            resultCopiedResetTask?.cancel()
            resultCopiedResetTask = nil
            resultButtonCopiedResetTask?.cancel()
            resultButtonCopiedResetTask = nil
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
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
                    showingRetranscribeAlert = true
                } label: {
                    Label("Retranscribe", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .buttonStyle(.bordered)
                .alert("Retranscribe this file?", isPresented: $showingRetranscribeAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Retranscribe", role: .destructive) {
                        onRetranscribe(transcription)
                    }
                } message: {
                    Text("All custom tabs, results, and chats generated from the current transcript will be removed and cannot be recovered.")
                }
            }

            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
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
        VStack(alignment: .leading, spacing: 0) {
            // Always-visible compact row: back button + title + metadata + mandala + expand toggle
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(backHovered ? DesignSystem.Colors.accent : DesignSystem.Colors.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(backHovered ? DesignSystem.Colors.accent.opacity(0.12) : DesignSystem.Colors.surfaceElevated)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(transcription.fileName)
                        .font(headerExpanded ? DesignSystem.Typography.pageTitle : DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(headerExpanded ? 3 : 1)

                    if !headerExpanded {
                        // Inline metadata in collapsed mode
                        HStack(spacing: 6) {
                            metadataChip(
                                icon: transcription.sourceURL != nil ? "play.rectangle.fill" : "waveform",
                                text: transcription.sourceURL != nil ? "YouTube" : "Local",
                                tint: transcription.sourceURL != nil ? DesignSystem.Colors.youtubeRed : DesignSystem.Colors.accent
                            )

                            if let durationMs = transcription.durationMs {
                                metadataChip(icon: "clock", text: durationMs.formattedDuration, tint: DesignSystem.Colors.textSecondary)
                            }

                            if transcriptWordCount > 0 {
                                metadataChip(icon: "text.word.spacing", text: "\(transcriptWordCount.formatted()) words", tint: DesignSystem.Colors.textSecondary)
                            }

                            if speakerCountValue > 0 {
                                metadataChip(icon: "person.2.fill", text: "\(speakerCountValue) speaker\(speakerCountValue == 1 ? "" : "s")", tint: DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                }

                Spacer(minLength: DesignSystem.Spacing.sm)

                SonicMandalaView(
                    data: mandalaData,
                    size: headerExpanded ? 56 : 40,
                    style: .fullColor
                )

                // Expand/collapse chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .rotationEffect(.degrees(headerExpanded ? 180 : 0))
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            // Expanded details section
            if headerExpanded {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        metadataChip(
                            icon: transcription.sourceURL != nil ? "play.rectangle.fill" : "waveform",
                            text: transcription.sourceURL != nil ? "YouTube source" : "Local file",
                            tint: transcription.sourceURL != nil ? DesignSystem.Colors.youtubeRed : DesignSystem.Colors.accent
                        )

                        if let durationMs = transcription.durationMs {
                            metadataChip(icon: "clock", text: durationMs.formattedDuration, tint: DesignSystem.Colors.textSecondary)
                        }

                        if transcriptWordCount > 0 {
                            metadataChip(icon: "text.word.spacing", text: "\(transcriptWordCount.formatted()) words", tint: DesignSystem.Colors.textSecondary)
                        }

                        if speakerCountValue > 0 {
                            metadataChip(icon: "person.2.fill", text: "\(speakerCountValue) speaker\(speakerCountValue == 1 ? "" : "s")", tint: DesignSystem.Colors.textSecondary)
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
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)
                .padding(.leading, onBack != nil ? 36 + DesignSystem.Spacing.sm : 0)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                headerExpanded.toggle()
            }
        }
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
                case .result(let id):
                    if promptResultsViewModel.promptResults.contains(where: { $0.id == id }) {
                        promptResultContentPane(promptResultID: id)
                    } else {
                        transcriptPane
                            .onAppear { viewModel.selectedTab = .transcript }
                    }
                case .generation(let id):
                    if promptResultsViewModel.pendingGeneration(id: id) != nil {
                        pendingGenerationPane(generationID: id)
                    } else {
                        transcriptPane
                            .onAppear { viewModel.selectedTab = .transcript }
                    }
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
        ScrollViewReader { proxy in
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
            .onChange(of: playerViewModel.currentTimeMs) { oldValue, newValue in
                guard playerViewModel.isPlaying else { return }
                // Detect seek (large time jump) — re-sync transcript regardless of pause state
                if autoScrollPaused && abs(newValue - oldValue) > 2000 {
                    autoScrollPaused = false
                    scrollPauseTask?.cancel()
                    lastScrolledSegmentMs = -1
                }
                guard !autoScrollPaused else { return }
                guard !cachedSegments.isEmpty else { return }
                if let targetId = autoScrollTarget(for: newValue),
                   targetId != lastScrolledSegmentMs {
                    lastScrolledSegmentMs = targetId
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetId, anchor: .center)
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
        .onAppear {
            if let existing = scrollMonitor {
                NSEvent.removeMonitor(existing)
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                if self.playerViewModel.isPlaying {
                    if !self.autoScrollPaused {
                        self.autoScrollPaused = true
                        self.lastScrolledSegmentMs = -1
                    }
                    self.scrollPauseTask?.cancel()
                    self.scrollPauseTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        if !Task.isCancelled {
                            self.autoScrollPaused = false
                        }
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
            scrollPauseTask?.cancel()
            autoScrollPaused = false
        }
    }

    // MARK: - Tab Bar

    private var orderedTabs: [TranscriptionViewModel.TranscriptTab] {
        var tabs: [TranscriptionViewModel.TranscriptTab] = [.transcript]
        // Generated content after transcript, oldest first so new tabs appear on the right
        for promptResult in promptResultsViewModel.promptResults.reversed() {
            tabs.append(.result(id: promptResult.id))
        }
        for generation in promptResultsViewModel.pendingGenerations(for: transcription.id) {
            tabs.append(.generation(id: generation.id))
        }
        tabs.append(.chat)
        return tabs
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(orderedTabs, id: \.self) { tab in
                    tabCapsule(for: tab)
                }

                if promptResultsViewModel.hasPromptResultGenerationCapability {
                    generateTabButton
                }

                Spacer()
            }
        }
        .mask(
            Rectangle()
                .padding(.vertical, -20)
        )
    }

    private func tabCapsule(for tab: TranscriptionViewModel.TranscriptTab) -> some View {
        let isSelected = viewModel.selectedTab == tab

        let isStreamingTab = {
            if case .generation(let id) = tab,
               let generation = promptResultsViewModel.pendingGeneration(id: id) {
                return generation.state == .streaming
            }
            return false
        }()

        let isCopiedTab: Bool = {
            if case .result(let id) = tab { return copiedResultID == id }
            return false
        }()

        return HStack(spacing: 6) {
            Image(systemName: tabIcon(tab))
                .font(.system(size: 11, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: isStreamingTab)
            Text(tabLabel(tab))
                .font(DesignSystem.Typography.bodySmall.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)

            if case .result(let id) = tab, promptResultsViewModel.hasUnreadPromptResult(id) {
                Circle()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: 6, height: 6)
            }

            if isCopiedTab {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(isSelected ? DesignSystem.Colors.accent.opacity(0.12) : .clear)
        )
        .contentShape(Capsule())
        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
        .animation(.easeInOut(duration: 0.3), value: isCopiedTab)
        .onTapGesture {
            viewModel.selectedTab = tab
        }
        .contextMenu {
            if case .result(let id) = tab,
               let promptResult = promptResultsViewModel.promptResults.first(where: { $0.id == id }) {
                Button("Copy Result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(promptResult.content, forType: .string)
                    Telemetry.send(.copyToClipboard(source: .transcription))
                    copiedResultID = id
                    resultCopiedResetTask?.cancel()
                    resultCopiedResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedResultID = nil
                    }
                }
                
                Menu("Export Document") {
                    Button("Markdown (.md)") { exportGenerationToDownloads(promptResult: promptResult, format: .md) }
                    Button("Plain Text (.txt)") { exportGenerationToDownloads(promptResult: promptResult, format: .txt) }
                }
                
                Button("Delete Result", role: .destructive) {
                    promptResultsViewModel.pendingDeletePromptResult = promptResult
                }
            }
            if case .generation(let id) = tab {
                Button("Remove", role: .destructive) {
                    promptResultsViewModel.cancelGeneration(id: id)
                }
            }
        }
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var generateTabButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .foregroundStyle(
                promptResultsViewModel.canGeneratePromptResult
                    ? DesignSystem.Colors.textSecondary
                    : DesignSystem.Colors.textTertiary
            )
            .onTapGesture {
                guard promptResultsViewModel.canGeneratePromptResult else { return }
                showGeneratePopover = true
            }
            .popover(isPresented: $showGeneratePopover) {
                promptGenerationPopover
                    .frame(width: 420)
                    .padding(DesignSystem.Spacing.lg)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("New prompt generation")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func tabIcon(_ tab: TranscriptionViewModel.TranscriptTab) -> String {
        switch tab {
        case .transcript:
            return "text.alignleft"
        case .result:
            return "sparkles"
        case .generation(let id):
            if promptResultsViewModel.pendingGeneration(id: id)?.state == .queued {
                return "clock"
            }
            return "sparkles"
        case .chat:
            return "bubble.left.and.text.bubble.right"
        }
    }

    private func tabLabel(_ tab: TranscriptionViewModel.TranscriptTab) -> String {
        switch tab {
        case .transcript:
            return "Transcript"
        case .result(let id):
            guard let promptResult = promptResultsViewModel.promptResults.first(where: { $0.id == id }) else { return "Result" }
            return label(for: promptResult.promptName, extraInstructions: promptResult.extraInstructions)
        case .generation(let id):
            guard let gen = promptResultsViewModel.pendingGeneration(id: id) else { return "Result" }
            return label(for: gen.promptName, extraInstructions: gen.extraInstructions)
        case .chat:
            return "Chat"
        }
    }

    private func label(for promptName: String, extraInstructions: String?) -> String {
        guard let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty else {
            return promptName
        }
        let limit = 16
        let truncated = extra.count > limit ? String(extra.prefix(limit)) + "..." : extra
        return "\(promptName) + \"\(truncated)\""
    }

    // MARK: - Result Panes

    private func promptResultContentPane(promptResultID: UUID) -> some View {
        let promptResult = promptResultsViewModel.promptResults.first(where: { $0.id == promptResultID })
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if let promptResult {
                    HStack {
                        Spacer()

                        Button {
                            if let generationID = promptResultsViewModel.regeneratePromptResult(promptResult, transcript: transcriptText) {
                                viewModel.selectedTab = .generation(id: generationID)
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "arrow.clockwise")
                                Text("Regenerate")
                            }
                            .font(DesignSystem.Typography.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!promptResultsViewModel.canGeneratePromptResult || transcriptText.isEmpty)

                        let isCopied = copiedButtonResultID == promptResultID
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(promptResult.content, forType: .string)
                            Telemetry.send(.copyToClipboard(source: .transcription))
                            copiedButtonResultID = promptResultID
                            resultButtonCopiedResetTask?.cancel()
                            resultButtonCopiedResetTask = Task {
                                try? await Task.sleep(for: .seconds(1))
                                copiedButtonResultID = nil
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "Copied" : "Copy")
                            }
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(isCopied ? DesignSystem.Colors.successGreen : .primary)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Menu {
                            Button("Markdown (.md)") { exportGenerationToDownloads(promptResult: promptResult, format: .md) }
                            Button("Plain Text (.txt)") { exportGenerationToDownloads(promptResult: promptResult, format: .txt) }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "arrow.down.doc")
                                Text("Export")
                            }
                            .font(DesignSystem.Typography.caption)
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            promptResultsViewModel.pendingDeletePromptResult = promptResult
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(DesignSystem.Typography.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    MarkdownContentView(promptResult.content, font: DesignSystem.Typography.bodyLarge)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func pendingGenerationPane(generationID: UUID) -> some View {
        if let generation = promptResultsViewModel.pendingGeneration(id: generationID) {
            generationPane(generation)
        }
    }

    private func generationPane(_ generation: PromptResultsViewModel.PendingGeneration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    Spacer()
                    Button {
                        promptResultsViewModel.cancelGeneration(id: generation.id)
                        viewModel.selectedTab = .transcript
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: generation.state == .queued ? "minus.circle" : "xmark")
                            Text(generation.state == .queued ? "Remove" : "Cancel")
                        }
                        .font(DesignSystem.Typography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if generation.state == .queued {
                    queuedGenerationCard
                } else if generation.content.isEmpty {
                    SummarySkeletonView()
                } else {
                    MarkdownContentView(generation.content, font: DesignSystem.Typography.bodyLarge)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var queuedGenerationCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Queued", systemImage: "clock")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
            Text("This result will start automatically after the current generation finishes.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
        )
    }

    private var promptGenerationPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Prompt chips
            promptChips

            // Model selector
            if !promptResultsViewModel.availableModels.isEmpty {
                ModelSelectorView(
                    currentModel: promptResultsViewModel.currentModelName,
                    displayName: promptResultsViewModel.modelDisplayName,
                    availableModels: promptResultsViewModel.availableModels,
                    disabled: promptResultsViewModel.hasPendingGenerations,
                    onSelect: { promptResultsViewModel.selectModel($0) }
                )
            }

            // Extra instructions
            TextField("Extra instructions (optional)", text: $promptResultsViewModel.extraInstructions)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.body)

            if promptResultsViewModel.hasPendingGenerations {
                Text(queueStatusText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if let errorMessage = promptResultsViewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }

            // Actions row — manage prompts on the left, generate on the right
            HStack {
                Button {
                    showGeneratePopover = false
                    showPromptLibrary = true
                } label: {
                    Label("Manage Prompts", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button {
                    showGeneratePopover = false
                    if let generationID = promptResultsViewModel.generatePromptResult(
                        transcript: transcriptText,
                        transcriptionId: transcription.id
                    ) {
                        viewModel.selectedTab = .generation(id: generationID)
                    }
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!promptResultsViewModel.canGenerateManualPromptResult || transcriptText.isEmpty)
            }
        }
    }

    private var promptChips: some View {
        let prompts = promptResultsViewModel.visiblePrompts
        return FlowLayout(spacing: 8) {
            ForEach(prompts) { prompt in
                let isSelected = promptResultsViewModel.selectedPrompt?.id == prompt.id
                let hasExisting = promptResultsViewModel.promptResults.contains { $0.promptName == prompt.name }
                    || promptResultsViewModel.hasPendingGeneration(
                        promptName: prompt.name,
                        transcriptionId: transcription.id
                    )

                HStack(spacing: 5) {
                    Text(prompt.name)
                        .font(DesignSystem.Typography.body.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if hasExisting {
                        Circle()
                            .fill(DesignSystem.Colors.accent)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? DesignSystem.Colors.accent.opacity(0.15) : DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? DesignSystem.Colors.accent.opacity(0.4) : DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                )
                .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textPrimary)
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(DesignSystem.Animation.selectionChange) {
                        promptResultsViewModel.selectedPrompt = prompt
                    }
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }

    private var queueStatusText: String {
        if promptResultsViewModel.isStreaming && promptResultsViewModel.queuedGenerationCount > 0 {
            return "1 generating, \(promptResultsViewModel.queuedGenerationCount) queued"
        }
        if promptResultsViewModel.isStreaming {
            return "Generating result"
        }
        return "\(promptResultsViewModel.queuedGenerationCount) queued"
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
        let isUser = message.role == .user

        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
            if isUser { Spacer(minLength: 80) }

            if !isUser {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)

                    if message.isStreaming {
                        SpinnerRingView(size: 14, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if message.content.isEmpty && message.isStreaming {
                    ChatLoadingSweep()
                } else {
                    let bubbleShape = UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: isUser ? 16 : 4,
                        bottomTrailingRadius: isUser ? 4 : 16,
                        topTrailingRadius: 16
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        if isUser {
                            Text(message.content)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.onAccent)
                                .textSelection(.enabled)
                        } else {
                            MarkdownContentView(message.content)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: isUser ? nil : 620, alignment: .leading)
                    .background(
                        bubbleShape.fill(isUser
                            ? DesignSystem.Colors.accent
                            : DesignSystem.Colors.surfaceElevated)
                    )
                    .overlay(
                        bubbleShape.strokeBorder(
                            isUser
                                ? Color.white.opacity(0.12)
                                : DesignSystem.Colors.border.opacity(0.4),
                            lineWidth: 0.5
                        )
                    )
                    .shadow(color: .black.opacity(isUser ? 0.12 : 0.05), radius: isUser ? 3 : 2, y: 1)
                    .overlay(alignment: .bottomTrailing) {
                        if !isUser && !message.isStreaming && !message.content.isEmpty {
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
                                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.85))
                                            .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5))
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

            if !isUser { Spacer(minLength: 80) }
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
                tintColor: DesignSystem.Colors.accent,
                animate: false
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
        if cachedHasSpeakers {
            // Speaker-aware layout: use cached turns
            ForEach(Array(cachedTurns.enumerated()), id: \.element.segments.first?.startMs) { _, turn in
                transcriptTurnCard(
                    speakerLabel: turn.speakerLabel,
                    speakerColor: cachedSpeakerColorMap[turn.speakerId] ?? DesignSystem.Colors.textTertiary,
                    segments: turn.segments.map { ($0.startMs, $0.text) }
                )
                .id(turn.segments.first?.startMs ?? 0)
            }
        } else {
            // No speakers — use cached segments
            ForEach(Array(cachedSegments.enumerated()), id: \.element.startMs) { index, segment in
                let isActive = isSegmentActiveBinarySearch(segmentIndex: index)
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
                        .fill(isActive
                              ? DesignSystem.Colors.accent.opacity(0.12)
                              : DesignSystem.Colors.surfaceElevated.opacity(0.45))
                )
                .id(segment.startMs)
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
            // Collapsible header row
            HStack {
                Text("Speaker overview")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                if !speakerOverviewExpanded {
                    // Compact inline speaker dots when collapsed
                    HStack(spacing: 4) {
                        ForEach(speakers.prefix(6), id: \.id) { speaker in
                            Circle()
                                .fill(colorMap[speaker.id] ?? DesignSystem.Colors.textTertiary)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .rotationEffect(.degrees(speakerOverviewExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    speakerOverviewExpanded.toggle()
                }
            }

            if speakerOverviewExpanded {
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
            Text("Speaker labels are approximate. Click a name to rename.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            } // end if speakerOverviewExpanded
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

    private var isPlayerSeekable: Bool {
        playerViewModel.playerState == .ready
    }

    @ViewBuilder
    private func timestampChip(_ startMs: Int) -> some View {
        Text(formatTimestamp(ms: startMs))
            .font(DesignSystem.Typography.timestamp)
            .foregroundStyle(isPlayerSeekable ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surface)
            )
            .frame(width: 72, alignment: .leading)
            .contentShape(Capsule())
            .onTapGesture {
                if isPlayerSeekable {
                    playerViewModel.seek(toMs: startMs)
                    if !playerViewModel.isPlaying {
                        playerViewModel.togglePlayPause()
                    }
                    autoScrollPaused = false
                    scrollPauseTask?.cancel()
                }
            }
            .onHover { hovering in
                if isPlayerSeekable {
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
    }

    // MARK: - Segment Cache

    /// Rebuild cached segment data. Called once on appear and when transcription.id changes.
    private func rebuildSegmentCache() {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            cachedSegments = []
            cachedTurns = []
            cachedHasSpeakers = false
            cachedSpeakerColorMap = [:]
            cachedSegmentStartMs = []
            return
        }

        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        let hasSpeakers = words.contains { $0.speakerId != nil }

        cachedSegments = segments
        cachedHasSpeakers = hasSpeakers
        cachedSpeakerColorMap = buildSpeakerColorMap()
        cachedSegmentStartMs = segments.map(\.startMs)

        if hasSpeakers {
            cachedTurns = TranscriptSegmenter.groupIntoSpeakerTurns(segments: segments, speakerLabelProvider: speakerLabel(for:))
        } else {
            cachedTurns = []
        }
    }

    // MARK: - Binary Search Helpers

    /// Find the active segment index for the current playback time using binary search. O(log n).
    private func activeSegmentIndex(for currentMs: Int) -> Int? {
        guard !cachedSegmentStartMs.isEmpty else { return nil }

        // Binary search: find the last segment whose startMs <= currentMs
        var lo = 0
        var hi = cachedSegmentStartMs.count - 1
        var result = -1

        while lo <= hi {
            let mid = (lo + hi) / 2
            if cachedSegmentStartMs[mid] <= currentMs {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        return result >= 0 ? result : nil
    }

    /// Check if a segment at the given index is active (O(1) after binary search).
    private func isSegmentActiveBinarySearch(segmentIndex: Int) -> Bool {
        guard playerViewModel.playbackMode != .none else { return false }
        let currentMs = playerViewModel.currentTimeMs
        guard currentMs > 0 else { return false }
        guard let activeIdx = activeSegmentIndex(for: currentMs) else { return false }
        return activeIdx == segmentIndex
    }

    /// Find the scroll target ID (segment startMs) for the given playback time using binary search.
    private func autoScrollTarget(for currentMs: Int) -> Int? {
        if cachedHasSpeakers {
            // Find the last turn whose first segment starts at or before currentMs
            for turn in cachedTurns.reversed() {
                if let first = turn.segments.first, first.startMs <= currentMs {
                    return first.startMs
                }
            }
        } else {
            if let idx = activeSegmentIndex(for: currentMs) {
                return cachedSegmentStartMs[idx]
            }
        }
        return nil
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

    private func exportGenerationToDownloads(promptResult: PromptResult, format: ExportFormat) {
        let source = viewModel.currentTranscription ?? transcription
        let baseStem = TranscriptSegmenter.sanitizedExportStem(from: source.fileName)
        
        let promptNameSafe = promptResult.promptName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            
        let stem = "\(baseStem)-\(promptNameSafe)"
        
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            exportErrorMessage = "Your Downloads folder could not be found."
            SoundManager.shared.play(.errorSoft)
            return
        }
        
        var fileURL = downloadsURL.appendingPathComponent("\(stem).\(format.rawValue)")

        // Avoid overwriting
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = downloadsURL.appendingPathComponent("\(stem) (\(counter)).\(format.rawValue)")
            counter += 1
        }

        do {
            try promptResult.content.write(to: fileURL, atomically: true, encoding: .utf8)
            Telemetry.send(.exportUsed(format: format.rawValue))
        } catch {
            exportErrorMessage = error.localizedDescription
            SoundManager.shared.play(.errorSoft)
            return
        }

        exportErrorMessage = nil
        SoundManager.shared.play(.transcriptionComplete)

        dismissTask?.cancel()
        exportConfirmation = ExportConfirmation(url: fileURL, format: format.rawValue)

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.0))
            guard !Task.isCancelled else { return }
            exportConfirmation = nil
        }
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
