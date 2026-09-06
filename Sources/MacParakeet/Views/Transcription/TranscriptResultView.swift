import AVKit
import AppKit
import Observation
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// One searchable unit of the transcript reading surface (U2): a renderable
/// text block plus its rendering context. Effective timed mode uses the stable
/// editable-segment identity, so split segments and equal timestamps remain
/// distinct. Legacy timed/text surfaces retain their integer scroll anchors.
private enum TranscriptFindBlockID: Hashable {
    case effective(SpeakerEditableSegmentID)
    case legacy(Int)
    case text
}

private struct TranscriptFindBlock: Equatable, Identifiable {
    let id: TranscriptFindBlockID
    let text: String
}

/// Invisible scroll target inside the full-text transcript. Text mode keeps one
/// selectable `Text` for the transcript body, then overlays a single prefix
/// target for the active match so find navigation can still land near it.
private struct TranscriptTextFindAnchor: Equatable, Identifiable {
    let id: Int
    let prefixText: String
}

/// Data-driven model for the export confirmation popover.
/// Using a single `Identifiable` value with `.popover(item:)` ensures
/// the popover content always has the correct URL and format — no race
/// between separate presentation and data states.
private struct ExportConfirmation: Identifiable {
    let id = UUID()
    let url: URL
    /// Full heading shown in the confirmation popover, e.g.
    /// "Exported Markdown" or "Saved Audio". The popover renders this
    /// verbatim so callers control the verb-noun phrasing.
    let title: String
}

private struct RetranscriptionConfirmation: Identifiable {
    let id = UUID()
    let transcriptionID: UUID
    let speechEngineOverride: SpeechEngineSelection?
    let speakerSelection: RetranscriptionSpeakerSelection?
    let countsOtherSpeakers: Bool
    let resetsSpeakerCorrections: Bool

    var title: String {
        if let speechEngineOverride {
            "Try with \(speechEngineOverride.engine.displayName)?"
        } else {
            "Retranscribe this file?"
        }
    }

    var confirmLabel: String {
        if let speechEngineOverride {
            "Try with \(speechEngineOverride.engine.displayName)"
        } else {
            "Retranscribe"
        }
    }

    var message: String {
        let speakerSummary: String
        let speakerNoun = countsOtherSpeakers ? "Other speakers" : "Speakers"
        switch speakerSelection {
        case .automatic:
            speakerSummary = "\(speakerNoun): Auto. "
        case .exact(let count):
            speakerSummary = "\(speakerNoun): Exact \(count). "
        case nil:
            speakerSummary = ""
        }
        let correctionWarning = resetsSpeakerCorrections
            ? "Your manual speaker corrections will be reset. " : ""
        return speakerSummary + correctionWarning
            + "Replaces this transcript. Prompts and chats are preserved."
    }
}

private enum TranscriptDisplayMode: String, CaseIterable, Hashable {
    case text = "Text"
    case timed = "Timed"
}

/// Owns the one rich-context preparation pipeline shared by chat and prompt
/// actions. Formatting always runs in a detached task; equal requests coalesce
/// and reuse their result, while a new revision or mode invalidates old work.
@MainActor
@Observable
final class TranscriptRichContextLoader {
    typealias Builder = @Sendable (Transcription, TranscriptAIContextMode) async -> String

    struct Request: Equatable, Sendable {
        let transcriptionID: UUID
        let contentRevision: UInt64
        // nil identifies the automatic snapshot while persisted attribution is loading.
        let speakerCorrectionRevision: Int?
        let mode: TranscriptAIContextMode
    }

    struct Prepared: Equatable, Sendable {
        let request: Request
        let text: String
    }

    private let builder: Builder
    private var generation: UInt64 = 0
    private var task: Task<String, Never>?
    private var taskRequest: Request?
    private var cached: Prepared?
    private var latestScheduledApplyID: UUID?
    private var latestPromptActionID: UUID?

    var preparingPromptContext: Bool { latestPromptActionID != nil }

    init(
        builder: @escaping Builder = { transcription, mode in
            TranscriptAIContextFormatter.format(transcription: transcription, mode: mode)
        }
    ) {
        self.builder = builder
    }

    /// Returns context only when this request is still the loader's newest
    /// request. The caller must additionally compare the returned revision to
    /// its live model immediately before submitting an external request.
    func prepare(
        transcription: Transcription,
        mode: TranscriptAIContextMode,
        contentRevision: UInt64,
        speakerCorrectionRevision: Int? = nil,
        isCurrent: @escaping @MainActor (Request) -> Bool = { _ in true }
    ) async -> Prepared? {
        let request = Request(
            transcriptionID: transcription.id,
            contentRevision: contentRevision,
            speakerCorrectionRevision: speakerCorrectionRevision,
            mode: mode
        )
        if let cached, cached.request == request {
            return isCurrent(request) ? cached : nil
        }

        if taskRequest != request || task == nil {
            invalidatePreparedWork()
            let builder = builder
            taskRequest = request
            task = Task.detached(priority: .userInitiated) {
                await builder(transcription, mode)
            }
        }

        guard let task else { return nil }
        let requestGeneration = generation
        let text = await task.value
        let isLatestRequest = generation == requestGeneration
        if isLatestRequest {
            self.task = nil
            taskRequest = nil
        }
        guard !Task.isCancelled,
            isLatestRequest,
            isCurrent(request)
        else {
            return nil
        }

        let prepared = Prepared(request: request, text: text)
        cached = prepared
        return prepared
    }

    @discardableResult
    func schedule(
        transcription: Transcription,
        mode: TranscriptAIContextMode,
        contentRevision: UInt64,
        speakerCorrectionRevision: Int? = nil,
        apply: @escaping @MainActor (Request, String) -> Void
    ) -> Task<Void, Never> {
        let applyID = UUID()
        latestScheduledApplyID = applyID
        return Task { [weak self] in
            guard let self,
                let prepared = await self.prepare(
                    transcription: transcription,
                    mode: mode,
                    contentRevision: contentRevision,
                    speakerCorrectionRevision: speakerCorrectionRevision
                ),
                !Task.isCancelled,
                self.latestScheduledApplyID == applyID
            else { return }
            apply(prepared.request, prepared.text)
        }
    }

    /// Owns submission separately from shared formatting so navigation can
    /// release the action without waiting for a cancelled detached builder.
    @discardableResult
    func startPromptAction(
        transcription: Transcription,
        mode: TranscriptAIContextMode,
        contentRevision: UInt64,
        speakerCorrectionRevision: Int? = nil,
        isCurrent: @escaping @MainActor (Request) -> Bool = { _ in true },
        onStale: @escaping @MainActor () -> Void,
        action: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never>? {
        guard !preparingPromptContext else { return nil }
        let actionID = UUID()
        latestPromptActionID = actionID
        return Task { [weak self] in
            guard let self, self.latestPromptActionID == actionID else { return }
            defer {
                if self.latestPromptActionID == actionID {
                    self.latestPromptActionID = nil
                }
            }
            let prepared = await self.prepare(
                transcription: transcription,
                mode: mode,
                contentRevision: contentRevision,
                speakerCorrectionRevision: speakerCorrectionRevision,
                isCurrent: isCurrent
            )
            guard !Task.isCancelled, self.latestPromptActionID == actionID else { return }
            guard let prepared, isCurrent(prepared.request) else {
                onStale()
                return
            }
            action(prepared.text)
        }
    }

    func invalidate() {
        latestPromptActionID = nil
        latestScheduledApplyID = nil
        invalidatePreparedWork()
    }

    private func invalidatePreparedWork() {
        generation &+= 1
        task?.cancel()
        task = nil
        taskRequest = nil
        cached = nil
    }
}

enum TranscriptResultTabOrdering {
    static func leadingTabs(
        for sourceType: Transcription.SourceType
    ) -> [TranscriptionViewModel.TranscriptTab] {
        sourceType == .meeting ? [.transcript, .notes] : [.transcript]
    }
}

private enum MeetingNotesNavigationAction {
    case navigateBack
    case startNewTranscription
}

/// Keeps a user action tied to the selection that initiated its notes flush.
/// Cancelling the action does not cancel the independently owned draft save.
@MainActor
@Observable
final class TranscriptNotesActionGate {
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    var isRunning: Bool { requestID != nil }

    @discardableResult
    func start(
        flush: @escaping @MainActor () async -> Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        onFailure: @escaping @MainActor () -> Void = {},
        action: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard !isRunning, isCurrent() else { return nil }
        let id = UUID()
        requestID = id
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self, self.requestID == id else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.task = nil
                }
            }
            let saved = await flush()
            guard !Task.isCancelled,
                self.requestID == id, isCurrent()
            else { return }
            guard saved else {
                onFailure()
                return
            }
            await action()
        }
        self.task = task
        return task
    }

    func invalidate() {
        requestID = nil
        task?.cancel()
        task = nil
    }
}

/// Records the user's engine choice from the retranscribe popover so the
/// confirmation alert can be presented in a *separate* render cycle from
/// the popover dismissal — chaining popover → alert in the same cycle on
/// macOS reliably drops the alert. The single `override` field carries
/// nil when the user picked the primary engine (no override needed) and
/// `.some` when they picked the alternative.
private struct RetranscribePick: Sendable {
    let transcriptionID: UUID
    let override: SpeechEngineSelection?
    let speakerSelection: RetranscriptionSpeakerSelection?
    let countsOtherSpeakers: Bool
}

struct MeetingTimedTranscriptRecoveryBannerPresentation: Equatable {
    struct Action: Equatable {
        let title: String
        let selection: SpeechEngineSelection
    }

    let title: String
    let message: String
    let action: Action?

    static func make(
        transcriptText: String,
        hasRetainedAudio: Bool,
        timestampCapableRerun: SpeechEngineSelection?
    ) -> MeetingTimedTranscriptRecoveryBannerPresentation? {
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let baseMessage =
            "This meeting has transcript text but no word timestamps, so timed playback, segments, and speaker labels are unavailable."
        if let timestampCapableRerun {
            return MeetingTimedTranscriptRecoveryBannerPresentation(
                title: "No timed transcript",
                message:
                    "\(baseMessage) Rerun with \(timestampCapableRerun.engine.displayName) to try adding timestamps. Speaker labels depend on the captured audio and may be approximate.",
                action: Action(
                    title: "Try timed retranscription",
                    selection: timestampCapableRerun
                )
            )
        }

        if hasRetainedAudio {
            return MeetingTimedTranscriptRecoveryBannerPresentation(
                title: "No timed transcript",
                message:
                    "\(baseMessage) A timestamp-capable engine would be needed to try adding timestamps, but none is available right now.",
                action: nil
            )
        }

        return MeetingTimedTranscriptRecoveryBannerPresentation(
            title: "No timed transcript",
            message:
                "\(baseMessage) Saved audio is no longer available, so MacParakeet cannot rerun the meeting to try adding timestamps.",
            action: nil
        )
    }
}

struct MeetingTranscriptProcessingPresentation: Equatable {
    let title: String
    let message: String

    static func make(
        sourceType: Transcription.SourceType,
        status: Transcription.TranscriptionStatus
    ) -> MeetingTranscriptProcessingPresentation? {
        guard sourceType == .meeting,
            status == .processing
        else {
            return nil
        }
        return MeetingTranscriptProcessingPresentation(
            title: "Transcribing meeting",
            message:
                "Your audio is saved. Final transcription is continuing in the background. You can leave this page and return later."
        )
    }
}

enum TranscriptDetailActionAvailability {
    static func canEdit(
        status: Transcription.TranscriptionStatus
    ) -> Bool {
        status != .processing
    }

    static func canRetranscribe(
        hasRetainedAudio: Bool,
        status: Transcription.TranscriptionStatus
    ) -> Bool {
        hasRetainedAudio && status != .processing
    }
}

struct TranscriptResultView: View {
    let transcription: Transcription
    @Bindable var viewModel: TranscriptionViewModel
    var chatViewModel: TranscriptChatViewModel
    @Bindable var promptResultsViewModel: PromptResultsViewModel
    @Bindable var promptsViewModel: PromptsViewModel
    var onBack: (() -> Void)?
    var onStartNew: (() -> Void)?
    var onRetranscribe: ((Transcription, SpeechEngineSelection?, RetranscriptionSpeakerSelection?) -> Void)?
    var onSetUpAI: (() -> Void)?

    @AppStorage(UserDefaultsAppRuntimePreferences.transcriptAIContextModeKey)
    private var transcriptAIContextModeRaw = TranscriptAIContextMode.richTranscript.rawValue

    @State private var backHovered = false
    @State private var headerExpanded = false
    @State private var speakerOverviewExpanded = true
    @State private var copied = false
    @State private var copiedResultID: UUID?
    @State private var copiedButtonResultID: UUID?
    @State private var copiedMessageId: UUID?
    @State private var hoveredMessageId: UUID?
    @State private var exportConfirmation: ExportConfirmation?
    @State private var exportErrorMessage: String?
    @State private var showingExportOptions = false
    @State private var selectedExportFormat: TranscriptExportFormat = .txt
    @State private var transcriptExportOptions = TranscriptExportOptions.default
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var resultCopiedResetTask: Task<Void, Never>?
    @State private var resultButtonCopiedResetTask: Task<Void, Never>?
    @State private var notesCopied = false
    @State private var notesCopiedResetTask: Task<Void, Never>?
    @State private var savedMeetingNotesViewModel = SavedMeetingNotesViewModel()
    @State private var dismissTask: Task<Void, Never>?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var editingTranscript = false
    @State private var transcriptDraft = ""
    @State private var transcriptEditError: String?
    @State private var transcriptDisplayMode: TranscriptDisplayMode = .text
    @State private var transcriptDisplayModeBeforeEdit: TranscriptDisplayMode?
    /// User-adjustable transcript reading size (Transcript Detail Refresh / U4).
    /// Persisted; applies to both the Text and Timed reading surfaces.
    @AppStorage(UserDefaultsAppRuntimePreferences.transcriptFontScaleKey)
    private var transcriptFontScale: Double = 1.0
    private static let transcriptFontScaleRange: ClosedRange<Double> = 0.85...1.4
    private static let transcriptFontScaleStep: Double = 0.1
    private static let textFindAnchorBaseID = -1_000_000
    // In-transcript find (Transcript Detail Refresh / U2). The matcher is the
    // testable `TranscriptFindModel`; this view owns the bar's visibility, the
    // ordered blocks fed to the model, and the scroll wiring.
    @State private var findModel = TranscriptFindModel()
    @State private var findBarVisible = false
    @State private var findBlocks: [TranscriptFindBlock] = []
    /// Bumped on every keystroke / navigation so the in-reader `onChange` can
    /// re-aim `scrollTo` at the current match (even when the cursor index is
    /// unchanged but the matched block moved).
    @State private var findScrollToken = 0
    /// True once find-navigation has taken over the auto-scroll pause, so closing
    /// the bar resumes playback-follow — without clobbering an unrelated
    /// manual-scroll pause when find never navigated.
    @State private var findPausedAutoScroll = false
    @State private var editingSpeakerId: String?
    @State private var editingSpeakerContextID: String?
    @State private var editingSpeakerLabel: String = ""
    @State private var editingSpeakers = false
    @State private var speakerSelection = SpeakerEditSelectionModel()
    @State private var showingNewSpeakerPrompt = false
    @State private var newSpeakerLabel = ""
    @State private var pendingNewSpeakerSegments: [SpeakerEditableSegment] = []
    @State private var pendingSplitSegment: SpeakerEditableSegment?
    @State private var pendingSplitWordIndex = 0
    @State private var showConversationPopover = false
    @State private var hoveredConversationId: UUID?
    @State private var playerViewModel = MediaPlayerViewModel()
    @State private var showVideoPanel = false
    @State private var lastScrolledSegmentMs: Int = -1
    @State private var lastScrolledEffectiveSegmentID: SpeakerEditableSegmentID?
    // Cached transcript data — recomputed only when transcription.id changes, not on every playback tick
    @State private var cachedSegments: [TranscriptSegment] = []
    /// Total timed rows (cards' segments or flat segments); drives the lazy/non-lazy choice.
    /// `nil` means the detached cache build is still pending, which must use
    /// the conservative lazy layout so a large first-open never renders eagerly.
    @State private var cachedTranscriptRowCount: Int?
    @State private var cachedIdentifiedTurnCards: [IdentifiedSpeakerTurn] = []
    @State private var cachedHasSpeakers: Bool = false
    @State private var cachedSpeakerColorMap: [String: Color] = [:]
    @State private var cachedSpeakerLabelMap: [String: String] = [:]
    @State private var cachedSegmentStartMs: [Int] = []  // sorted, for binary search
    @State private var cachedSpeakerStats: [String: SpeakerStatistics] = [:]
    @State private var segmentCacheRequestID = UUID()
    @State private var richContextLoader = TranscriptRichContextLoader()
    @State private var promptNotesActionGate = TranscriptNotesActionGate()
    @State private var chatNotesActionGate = TranscriptNotesActionGate()
    @State private var navigationNotesActionGate = TranscriptNotesActionGate()
    @State private var autoScrollPaused = false
    @State private var scrollPauseTask: Task<Void, Never>?
    @State private var scrollMonitor: Any?
    @State private var showPromptLibrary = false
    @State private var showGeneratePopover = false
    @State private var retranscriptionConfirmation: RetranscriptionConfirmation?
    @State private var showingRetranscribeOptions = false
    @State private var pendingRetranscribePick: RetranscribePick?
    @State private var retranscriptionUsesExactSpeakerCount = false
    @State private var retranscriptionExactSpeakerCount = 2
    @State private var selectedRetranscriptionSpeechEngineOverride: SpeechEngineSelection?
    @State private var pendingDeleteMeetingAudio = false
    @State private var showingCancelGenerationAlert: UUID?
    @FocusState private var chatInputFocused: Bool
    @FocusState private var titleFocused: Bool
    @FocusState private var transcriptEditorFocused: Bool
    @FocusState private var meetingNotesEditorFocused: Bool
    @FocusState private var speakerRenameFocused: Bool
    @FocusState private var findFieldFocused: Bool

    private let suggestedPrompts = [
        "Summarize the key points",
        "What are the main takeaways?",
        "List any action items mentioned",
    ]

    var body: some View {
        presentationContent
    }

    private var transcriptObservationContent: some View {
        adaptiveLayout
            .onAppear(perform: handleAppear)
            .onChange(of: transcription.id) {
                handleTranscriptionChange()
            }
            .onChange(of: activeTranscription.speakers) {
                if transcriptDisplayMode == .timed {
                    scheduleSegmentCacheRebuild()
                }
                if findBarVisible { rebuildFindBlocks() }
            }
            .onChange(of: activeTranscription.wordTimestamps) {
                if transcriptDisplayMode == .timed {
                    scheduleSegmentCacheRebuild()
                }
                if findBarVisible { rebuildFindBlocks() }
            }
            .onChange(of: activeTranscription.diarizationSegments) {
                if transcriptDisplayMode == .timed {
                    scheduleSegmentCacheRebuild()
                }
                if findBarVisible { rebuildFindBlocks() }
            }
    }

    private var contextObservationContent: some View {
        transcriptObservationContent
            .onChange(of: viewModel.speakerAttribution?.correctionRevision) {
                let ids = viewModel.speakerAttribution?.editableSegments.map(\.id) ?? []
                speakerSelection.reconcile(with: ids)
                if transcriptDisplayMode == .timed {
                    scheduleSegmentCacheRebuild()
                }
                if findBarVisible { rebuildFindBlocks() }
                scheduleRichAIContextLoad()
            }
            .onChange(of: transcriptText) {
                if findBarVisible { rebuildFindBlocks() }
            }
            .onChange(of: viewModel.currentTranscriptionRevision) {
                guard viewModel.currentTranscription?.id == transcription.id else {
                    richContextLoader.invalidate()
                    return
                }
                chatViewModel.updateTranscriptText(transcriptText)
                scheduleRichAIContextLoad()
            }
            .onChange(of: transcriptAIContextModeRaw) {
                scheduleRichAIContextLoad()
            }
            .onChange(of: viewModel.selectedTab) {
                if case .result(let id) = viewModel.selectedTab {
                    promptResultsViewModel.markPromptResultViewed(id)
                }
            }
            .onDisappear(perform: handleDisappear)
    }

    private var presentationContent: some View {
        contextObservationContent
            .sheet(
                isPresented: $showPromptLibrary,
                onDismiss: {
                    promptsViewModel.loadPrompts()
                    promptResultsViewModel.loadVisiblePrompts()
                }
            ) {
                PromptLibraryView(viewModel: promptsViewModel)
            }
            .alert("New speaker", isPresented: $showingNewSpeakerPrompt) {
                TextField("Speaker name", text: $newSpeakerLabel)
                Button("Cancel", role: .cancel) {
                    pendingNewSpeakerSegments = []
                }
                Button("Add") {
                    createPendingSpeaker()
                }
                .disabled(newSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text(pendingNewSpeakerSegments.isEmpty
                     ? "Add a speaker to this transcript."
                     : "Add a speaker and assign the selected segments.")
            }
            .sheet(item: $pendingSplitSegment) { segment in
                speakerSplitSheet(segment)
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

    private func handleAppear() {
        configureSavedMeetingNotes(for: activeTranscription)
        // Lazy migration for existing webm/opus YouTube audio files saved
        // before issue #237's playback fix shipped.
        playerViewModel.onPlaybackFilePathConverted = { [viewModel] id, newPath, sourcePath in
            try viewModel.applyConvertedPlaybackPath(
                transcriptionID: id,
                newFilePath: newPath,
                sourceFileToCleanup: sourcePath
            )
        }
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
        syncTranscriptDisplayMode()
        if transcriptDisplayMode == .timed {
            scheduleSegmentCacheRebuild()
        }
        viewModel.loadPersistedContent()
        promptResultsViewModel.loadVisiblePrompts()
        promptResultsViewModel.loadPromptResults(transcriptionId: transcription.id)
        chatViewModel.loadTranscript(transcriptText, transcriptionId: viewModel.currentTranscription?.id)
        scheduleRichAIContextLoad()
        // Re-evaluate typed meeting notes on every send so external CLI edits
        // are visible without reloading the transcript.
        chatViewModel.bindUserNotesProvider { [viewModel] in
            viewModel.currentTranscription?.userNotes
        }
    }

    private func handleTranscriptionChange() {
        navigationNotesActionGate.invalidate()
        promptNotesActionGate.invalidate()
        chatNotesActionGate.invalidate()
        richContextLoader.invalidate()
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
        headerExpanded = false
        speakerOverviewExpanded = true
        editingTitle = false
        titleDraft = ""
        editingTranscript = false
        transcriptDraft = ""
        transcriptEditError = nil
        configureSavedMeetingNotes(for: activeTranscription)
        transcriptDisplayModeBeforeEdit = nil
        editingSpeakerId = nil
        editingSpeakerLabel = ""
        editingSpeakers = false
        speakerSelection.clear()
        showConversationPopover = false
        hoveredConversationId = nil
        lastScrolledSegmentMs = -1
        lastScrolledEffectiveSegmentID = nil
        autoScrollPaused = false
        scrollPauseTask?.cancel()
        findBarVisible = false
        findFieldFocused = false
        findModel.clear()
        findBlocks = []
        findPausedAutoScroll = false
        viewModel.hasConversations = false
        viewModel.selectedTab = .transcript
        viewModel.loadPersistedContent()
        syncTranscriptDisplayMode()
        if transcriptDisplayMode == .timed {
            scheduleSegmentCacheRebuild()
        } else {
            applyEmptySegmentCache()
        }
        promptResultsViewModel.loadPromptResults(transcriptionId: transcription.id)
        chatViewModel.loadTranscript(transcriptText, transcriptionId: viewModel.currentTranscription?.id)
        scheduleRichAIContextLoad()
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
            copyAction

            Button {
                showingExportOptions.toggle()
            } label: {
                Label("Export", systemImage: "arrow.down.doc")
            }
            .parakeetAction(.secondary)
            .popover(isPresented: $showingExportOptions, arrowEdge: .top) {
                exportOptionsPopover
            }

            if activeTranscription.sourceType == .meeting {
                let audioState = MeetingAudioFile.state(for: activeTranscription)
                let audioAvailable = audioState == .saved
                let audioRemovable = MeetingAudioFile.isRemovable(for: activeTranscription, state: audioState)
                Menu {
                    Button {
                        MeetingAudioActions.revealInFinder(activeTranscription)
                    } label: {
                        Label("Show Audio in Finder", systemImage: "waveform")
                    }
                    Button {
                        saveMeetingAudioFromActionBar()
                    } label: {
                        Label("Save Audio As…", systemImage: "square.and.arrow.down")
                    }

                    Divider()

                    Button(role: .destructive) {
                        pendingDeleteMeetingAudio = true
                    } label: {
                        Label(MeetingDeletionCopy.audioOnlyMenuTitle, systemImage: "waveform.slash")
                    }
                    .disabled(!audioRemovable)
                    .help(
                        audioRemovable
                            ? "Remove the saved meeting audio while keeping the meeting"
                            : MeetingDeletionCopy.audioRemovalUnavailableHelp(
                                for: activeTranscription,
                                state: audioState
                            ))
                } label: {
                    Label("Audio", systemImage: "waveform")
                }
                .parakeetAction(.secondary)
                .disabled(!audioAvailable)
                .help(
                    audioAvailable
                        ? "Reveal or save the meeting audio file"
                        : MeetingDeletionCopy.audioUnavailableHelp(for: audioState))

                let artifactAvailable = MeetingArtifactActions.folderURL(for: activeTranscription) != nil
                Menu {
                    Button {
                        MeetingArtifactActions.openFolder(for: activeTranscription)
                    } label: {
                        Label("Open Meeting Folder", systemImage: "folder")
                    }

                    Button {
                        MeetingArtifactActions.copyFolderPath(for: activeTranscription)
                    } label: {
                        Label("Copy Artifact Folder Path", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("Artifacts", systemImage: "folder")
                }
                .parakeetAction(.secondary)
                .disabled(!artifactAvailable)
                .help(
                    artifactAvailable
                        ? "Open or copy the meeting artifact folder path"
                        : "Meeting artifact folder is not available")
            }

            if onRetranscribe != nil, let filePath = activeTranscription.filePath,
                TranscriptDetailActionAvailability.canRetranscribe(
                    hasRetainedAudio: FileManager.default.fileExists(atPath: filePath),
                    status: activeTranscription.status
                )
            {
                let engineOption = viewModel.retranscriptionEngineOption(for: activeTranscription)
                let canConfigureSpeakers = viewModel.canConfigureSpeakersForRetranscription(activeTranscription)
                Button {
                    if engineOption != nil || canConfigureSpeakers {
                        selectedRetranscriptionSpeechEngineOverride = nil
                        retranscriptionExactSpeakerCount = min(
                            max(defaultRetranscriptionSpeakerCount, RetranscriptionSpeakerSelection.supportedExactCount.lowerBound),
                            RetranscriptionSpeakerSelection.supportedExactCount.upperBound
                        )
                        showingRetranscribeOptions.toggle()
                    } else {
                        retranscriptionConfirmation = RetranscriptionConfirmation(
                            transcriptionID: activeTranscription.id,
                            speechEngineOverride: nil,
                            speakerSelection: nil,
                            countsOtherSpeakers: false,
                            resetsSpeakerCorrections: viewModel.speakerCorrectionsApplied
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                        Text("Retranscribe")
                        if engineOption != nil {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }
                .parakeetAction(.secondary)
                .help(engineOption != nil ? "Choose a speech engine for this rerun" : "Retranscribe this file")
                .popover(isPresented: $showingRetranscribeOptions, arrowEdge: .top) {
                    retranscribeOptionsPopover(
                        for: engineOption,
                        canConfigureSpeakers: canConfigureSpeakers
                    )
                }
            }

            Spacer()

            if onStartNew != nil {
                Button {
                    requestMeetingNotesNavigation(.startNewTranscription)
                } label: {
                    Label("New Transcription", systemImage: "plus")
                }
                .parakeetAction(.primary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .onChange(of: showingRetranscribeOptions) { _, isOpen in
            // Picker → alert handoff: the picker popover stores the user's
            // choice in `pendingRetranscribePick` then closes itself. We hop
            // through Task { @MainActor } so the popover-dismiss render
            // cycle finishes before the alert tries to present — without the
            // hop, SwiftUI on macOS reliably drops the alert.
            guard !isOpen, let pick = pendingRetranscribePick else { return }
            pendingRetranscribePick = nil
            Task { @MainActor in
                retranscriptionConfirmation = RetranscriptionConfirmation(
                    transcriptionID: pick.transcriptionID,
                    speechEngineOverride: pick.override,
                    speakerSelection: pick.speakerSelection,
                    countsOtherSpeakers: pick.countsOtherSpeakers,
                    resetsSpeakerCorrections: viewModel.speakerCorrectionsApplied
                )
            }
        }
        .onChange(of: transcription.id) {
            pendingRetranscribePick = nil
            retranscriptionConfirmation = nil
            showingRetranscribeOptions = false
        }
        .alert(
            retranscriptionConfirmation?.title ?? "Retranscribe this file?",
            isPresented: isRetranscriptionConfirmationPresented,
            presenting: retranscriptionConfirmation
        ) { confirmation in
            Button(confirmation.confirmLabel, role: .destructive) {
                guard confirmation.transcriptionID == transcription.id else { return }
                onRetranscribe?(
                    activeTranscription,
                    confirmation.speechEngineOverride,
                    confirmation.speakerSelection
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert(MeetingDeletionCopy.audioOnlyAlertTitle, isPresented: $pendingDeleteMeetingAudio) {
            Button("Cancel", role: .cancel) {}
            Button(MeetingDeletionCopy.audioOnlyConfirmTitle, role: .destructive) {
                deleteMeetingAudioFromActionBar()
            }
        } message: {
            Text(
                MeetingDeletionCopy.singleAudioOnlyMessage(
                    surface: .library,
                    status: activeTranscription.status
                )
            )
        }
        .popover(item: $exportConfirmation, arrowEdge: .top) { confirmation in
            exportConfirmationPopover(confirmation)
        }
    }

    @ViewBuilder
    private var copyAction: some View {
        if activeTranscription.sourceType == .meeting {
            Menu {
                Button {
                    copyTranscriptToClipboard()
                } label: {
                    Label("Copy Transcript", systemImage: "doc.plaintext")
                }
            } label: {
                copyActionLabel(title: copied ? "Copied!" : "Copy Meeting")
            } primaryAction: {
                copyMeetingToClipboard()
            }
            .parakeetAction(.secondary)
            .help("Copy the meeting title, notes, and transcript. Use the menu to copy only the transcript.")
            .accessibilityLabel("Copy meeting")
            .accessibilityValue(copied ? "Copied" : "")
        } else {
            Button {
                copyTranscriptToClipboard()
            } label: {
                copyActionLabel(title: copied ? "Copied!" : "Copy")
            }
            .parakeetAction(.secondary)
        }
    }

    private func copyActionLabel(title: String) -> some View {
        Label(
            title,
            systemImage: copied ? "checkmark" : "doc.on.clipboard"
        )
        .foregroundStyle(copied ? DesignSystem.Colors.successGreen : .primary)
    }

    private var isRetranscriptionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { retranscriptionConfirmation?.transcriptionID == transcription.id },
            set: { isPresented in
                if !isPresented {
                    retranscriptionConfirmation = nil
                }
            }
        )
    }

    private func retranscribeOptionsPopover(
        for option: TranscriptionViewModel.RetranscriptionEngineOption?,
        canConfigureSpeakers: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Retranscribe with", systemImage: "arrow.trianglehead.2.clockwise")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer(minLength: 8)

                Button {
                    showingRetranscribeOptions = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close retranscribe options")
            }

            if let option {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(option.choices) { choice in
                        EngineOptionCard(
                            selection: choice.selection,
                            nemotronVariant: option.nemotronVariant,
                            parakeetVariant: option.parakeetVariant,
                            isPrimary: choice.isPrimary,
                            primaryReflectsTranscriptEngine: option.primaryReflectsTranscriptEngine,
                            isAvailable: choice.isAvailable,
                            unavailableReason: choice.unavailableReason,
                            advisory: choice.advisory
                        ) {
                            selectRetranscribeEngine(
                                choice,
                                reflectsTranscriptEngine: option.primaryReflectsTranscriptEngine
                            )
                        }
                    }
                }
            }

            if canConfigureSpeakers {
                Divider()
                retranscriptionSpeakerOptions
            }

            Button("Continue") {
                pendingRetranscribePick = RetranscribePick(
                    transcriptionID: transcription.id,
                    override: selectedRetranscriptionSpeechEngineOverride,
                    speakerSelection: canConfigureSpeakers
                        ? selectedRetranscriptionSpeakerSelection
                        : nil,
                    countsOtherSpeakers: activeTranscription.sourceType == .meeting
                )
                showingRetranscribeOptions = false
            }
            .parakeetAction(.primary)

            Text("Replaces this transcript. Prompts and chats are preserved.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 390)
    }

    private var retranscriptionSpeakerOptions: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(activeTranscription.sourceType == .meeting ? "Other speakers" : "Speakers")
                .font(DesignSystem.Typography.body.weight(.semibold))

            Picker("Speaker count", selection: $retranscriptionUsesExactSpeakerCount) {
                Text("Auto").tag(false)
                Text("Exact").tag(true)
            }
            .pickerStyle(.segmented)

            if retranscriptionUsesExactSpeakerCount {
                Stepper(
                    value: $retranscriptionExactSpeakerCount,
                    in: RetranscriptionSpeakerSelection.supportedExactCount
                ) {
                    Text("Exact: \(retranscriptionExactSpeakerCount)")
                }
                Text("The diarizer may return fewer speakers when the audio does not contain enough distinct speech.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedRetranscriptionSpeakerSelection: RetranscriptionSpeakerSelection {
        retranscriptionUsesExactSpeakerCount
            ? .exact(retranscriptionExactSpeakerCount)
            : .automatic
    }

    private func selectRetranscribeEngine(
        _ choice: TranscriptionViewModel.RetranscriptionEngineOption.Choice,
        reflectsTranscriptEngine: Bool
    ) {
        // Pin the engine named on the card whenever it is a specific choice — an
        // alternative engine, or the engine that actually produced this
        // transcript. Only the legacy "Current" primary (a fall-back to the
        // user's Final Transcription default) reruns through the plain
        // current-settings path, so its variant and language follow whatever
        // the user has set now.
        let override: SpeechEngineSelection? =
            (choice.isPrimary && !reflectsTranscriptEngine) ? nil : choice.selection
        selectedRetranscriptionSpeechEngineOverride = override
    }

    private var activeTranscription: Transcription {
        guard let current = viewModel.effectiveCurrentTranscription, current.id == transcription.id else {
            return transcription
        }
        return current
    }

    private var transcriptText: String {
        activeTranscription.cleanTranscript ?? activeTranscription.rawTranscript ?? ""
    }

    private var currentAIContextMode: TranscriptAIContextMode {
        TranscriptAIContextMode(rawValue: transcriptAIContextModeRaw) ?? .richTranscript
    }

    /// Captures one immutable revision before leaving the main actor, then
    /// verifies that same revision and context mode immediately before use.
    /// A formatter completion from an edited/reverted/switched transcript is
    /// therefore never eligible for an AI request.
    private func startPromptContextAction(
        _ action: @escaping @MainActor (String) -> Void
    ) {
        let selectedID = activeTranscription.id
        let notesEditor = savedMeetingNotesViewModel
        promptNotesActionGate.start(
            flush: {
                guard await notesEditor.flush() else { return false }
                return await viewModel.waitForCurrentSpeakerAttribution()
            },
            isCurrent: {
                viewModel.currentTranscription?.id == selectedID
                    && savedMeetingNotesViewModel === notesEditor
                    && notesEditor.saveState != .deleted
            }
        ) {
            // Persisting notes publishes a new transcription revision. Capture
            // the immutable context only after that intentional update.
            let transcription = activeTranscription
            let mode = currentAIContextMode
            let revision = viewModel.currentTranscriptionRevision
            let preparation = richContextLoader.startPromptAction(
                transcription: transcription,
                mode: mode,
                contentRevision: revision,
                speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision,
                isCurrent: { request in
                    viewModel.currentTranscriptionRevision == request.contentRevision
                        && viewModel.speakerAttribution?.correctionRevision == request.speakerCorrectionRevision
                        && viewModel.currentTranscription?.id == request.transcriptionID
                        && currentAIContextMode == request.mode
                },
                onStale: {
                    guard viewModel.currentTranscription?.id == transcription.id else { return }
                    promptResultsViewModel.errorMessage =
                        "The transcript or AI context changed while preparing this prompt. Please try again."
                },
                action: action
            )
            if let preparation {
                promptResultsViewModel.errorMessage = nil
                await preparation.value
            }
        }
    }

    private var rawTranscriptText: String {
        activeTranscription.rawTranscript ?? ""
    }

    private var hasEditedTranscript: Bool {
        activeTranscription.isTranscriptEdited && hasCleanTranscriptText
    }

    private var hasCleanTranscriptText: Bool {
        guard let clean = activeTranscription.cleanTranscript else { return false }
        return !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var transcriptWordCount: Int {
        if !hasEditedTranscript,
            let wordTimestamps = activeTranscription.wordTimestamps, !wordTimestamps.isEmpty
        {
            return wordTimestamps.count
        }
        return transcriptText.split(whereSeparator: \.isWhitespace).count
    }

    private var speakerCountValue: Int {
        activeTranscription.speakers?.count ?? activeTranscription.speakerCount ?? 0
    }

    /// Meeting retranscription configures the diarized participants captured
    /// from system audio. The protected microphone speaker (`Me`) is separate.
    private var defaultRetranscriptionSpeakerCount: Int {
        guard activeTranscription.sourceType == .meeting else { return speakerCountValue }
        if let speakers = activeTranscription.speakers, !speakers.isEmpty {
            return speakers.filter { $0.id != AudioSource.microphone.rawValue }.count
        }
        return max(0, speakerCountValue - 1)
    }

    /// User-facing engine attribution string for the metadata chip, or `nil`
    /// for legacy rows saved before the v0.8 engine-attribution migration —
    /// in that case we omit the chip rather than mislabel.
    private var engineAttributionLabel: String? {
        guard let engineRaw = activeTranscription.engine,
            let preference = SpeechEnginePreference(rawValue: engineRaw)
        else {
            return nil
        }
        switch preference {
        case .parakeet:
            return "Parakeet TDT"
        case .nemotron:
            // Variant-aware: the EN build is not "Nemotron 3.5". Legacy rows
            // (nil/multilingual variant) keep the established label.
            if activeTranscription.engineVariant == NemotronModelVariant.english1120.rawValue {
                return "Nemotron EN Beta"
            }
            return "Nemotron 3.5 Beta"
        case .whisper:
            guard let variant = activeTranscription.engineVariant else {
                return "Whisper"
            }
            return "Whisper \(SpeechEnginePreference.friendlyVariantName(variant))"
        case .cohere:
            return "Cohere Transcribe"
        }
    }

    private var resultHeaderCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always-visible compact row: back button + title + metadata + mandala + expand toggle
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                if onBack != nil {
                    Button {
                        requestMeetingNotesNavigation(.navigateBack)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(backHovered ? DesignSystem.Colors.accent : DesignSystem.Colors.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(
                                        backHovered
                                            ? DesignSystem.Colors.accent.opacity(0.12)
                                            : DesignSystem.Colors.surfaceElevated)
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
                    titleView

                    if !headerExpanded {
                        // Inline metadata in collapsed mode
                        HStack(spacing: 6) {
                            metadataChip(
                                icon: sourceChipIcon,
                                text: sourceChipText,
                                tint: sourceChipTint,
                                symbolText: sourceChipSymbolText
                            )

                            if let durationMs = transcription.durationMs {
                                metadataChip(
                                    icon: "clock", text: durationMs.formattedDuration,
                                    tint: DesignSystem.Colors.textSecondary)
                            }

                            if transcriptWordCount > 0 {
                                metadataChip(
                                    icon: "text.word.spacing", text: "\(transcriptWordCount.formatted()) words",
                                    tint: DesignSystem.Colors.textSecondary)
                            }

                            if speakerCountValue > 0 {
                                metadataChip(
                                    icon: "person.2.fill",
                                    text: "\(speakerCountValue) speaker\(speakerCountValue == 1 ? "" : "s")",
                                    tint: DesignSystem.Colors.textSecondary)
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

            if let errorMessage = promptResultsViewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.bottom, DesignSystem.Spacing.sm)
            }

            // Expanded details section
            if headerExpanded {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        metadataChip(
                            icon: sourceChipIcon,
                            text: expandedSourceChipText,
                            tint: sourceChipTint,
                            symbolText: sourceChipSymbolText
                        )

                        if let durationMs = transcription.durationMs {
                            metadataChip(
                                icon: "clock", text: durationMs.formattedDuration,
                                tint: DesignSystem.Colors.textSecondary)
                        }

                        if transcriptWordCount > 0 {
                            metadataChip(
                                icon: "text.word.spacing", text: "\(transcriptWordCount.formatted()) words",
                                tint: DesignSystem.Colors.textSecondary)
                        }

                        if speakerCountValue > 0 {
                            metadataChip(
                                icon: "person.2.fill",
                                text: "\(speakerCountValue) speaker\(speakerCountValue == 1 ? "" : "s")",
                                tint: DesignSystem.Colors.textSecondary)
                        }

                        if let engineAttributionLabel {
                            metadataChip(
                                icon: "cpu", text: engineAttributionLabel, tint: DesignSystem.Colors.textSecondary)
                        }
                    }

                    if let sourceURL = transcription.sourceURL,
                        let url = URL(string: sourceURL)
                    {
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

    @ViewBuilder
    private var titleView: some View {
        if editingTitle {
            HStack(spacing: 8) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(headerExpanded ? DesignSystem.Typography.pageTitle : DesignSystem.Typography.sectionTitle)
                    .focused($titleFocused)
                    .onSubmit(commitTitleRename)

                Button(action: commitTitleRename) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.successGreen)
                }
                .buttonStyle(.plain)

                Button(action: cancelTitleRename) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 8) {
                Text(displayedTitle)
                    .font(headerExpanded ? DesignSystem.Typography.pageTitle : DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(headerExpanded ? 3 : 1)

                if canRenameTitle {
                    Button(action: beginTitleRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(transcription.sourceType == .meeting ? "Rename meeting" : "Rename transcription")
                }

                if transcription.recoveredFromCrash {
                    metadataChip(
                        icon: "wrench.and.screwdriver",
                        text: "Recovered",
                        tint: DesignSystem.Colors.warningAmber
                    )
                }

                if let partialCapture = MeetingPartialCapturePresentation.make(for: activeTranscription) {
                    metadataChip(
                        icon: "exclamationmark.triangle.fill",
                        text: partialCapture.badgeText,
                        tint: DesignSystem.Colors.warningAmber
                    )
                }
            }
        }
    }

    private var sourceDisplay: TranscriptionSourceDisplay {
        TranscriptionSourceDisplay.resolve(for: transcription)
    }

    private var sourceChipIcon: String {
        sourceDisplay.systemImage
    }

    private var sourceChipSymbolText: String? {
        sourceDisplay.symbolText
    }

    private var sourceChipText: String {
        sourceDisplay.collapsedText
    }

    private var expandedSourceChipText: String {
        sourceDisplay.expandedText
    }

    private var sourceChipTint: Color {
        sourceDisplay.tint
    }

    private var displayedTitle: String {
        (viewModel.currentTranscription ?? transcription).effectiveDisplayTitle
    }

    private var canRenameTitle: Bool {
        transcription.sourceType == .meeting || transcription.sourceType == .file
    }

    private func beginTitleRename() {
        titleDraft = displayedTitle
        editingTitle = true
        Task { @MainActor in
            titleFocused = true
        }
    }

    private func cancelTitleRename() {
        editingTitle = false
        titleDraft = ""
    }

    private func commitTitleRename() {
        if transcription.sourceType == .meeting {
            viewModel.renameCurrentTranscription(to: titleDraft)
        } else if transcription.sourceType == .file {
            viewModel.renameCurrentTranscriptionTitle(to: titleDraft)
        }
        editingTitle = false
    }

    private func metadataChip(icon: String, text: String, tint: Color, symbolText: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let symbolText {
                Text(symbolText)
                    .font(.system(size: 10, weight: .bold))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
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
                case .notes:
                    if activeTranscription.sourceType == .meeting {
                        meetingNotesPane
                    } else {
                        transcriptPane
                            .onAppear { viewModel.selectedTab = .transcript }
                    }
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

    /// Small timed transcripts render in a plain stack; only their row container
    /// becomes lazy at the long-transcript threshold.
    private var transcriptBodyUsesLazyStack: Bool {
        TranscriptBodyLayout.usesLazyStack(
            rowCount: viewModel.speakerAttribution?.editableSegments.count ?? cachedTranscriptRowCount
        )
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            if findBarVisible {
                transcriptFindToolbar
            }
            if editingSpeakers {
                speakerEditingActionBar
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.sm)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        transcriptPaneHeader

                    if let partialCapture = MeetingPartialCapturePresentation.make(for: activeTranscription) {
                        meetingPartialCaptureBanner(partialCapture)
                    }

                    if activeTranscription.sourceType == .meeting,
                       activeTranscription.status != .processing,
                       !activeTranscription.hasWordTimestamps,
                       let banner = meetingNoWordTimestampsBannerPresentation {
                        meetingNoWordTimestampsBanner(banner)
                    }

                    if shouldShowTranscriptAISetupBanner {
                        chatConfigurationBanner
                    }

                    if let error = transcriptEditError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.errorRed)
                    }

                    if let presentation = meetingTranscriptProcessingPresentation {
                        meetingTranscriptProcessingState(presentation)
                    }

                    if editingTranscript {
                        transcriptEditor
                    } else if transcriptDisplayMode == .timed,
                              let timestamps = activeTranscription.wordTimestamps,
                              !timestamps.isEmpty {
                        if let attribution = viewModel.speakerAttribution {
                            speakerSummaryPanel(speakers: attribution.speakers)
                        } else if let speakers = activeTranscription.speakers, !speakers.isEmpty {
                            speakerSummaryPanel(speakers: speakers)
                        }
                        timestampedView(words: timestamps)
                    } else if !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        transcriptTextBlock
                    } else if meetingTranscriptProcessingPresentation == nil {
                        Text("No transcript available")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .onChange(of: playerViewModel.currentTimeMs) { oldValue, newValue in
                guard playerViewModel.isPlaying else { return }
                guard !editingSpeakers else { return }
                // Detect seek (large time jump) — re-sync transcript regardless of pause state
                if autoScrollPaused && abs(newValue - oldValue) > 2000 {
                    autoScrollPaused = false
                    scrollPauseTask?.cancel()
                    lastScrolledSegmentMs = -1
                    lastScrolledEffectiveSegmentID = nil
                }
                guard !autoScrollPaused else { return }
                if let attribution = viewModel.speakerAttribution,
                   let targetID = effectiveTranscriptScrollTarget(
                       for: newValue,
                       attribution: attribution
                   ),
                   targetID != lastScrolledEffectiveSegmentID {
                    lastScrolledEffectiveSegmentID = targetID
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                } else if viewModel.speakerAttribution == nil,
                          !cachedSegments.isEmpty,
                          let targetID = autoScrollTarget(for: newValue),
                          targetID != lastScrolledSegmentMs {
                    lastScrolledSegmentMs = targetID
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
            }
            // Find navigation: scroll the current match into view. Pausing
            // auto-scroll keeps playback-follow from yanking the view back.
            .onChange(of: findScrollToken) {
                guard findBarVisible else { return }
                autoScrollPaused = true
                findPausedAutoScroll = true
                scrollPauseTask?.cancel()
                if let target = findCurrentEffectiveScrollTargetID {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                } else if let target = findCurrentLegacyScrollTargetID {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
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
        .background { transcriptFindShortcuts }
        .onChange(of: transcriptDisplayMode) {
            if transcriptDisplayMode == .timed {
                scheduleSegmentCacheRebuild()
            }
            if findBarVisible { rebuildFindBlocks() }
            if transcriptDisplayMode != .timed {
                editingSpeakers = false
                speakerSelection.clear()
            }
        }
        .onChange(of: editingTranscript) {
            if editingTranscript, findBarVisible { closeFindBar() }
        }
        .onAppear {
            if let existing = scrollMonitor {
                NSEvent.removeMonitor(existing)
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                if self.playerViewModel.isPlaying {
                    if self.findPausedAutoScroll {
                        // Manual scroll takes ownership and should start the
                        // normal bounded pause below, not inherit find's pause.
                        self.findPausedAutoScroll = false
                        self.autoScrollPaused = false
                        self.scrollPauseTask?.cancel()
                    }
                    if !self.autoScrollPaused {
                        self.autoScrollPaused = true
                        self.lastScrolledSegmentMs = -1
                        self.lastScrolledEffectiveSegmentID = nil
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

    // MARK: - In-transcript find (U2)

    /// Pinned find toolbar at the top of the reading pane. Stays visible while
    /// scrolling (unlike a row inside the ScrollView) and never overlaps the
    /// header controls (unlike a floating overlay).
    private var transcriptFindToolbar: some View {
        HStack {
            Spacer()
            transcriptFindBar
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var transcriptFindBar: some View {
        TranscriptFindBar(
            query: Binding(
                get: { findModel.query },
                set: { setFindQuery($0) }
            ),
            isFocused: $findFieldFocused,
            position: findModel.displayPosition,
            hasQueryButNoMatches: findHasQueryNoMatches,
            onNext: {
                findModel.next(); findScrollToken &+= 1
            },
            onPrev: {
                findModel.prev(); findScrollToken &+= 1
            },
            onClose: closeFindBar
        )
    }

    /// Hidden buttons that register ⌘F / ⌘G / ⇧⌘G while the transcript pane is
    /// in the hierarchy. ⌘G stepping is gated on an open bar with live matches.
    private var transcriptFindShortcuts: some View {
        ZStack {
            Button("") { openFindBar() }
                .keyboardShortcut("f", modifiers: .command)
            if findBarVisible, findModel.hasMatches {
                Button("") {
                    findModel.next(); findScrollToken &+= 1
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("") {
                    findModel.prev(); findScrollToken &+= 1
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            if editingSpeakers {
                Button("") { viewModel.undoSpeakerCorrection() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!viewModel.canUndoSpeakerCorrection)
                Button("") { viewModel.redoSpeakerCorrection() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!viewModel.canRedoSpeakerCorrection)
                Button("") {
                    if speakerSelection.isEmpty {
                        editingSpeakers = false
                    } else {
                        speakerSelection.clear()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Match ranges to wash in the reading surface, keyed by block `id`
    /// (segment `startMs` in Timed mode, paragraph line index in Text mode).
    private var findHighlightsByBlockId: [TranscriptFindBlockID: [NSRange]] {
        guard findBarVisible, !findModel.matches.isEmpty, !findBlocks.isEmpty else { return [:] }
        var dict: [TranscriptFindBlockID: [NSRange]] = [:]
        for match in findModel.matches where findBlocks.indices.contains(match.blockIndex) {
            dict[findBlocks[match.blockIndex].id, default: []].append(match.range)
        }
        return dict
    }

    /// The single emphasized match, resolved to its block's scroll `id`.
    private var findCurrentHighlight: (id: TranscriptFindBlockID, range: NSRange)? {
        guard findBarVisible, let current = findModel.current,
            findBlocks.indices.contains(current.blockIndex)
        else { return nil }
        return (id: findBlocks[current.blockIndex].id, range: current.range)
    }

    /// The scroll target for the current match. Timed mode scrolls to the
    /// owning segment. Text mode keeps one selectable transcript body, so it
    /// scrolls to the hidden prefix anchor for the current match range.
    private var findCurrentEffectiveScrollTargetID: SpeakerEditableSegmentID? {
        guard findBarVisible, let current = findModel.current,
              findBlocks.indices.contains(current.blockIndex) else { return nil }
        if case .effective(let id) = findBlocks[current.blockIndex].id {
            return id
        }
        return nil
    }

    private var findCurrentLegacyScrollTargetID: Int? {
        guard findBarVisible, let current = findModel.current,
              findBlocks.indices.contains(current.blockIndex) else { return nil }
        switch findBlocks[current.blockIndex].id {
        case .effective:
            return nil
        case .legacy(let id):
            return id
        case .text:
            return currentTextFindAnchor?.id
        }
    }

    private var findFullTextHighlightRanges: [NSRange] {
        guard findBarVisible, transcriptDisplayMode == .text, !findModel.matches.isEmpty else { return [] }
        return findModel.matches.map(\.range)
    }

    private var findFullTextCurrentHighlightRange: NSRange? {
        guard findBarVisible, transcriptDisplayMode == .text else { return nil }
        return findModel.current?.range
    }

    private var findHasQueryNoMatches: Bool {
        findBarVisible
            && !findModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !findModel.hasMatches
    }

    private func openFindBar() {
        // Find is a reading affordance; editing uses the raw text editor.
        guard !editingTranscript else { return }
        if !findBarVisible {
            withAnimation(DesignSystem.Animation.contentSwap) { findBarVisible = true }
        }
        rebuildFindBlocks()
        Task { @MainActor in findFieldFocused = true }
    }

    private func closeFindBar() {
        withAnimation(DesignSystem.Animation.contentSwap) { findBarVisible = false }
        findFieldFocused = false
        findModel.clear()
        findBlocks = []
        releaseFindOwnedAutoScrollPause()
    }

    /// Resume playback-follow only if find navigation owns the pause; manual
    /// scroll pauses keep their normal 5-second lifetime.
    private func releaseFindOwnedAutoScrollPause() {
        if findPausedAutoScroll {
            autoScrollPaused = false
            scrollPauseTask?.cancel()
            findPausedAutoScroll = false
        }
    }

    private func setFindQuery(_ newValue: String) {
        findModel.setQuery(newValue)
        if !findModel.hasMatches {
            releaseFindOwnedAutoScrollPause()
        }
        findScrollToken &+= 1
    }

    /// Rebuild the ordered blocks the matcher searches for the current mode and
    /// re-run the live query. Timed mode searches effective editable segments
    /// when available, including user-created splits. Text mode
    /// searches the full transcript string so native selection can span line and
    /// paragraph breaks; the current-match scroll anchor is derived on demand.
    private func rebuildFindBlocks() {
        guard findBarVisible, !editingTranscript else {
            findBlocks = []
            findModel.setBlocks([])
            releaseFindOwnedAutoScrollPause()
            return
        }
        let blocks: [TranscriptFindBlock]
        if transcriptDisplayMode == .timed, hasTimestamps {
            if let attribution = viewModel.speakerAttribution {
                blocks = attribution.editableSegments.map {
                    TranscriptFindBlock(id: .effective($0.id), text: $0.text)
                }
            } else {
                blocks = cachedSegments.map {
                    TranscriptFindBlock(id: .legacy($0.startMs), text: $0.text)
                }
            }
        } else {
            blocks = [TranscriptFindBlock(id: .text, text: transcriptText)]
        }
        findBlocks = blocks
        findModel.setBlocks(blocks.map(\.text))
        if findModel.hasMatches {
            findScrollToken &+= 1
        } else {
            releaseFindOwnedAutoScrollPause()
        }
    }

    private var currentTextFindAnchor: TranscriptTextFindAnchor? {
        guard findBarVisible, transcriptDisplayMode == .text,
            let current = findModel.current
        else { return nil }
        guard let prefixEnd = transcriptText.stringIndex(utf16Offset: current.range.location) else {
            return nil
        }
        return TranscriptTextFindAnchor(
            id: Self.textFindAnchorBaseID,
            prefixText: String(transcriptText[..<prefixEnd])
        )
    }

    /// Persisted scale clamped to the supported range, so a stale or externally
    /// written `transcriptFontScale` never renders the body at an out-of-range
    /// size before the user touches A−/A+.
    private var clampedTranscriptFontScale: Double {
        min(
            max(transcriptFontScale, Self.transcriptFontScaleRange.lowerBound),
            Self.transcriptFontScaleRange.upperBound
        )
    }

    /// Transcript body font at the current user reading scale (U4).
    private var scaledTranscriptFont: Font {
        DesignSystem.Typography.transcriptBody(scale: clampedTranscriptFontScale)
    }

    private func adjustTranscriptFontScale(by delta: Double) {
        let next = clampedTranscriptFontScale + delta
        transcriptFontScale = min(
            max(next, Self.transcriptFontScaleRange.lowerBound),
            Self.transcriptFontScaleRange.upperBound
        )
    }

    /// Compact A−/A+ control for the transcript reading size. Lives in the pane
    /// header; hidden while editing (editing uses the raw text editor).
    private var transcriptFontSizeControl: some View {
        HStack(spacing: 2) {
            Button {
                adjustTranscriptFontScale(by: -Self.transcriptFontScaleStep)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(clampedTranscriptFontScale <= Self.transcriptFontScaleRange.lowerBound + 0.001)
            .help("Smaller transcript text")
            .accessibilityLabel("Smaller transcript text")

            Button {
                adjustTranscriptFontScale(by: Self.transcriptFontScaleStep)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(clampedTranscriptFontScale >= Self.transcriptFontScaleRange.upperBound - 0.001)
            .help("Larger transcript text")
            .accessibilityLabel("Larger transcript text")
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private var transcriptPaneHeader: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Label("Transcript", systemImage: "text.alignleft")
                .font(DesignSystem.Typography.sectionTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if hasEditedTranscript {
                Label("Edited", systemImage: "checkmark.circle.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.10))
                    )
            }

            Spacer()

            // Show whenever word timestamps exist: Timed renders from word data,
            // and Text falls back to the raw transcript when clean text is absent.
            if !editingTranscript, hasTimestamps {
                Picker("Transcript view", selection: $transcriptDisplayMode) {
                    ForEach(TranscriptDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            if !editingTranscript {
                transcriptFontSizeControl
            }

            if editingTranscript {
                if hasEditedTranscript {
                    Button {
                        revertTranscriptEdit()
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                    }
                    .parakeetAction(.secondary)
                }

                Button {
                    cancelTranscriptEdit()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .parakeetAction(.secondary)

                Button {
                    commitTranscriptEdit()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .parakeetAction(.primaryProminent)
                .disabled(transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                if speakerEditingAvailable {
                    Button {
                        editingSpeakers.toggle()
                        if !editingSpeakers {
                            speakerSelection.clear()
                        } else if findBarVisible {
                            closeFindBar()
                        }
                    } label: {
                        Label(editingSpeakers ? "Done" : "Edit speakers", systemImage: "person.2")
                    }
                    .parakeetAction(editingSpeakers ? .primary : .secondary)
                    .disabled(activeTranscription.status == .processing)
                }

                // Editing operates on the plain text transcript only; the Timed
                // view is derived from word timestamps and has no editable text.
                // Disable Edit in Timed mode rather than silently dropping the
                // user into the raw text view when they click it.
                Button {
                    beginTranscriptEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .parakeetAction(.secondary)
                .disabled(
                    transcriptDisplayMode != .text
                        || !TranscriptDetailActionAvailability.canEdit(
                            status: activeTranscription.status
                        )
                )
                .help(transcriptEditHelp)
            }
        }
    }

    private var transcriptEditHelp: String {
        if transcriptDisplayMode != .text {
            return "Switch to Text to edit. Edits apply to the text transcript; timestamps are preserved."
        }
        if activeTranscription.status == .processing {
            return "Editing is available after transcription finishes."
        }
        if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add transcript text manually."
        }
        return "Edit the transcript text"
    }

    private var speakerEditingAvailable: Bool {
        transcriptDisplayMode == .timed
            && activeTranscription.status == .completed
            && !(activeTranscription.wordTimestamps ?? []).isEmpty
            && !(activeTranscription.transcriptSegments ?? []).isEmpty
            && viewModel.speakerAttribution != nil
    }

    private var meetingTranscriptProcessingPresentation: MeetingTranscriptProcessingPresentation? {
        MeetingTranscriptProcessingPresentation.make(
            sourceType: activeTranscription.sourceType,
            status: activeTranscription.status
        )
    }

    private func meetingTranscriptProcessingState(
        _ presentation: MeetingTranscriptProcessingPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ParakeetSpinner(.inline, tint: DesignSystem.Colors.accent)
                Text(presentation.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Text(presentation.message)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .accessibilityElement(children: .combine)
    }

    private var transcriptEditor: some View {
        TextEditor(text: $transcriptDraft)
            .font(DesignSystem.Typography.bodyLarge)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .focused($transcriptEditorFocused)
            .padding(DesignSystem.Spacing.md)
            .frame(minHeight: 320)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.accent.opacity(0.30), lineWidth: 1)
            )
    }

    private var shouldShowTranscriptAISetupBanner: Bool {
        !viewModel.llmAvailable
            && !viewModel.hasPromptResultTabs
            && !viewModel.hasConversations
    }

    @ViewBuilder
    private var transcriptTextBlock: some View {
        if findBarVisible {
            transcriptTextBlockSearchable()
        } else {
            Text(transcriptText)
                .font(scaledTranscriptFont)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(6)
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                )
        }
    }

    @ViewBuilder
    private func transcriptTextBlockSearchable() -> some View {
        if transcriptDisplayMode == .text {
            transcriptFullTextSearchableBlock()
        } else {
            transcriptTimedTextSearchableBlocks()
        }
    }

    private func transcriptFullTextSearchableBlock() -> some View {
        Text(
            TranscriptFindHighlight.attributed(
                transcriptText,
                ranges: findFullTextHighlightRanges,
                current: findFullTextCurrentHighlightRange,
                baseFont: scaledTranscriptFont
            )
        )
        .foregroundStyle(DesignSystem.Colors.textPrimary)
        .lineSpacing(6)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            transcriptTextFindAnchor()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
    }

    @ViewBuilder
    private func transcriptTextFindAnchor() -> some View {
        if let anchor = currentTextFindAnchor {
            Text(anchor.prefixText)
                .font(scaledTranscriptFont)
                .lineSpacing(6)
                .foregroundStyle(.clear)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomLeading) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(anchor.id)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func transcriptTimedTextSearchableBlocks() -> some View {
        let highlights = findHighlightsByBlockId
        let current = findCurrentHighlight
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(findBlocks) { block in
                paragraphText(block, highlights: highlights, current: current)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(block.id)
            }
        }
        .textSelection(.enabled)
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
    }

    private func paragraphText(
        _ block: TranscriptFindBlock,
        highlights: [TranscriptFindBlockID: [NSRange]],
        current: (id: TranscriptFindBlockID, range: NSRange)?
    ) -> Text {
        let ranges = highlights[block.id] ?? []
        guard !ranges.isEmpty else {
            return Text(block.text).font(scaledTranscriptFont)
        }
        let currentRange = (current?.id == block.id) ? current?.range : nil
        return Text(
            TranscriptFindHighlight.attributed(
                block.text,
                ranges: ranges,
                current: currentRange,
                baseFont: scaledTranscriptFont
            ))
    }

    private var meetingNotesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Label("Your notes", systemImage: "note.text")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                if let notes = normalizedMeetingNotesDraft {
                    Button {
                        TranscriptResultActions.copyText(notes)
                        notesCopied = true
                        notesCopiedResetTask?.cancel()
                        notesCopiedResetTask = Task {
                            try? await Task.sleep(for: .seconds(1))
                            if !Task.isCancelled {
                                notesCopied = false
                            }
                        }
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: notesCopied ? "checkmark" : "doc.on.doc")
                            Text(notesCopied ? "Copied" : "Copy")
                        }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(notesCopied ? DesignSystem.Colors.successGreen : .primary)
                    }
                    .parakeetAction(.secondary)
                    .controlSize(.small)
                    .accessibilityLabel(notesCopied ? "Notes copied" : "Copy your notes")
                }
            }

            TextEditor(text: savedMeetingNotesViewModel.textBinding(for: activeTranscription.id))
                .disabled(
                    savedMeetingNotesViewModel.meetingID != activeTranscription.id
                        || savedMeetingNotesViewModel.saveState == .deleted
                )
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($meetingNotesEditorFocused)
                .frame(minHeight: 280, maxHeight: .infinity)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(DesignSystem.Colors.border.opacity(0.7), lineWidth: 1)
                )
                .accessibilityLabel("Meeting notes")
                .accessibilityHint("Add private context, decisions, or reminders for this meeting. Changes save automatically.")

            HStack(spacing: DesignSystem.Spacing.sm) {
                if savedMeetingNotesViewModel.wordCount >= MeetingNotesViewModel.softCapWarningWordCount {
                    Label(
                        "Prompts may trim notes past 8,000 words.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                }

                Spacer()

                meetingNotesSaveStatus

                Text("\(savedMeetingNotesViewModel.wordCount.formatted()) words")
                    .font(DesignSystem.Typography.caption.monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }

            if let warning = viewModel.meetingNotesArtifactWarning {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                    Spacer()
                    Button("Retry") {
                        Task {
                            await viewModel.retryCurrentMeetingNotesArtifactRefresh()
                        }
                    }
                    .parakeetAction(.secondary)
                    .controlSize(.small)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.25))
        )
    }

    @ViewBuilder
    private var meetingNotesSaveStatus: some View {
        switch savedMeetingNotesViewModel.saveState {
        case .deleted:
            Label("Meeting deleted — notes were not saved", systemImage: "trash")
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.successGreen)
        case .saving:
            HStack(spacing: DesignSystem.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        case .failed:
            HStack(spacing: DesignSystem.Spacing.xs) {
                Label("Couldn’t save", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                Button("Retry") {
                    retrySavedMeetingNotes()
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
            }
        }
    }

    private var meetingNotesPane: some View {
        meetingNotesSection
            .padding(DesignSystem.Spacing.lg)
    }

    // MARK: - Tab Bar

    private var orderedTabs: [TranscriptionViewModel.TranscriptTab] {
        var tabs = TranscriptResultTabOrdering.leadingTabs(for: activeTranscription.sourceType)
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

                generateTabButton

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
                let generation = promptResultsViewModel.pendingGeneration(id: id)
            {
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
            guard viewModel.selectedTab != tab else { return }
            if case .notes = viewModel.selectedTab {
                startMeetingNotesNavigation(isCurrent: { viewModel.selectedTab == .notes }) {
                    viewModel.selectedTab = tab
                }
                return
            }
            viewModel.selectedTab = tab
        }
        .contextMenu {
            if case .result(let id) = tab,
                let promptResult = promptResultsViewModel.promptResults.first(where: { $0.id == id })
            {
                Button("Copy Result") {
                    TranscriptResultActions.copyText(promptResult.content)
                    copiedResultID = id
                    resultCopiedResetTask?.cancel()
                    resultCopiedResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedResultID = nil
                    }
                }

                Menu("Export Document") {
                    Button("Markdown (.md)") { exportGenerationToDownloads(promptResult: promptResult, format: .md) }
                    Button("Plain Text (.txt)") {
                        exportGenerationToDownloads(promptResult: promptResult, format: .txt)
                    }
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
        let hasAI = promptResultsViewModel.hasPromptResultGenerationCapability
        return Button {
            showGeneratePopover = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(
                    hasAI
                        ? DesignSystem.Colors.textSecondary
                        : DesignSystem.Colors.accent
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .popover(isPresented: $showGeneratePopover) {
            promptGenerationPopover
                .frame(width: 420)
                .padding(DesignSystem.Spacing.lg)
        }
        .accessibilityLabel(hasAI ? "New prompt generation" : "Set up AI for prompt generation")
        .help(hasAI ? "Generate a prompt result" : "Set up AI for summaries and action items")
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func tabIcon(_ tab: TranscriptionViewModel.TranscriptTab) -> String {
        switch tab {
        case .transcript:
            return "text.alignleft"
        case .notes:
            return "note.text"
        case .result:
            return "sparkles"
        case .generation(let id):
            switch promptResultsViewModel.pendingGeneration(id: id)?.state {
            case .queued:
                return "clock"
            case .failed:
                return "exclamationmark.triangle"
            default:
                return "sparkles"
            }
        case .chat:
            return "bubble.left.and.text.bubble.right"
        }
    }

    private func tabLabel(_ tab: TranscriptionViewModel.TranscriptTab) -> String {
        switch tab {
        case .transcript:
            return "Transcript"
        case .notes:
            return "Notes"
        case .result(let id):
            guard let promptResult = promptResultsViewModel.promptResults.first(where: { $0.id == id }) else {
                return "Result"
            }
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
                            startPromptContextAction { context in
                                if let generationID = promptResultsViewModel.regeneratePromptResult(
                                    promptResult,
                                    transcript: context
                                ) {
                                    viewModel.selectedTab = .generation(id: generationID)
                                }
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "arrow.clockwise")
                                Text("Regenerate")
                            }
                            .font(DesignSystem.Typography.caption)
                        }
                        .parakeetAction(.secondary)
                        .controlSize(.small)
                        .disabled(
                            promptNotesActionGate.isRunning || richContextLoader.preparingPromptContext
                                || !promptResultsViewModel.canGeneratePromptResult
                                || transcriptText.isEmpty
                        )

                        let isCopied = copiedButtonResultID == promptResultID
                        Button {
                            TranscriptResultActions.copyText(promptResult.content)
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
                        .parakeetAction(.secondary)
                        .controlSize(.small)

                        Menu {
                            Button("Markdown (.md)") {
                                exportGenerationToDownloads(promptResult: promptResult, format: .md)
                            }
                            Button("Plain Text (.txt)") {
                                exportGenerationToDownloads(promptResult: promptResult, format: .txt)
                            }
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "arrow.down.doc")
                                Text("Export")
                            }
                            .font(DesignSystem.Typography.caption)
                        }
                        .menuStyle(.borderedButton)
                        .tint(DesignSystem.Colors.tintNeutral)
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
                        .parakeetAction(.destructive)
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
                if case .failed(let message) = generation.state {
                    failedGenerationCard(generation, message: message)

                    // Partial content streamed before the failure is still
                    // worth reading; dimmed so it reads as incomplete.
                    if !generation.content.isEmpty {
                        MarkdownContentView(generation.content, font: DesignSystem.Typography.bodyLarge)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(0.6)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button {
                            showingCancelGenerationAlert = generation.id
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: generation.state == .queued ? "minus.circle" : "xmark")
                                Text(generation.state == .queued ? "Remove" : "Cancel")
                            }
                            .font(DesignSystem.Typography.caption)
                        }
                        .parakeetAction(.secondary)
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
        .alert(
            generation.state == .queued ? "Remove from queue?" : "Cancel generation?",
            isPresented: Binding(
                get: { showingCancelGenerationAlert == generation.id },
                set: { if !$0 { showingCancelGenerationAlert = nil } }
            )
        ) {
            Button("Keep", role: .cancel) {}
            Button(generation.state == .queued ? "Remove" : "Cancel", role: .destructive) {
                promptResultsViewModel.cancelGeneration(id: generation.id)
                viewModel.selectedTab = .transcript
            }
        } message: {
            Text(
                generation.state == .queued
                    ? "This will remove the prompt from the generation queue."
                    : "This will stop the AI from generating the result.")
        }
    }

    private func failedGenerationCard(
        _ generation: PromptResultsViewModel.PendingGeneration,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("Generation failed", systemImage: "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.errorRed)

            Text(message)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    if let newID = promptResultsViewModel.retryGeneration(id: generation.id) {
                        viewModel.selectedTab = .generation(id: newID)
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .parakeetAction(.primary)
                .controlSize(.regular)

                Button("Dismiss") {
                    let replacingID = generation.replacingPromptResultID
                    promptResultsViewModel.cancelGeneration(id: generation.id)
                    viewModel.selectedTab = replacingID.map { .result(id: $0) } ?? .transcript
                }
                .parakeetAction(.secondary)
                .controlSize(.regular)
            }
            .padding(.top, DesignSystem.Spacing.xs)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
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

    @ViewBuilder
    private var promptGenerationPopover: some View {
        if promptResultsViewModel.hasPromptResultGenerationCapability {
            promptGenerationControls
        } else {
            promptGenerationSetupPopover
        }
    }

    private var promptGenerationControls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Prompt chips
            promptChips

            if let summary = promptResultsViewModel.selectedPromptInferenceSummary {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Label(summary, systemImage: "slider.horizontal.3")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    if let compatibility = promptResultsViewModel.selectedPromptInferenceCompatibilityMessage {
                        Text(compatibility)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.warningAmber)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // Model selector
            if !promptResultsViewModel.availableModels.isEmpty {
                ModelSelectorView(
                    currentModel: promptResultsViewModel.currentModelName,
                    displayName: promptResultsViewModel.modelDisplayName,
                    availableModels: promptResultsViewModel.availableModels,
                    disabled: promptResultsViewModel.hasActiveGenerations,
                    onSelect: { promptResultsViewModel.selectModel($0) }
                )
            }

            // Extra instructions
            TextField("Extra instructions (optional)", text: $promptResultsViewModel.extraInstructions)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.body)

            if promptResultsViewModel.hasActiveGenerations {
                Text(queueStatusText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            // Actions row — manage prompts on the left, generate on the right
            HStack {
                Button {
                    showGeneratePopover = false
                    showPromptLibrary = true
                } label: {
                    Label("Manage Prompts", systemImage: "slider.horizontal.3")
                }
                .parakeetAction(.secondary)
                .controlSize(.regular)

                Spacer()

                Button {
                    showGeneratePopover = false
                    startPromptContextAction { context in
                        if let generationID = promptResultsViewModel.generatePromptResult(
                            transcript: context,
                            transcriptionId: transcription.id
                        ) {
                            viewModel.selectedTab = .generation(id: generationID)
                        }
                    }
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .parakeetAction(.primaryProminent)
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    promptNotesActionGate.isRunning || richContextLoader.preparingPromptContext
                        || !promptResultsViewModel.canGenerateManualPromptResult
                        || transcriptText.isEmpty
                )
            }
        }
    }

    private var promptGenerationSetupPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Turn on AI for summaries and action items")
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(
                        "MacParakeet can generate summaries, action items, and custom prompt results from this transcript. Transcription still works without AI."
                    )
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()

                Button {
                    showGeneratePopover = false
                    onSetUpAI?()
                } label: {
                    Label("Set up AI", systemImage: "gearshape")
                }
                .parakeetAction(.primaryProminent)
                .controlSize(.regular)
            }
        }
    }

    private var promptChips: some View {
        let prompts = promptResultsViewModel.visiblePrompts
        return FlowLayout(spacing: 8) {
            ForEach(prompts) { prompt in
                let isSelected = promptResultsViewModel.selectedPrompt?.id == prompt.id
                let hasExisting =
                    promptResultsViewModel.promptResults.contains { $0.promptName == prompt.name }
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
                        .fill(
                            isSelected ? DesignSystem.Colors.accent.opacity(0.15) : DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected
                                ? DesignSystem.Colors.accent.opacity(0.4) : DesignSystem.Colors.border.opacity(0.5),
                            lineWidth: 0.5)
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
                    if chatVM.canSendMessage && chatVM.messages.isEmpty {
                        VStack(spacing: DesignSystem.Spacing.md) {
                            chatEmptyState(chatVM: chatVM)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let error = chatVM.errorMessage {
                                chatErrorRow(error)
                            }
                        }
                        .padding(DesignSystem.Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DesignSystem.Colors.surface)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                                if !chatVM.canSendMessage {
                                    chatConfigurationBanner
                                }

                                ForEach(chatVM.messages) { message in
                                    chatBubble(message)
                                        .id(message.id)
                                }

                                if let error = chatVM.errorMessage {
                                    chatErrorRow(error)
                                }
                            }
                            .padding(DesignSystem.Spacing.lg)
                        }
                        .defaultScrollAnchor(.bottom)
                        .background(DesignSystem.Colors.surface)
                    }

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
                                    if !chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        && chatVM.canSendMessage && !chatVM.isStreaming
                                        && !chatNotesActionGate.isRunning
                                    {
                                        sendChatMessage(chatVM)
                                    }
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
                                let canSend =
                                    !chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && chatVM.canSendMessage && !chatNotesActionGate.isRunning
                                Button {
                                    sendChatMessage(chatVM)
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 26))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(
                                    canSend ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.3)
                                )
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
                chatNotesActionGate.invalidate()
                chatVM.newChat()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .font(DesignSystem.Typography.caption)
            }
            .parakeetAction(.secondary)
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
                            chatNotesActionGate.invalidate()
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
                    chatNotesActionGate.invalidate()
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
                        topLeadingRadius: DesignSystem.Layout.cornerRadius,
                        bottomLeadingRadius: isUser ? DesignSystem.Layout.cornerRadius : 4,
                        bottomTrailingRadius: isUser ? 4 : DesignSystem.Layout.cornerRadius,
                        topTrailingRadius: DesignSystem.Layout.cornerRadius
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
                        bubbleShape.fill(
                            isUser
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
                                    TranscriptResultActions.copyText(message.content)
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
                                    .foregroundStyle(
                                        copiedMessageId == message.id
                                            ? DesignSystem.Colors.successGreen : DesignSystem.Colors.textTertiary
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.85))
                                            .overlay(
                                                Capsule().strokeBorder(
                                                    DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5))
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
                Text("Turn on AI for summaries and chat")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(
                    "MacParakeet can use a local AI app, your API key, or a command-line AI tool. Transcription still works without this."
                )
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            Button {
                onSetUpAI?()
            } label: {
                Label("Set up AI", systemImage: "gearshape")
            }
            .parakeetAction(.secondary)
            .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.accentLight)
        )
    }

    /// Shown above a meeting transcript that has text but no word timestamps
    /// (for example, it was transcribed with Cohere). Makes the
    /// text-only trade-off visible without promising speaker-label quality.
    private var meetingNoWordTimestampsBannerPresentation: MeetingTimedTranscriptRecoveryBannerPresentation? {
        let hasRetainedAudio =
            onRetranscribe != nil
            && (activeTranscription.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        // Resolve the rerun choice from the live transcription so the banner
        // stays in sync with what's actually shown.
        let timestampCapableRerun: SpeechEngineSelection? =
            hasRetainedAudio
            ? viewModel.retranscriptionEngineOption(for: activeTranscription)?
                .firstTimestampCapableChoice?.selection
            : nil
        return MeetingTimedTranscriptRecoveryBannerPresentation.make(
            transcriptText: transcriptText,
            hasRetainedAudio: hasRetainedAudio,
            timestampCapableRerun: timestampCapableRerun
        )
    }

    private func meetingNoWordTimestampsBanner(
        _ presentation: MeetingTimedTranscriptRecoveryBannerPresentation
    ) -> some View {
        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(presentation.message)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            if let action = presentation.action {
                Button {
                    retranscriptionConfirmation = RetranscriptionConfirmation(
                        transcriptionID: activeTranscription.id,
                        speechEngineOverride: action.selection,
                        speakerSelection: nil,
                        countsOtherSpeakers: false,
                        resetsSpeakerCorrections: viewModel.speakerCorrectionsApplied
                    )
                } label: {
                    Label(
                        action.title,
                        systemImage: "arrow.trianglehead.2.clockwise"
                    )
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.accentLight)
        )
    }

    private func meetingPartialCaptureBanner(
        _ presentation: MeetingPartialCapturePresentation
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warningAmber)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(presentation.message)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.warningAmber.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chatErrorRow(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.errorRed)
            Text(error)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.errorRed)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    private func chatEmptyState(chatVM: TranscriptChatViewModel) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: DesignSystem.Spacing.hero)

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
                            sendChatMessage(chatVM)
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
                        .disabled(chatNotesActionGate.isRunning)
                    }
                }
            }

            Spacer(minLength: DesignSystem.Spacing.hero)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
    }

    // MARK: - Mandala Data

    private var mandalaData: MandalaData {
        if let timestamps = activeTranscription.wordTimestamps, !timestamps.isEmpty {
            return .from(wordTimestamps: timestamps)
        }
        return .from(
            text: activeTranscription.cleanTranscript ?? activeTranscription.rawTranscript
                ?? activeTranscription.fileName,
            durationMs: activeTranscription.durationMs ?? 1000
        )
    }

    // MARK: - Timestamped View

    @ViewBuilder
    private func timestampedView(words _: [WordTimestamp]) -> some View {
        // Compute the highlight map once here, not per row, so a long transcript
        // with an active find doesn't rescan matches for every segment.
        let highlightsByBlockID = findHighlightsByBlockId
        let currentBlockHighlight = findCurrentHighlight
        let attribution = viewModel.speakerAttribution
        let legacyHighlights = highlightsByBlockID.reduce(into: [Int: [NSRange]]()) { result, entry in
            guard case .legacy(let startMs) = entry.key else { return }
            result[startMs] = entry.value
        }
        let effectiveHighlights = highlightsByBlockID.reduce(
            into: [SpeakerEditableSegmentID: [NSRange]]()
        ) { result, entry in
            guard case .effective(let id) = entry.key else { return }
            result[id] = entry.value
        }
        let legacyCurrent = currentBlockHighlight.flatMap { highlight -> (id: Int, range: NSRange)? in
            guard case .legacy(let startMs) = highlight.id else { return nil }
            return (startMs, highlight.range)
        }
        let effectiveCurrent = currentBlockHighlight.flatMap {
            highlight -> (id: SpeakerEditableSegmentID, range: NSRange)? in
            guard case .effective(let id) = highlight.id else { return nil }
            return (id, highlight.range)
        }
        TranscriptTimestampedContentView(
            hasSpeakers: cachedHasSpeakers,
            identifiedTurnCards: cachedIdentifiedTurnCards,
            segments: cachedSegments,
            speakerColorMap: cachedSpeakerColorMap,
            speakerLabelForID: { cachedSpeakerLabelMap[$0] ?? "Unknown" },
            speakerLabelContent: {
                speakerID, speakerLabel, speakerColor, renameContextID, isRenameButtonVisuallyRevealed in
                speakerLabelView(
                    speaker: SpeakerInfo(id: speakerID, label: speakerLabel),
                    color: speakerColor,
                    contextID: renameContextID,
                    font: DesignSystem.Typography.body.weight(.semibold),
                    renameButtonOpacity: SpeakerRenameAccessibility.renameButtonOpacity(
                        isVisuallyRevealed: isRenameButtonVisuallyRevealed
                    )
                )
            },
            isSegmentActive: isSegmentActiveBinarySearch(segmentIndex:),
            timestampLabel: { formatTimestamp(ms: $0) },
            isTimestampSeekable: playerViewModel.playerState == .ready,
            onTimestampTap: { startMs in
                playerViewModel.seek(toMs: startMs)
                if !playerViewModel.isPlaying {
                    playerViewModel.togglePlayPause()
                }
                autoScrollPaused = false
                scrollPauseTask?.cancel()
            },
            usesLazyStack: transcriptBodyUsesLazyStack,
            bodyFont: scaledTranscriptFont,
            highlightRangesByStartMs: legacyHighlights,
            currentHighlight: legacyCurrent,
            textSelectionEnabled: TranscriptBodyLayout.rowTextSelectionEnabled,
            usesEffectiveAttribution: attribution != nil,
            editableSegments: attribution?.editableSegments ?? [],
            effectiveTurnCards: (attribution?.speakers.isEmpty ?? true)
                ? [] : identifiedEffectiveSpeakerTurnCards(attribution?.turns ?? []),
            availableSpeakers: attribution?.speakers ?? [],
            isSpeakerEditing: editingSpeakers,
            isSpeakerActionDisabled: viewModel.isApplyingSpeakerCorrection,
            selectedSegmentIDs: speakerSelection.selectedIDs,
            effectiveIsSegmentActive: { segment in
                let currentMs = playerViewModel.currentTimeMs
                return playerViewModel.playbackMode != .none
                    && currentMs > 0
                    && currentMs >= segment.startMs
                    && currentMs <= segment.endMs
            },
            effectiveHighlightRanges: effectiveHighlights,
            effectiveCurrentHighlight: effectiveCurrent,
            onSelectSegment: selectSpeakerSegment,
            onToggleTurnSelection: toggleSpeakerTurnSelection,
            onBeginSpeakerEditing: beginSpeakerEditing,
            onAssignSegment: { segment, assignment in
                applySpeakerAssignment(assignment, from: segment)
            },
            onCreateSpeakerForSegment: { segment in
                presentNewSpeaker(for: actionSegments(fallback: segment))
            },
            onSplitSegment: presentSplitPicker,
            onAssignTurn: assignSpeakerTurn,
            onCreateSpeakerForTurn: presentNewSpeaker
        )
    }

    private var speakerEditingActionBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("\(speakerSelection.count) selected")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if !speakerSelection.isEmpty {
                Button("Clear") {
                    speakerSelection.clear()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .disabled(viewModel.isApplyingSpeakerCorrection)
                .help("Deselect all transcript segments")
            }

            Menu("Assign to…") {
                ForEach(viewModel.speakerAttribution?.speakers ?? [], id: \.id) { speaker in
                    Button(speaker.label) {
                        assignSelectedSegments(to: .speaker(id: speaker.id))
                    }
                }
            }
            .disabled(speakerSelection.isEmpty || viewModel.isApplyingSpeakerCorrection)

            Button("New speaker…") {
                presentNewSpeaker(for: selectedSpeakerSegments)
            }
            .disabled(speakerSelection.isEmpty || viewModel.isApplyingSpeakerCorrection)

            Button("Unassigned") {
                assignSelectedSegments(to: .unassigned)
            }
            .disabled(speakerSelection.isEmpty || viewModel.isApplyingSpeakerCorrection)

            Spacer()

            Button(action: viewModel.undoSpeakerCorrection) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndoSpeakerCorrection || viewModel.isApplyingSpeakerCorrection)

            Button(action: viewModel.redoSpeakerCorrection) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedoSpeakerCorrection || viewModel.isApplyingSpeakerCorrection)

            if viewModel.speakerCorrectionsApplied {
                Button("Reset") {
                    viewModel.applySpeakerCorrection(.reset)
                }
                .disabled(viewModel.isApplyingSpeakerCorrection)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var selectedSpeakerSegments: [SpeakerEditableSegment] {
        speakerSelection.selectedSegments(from: viewModel.speakerAttribution?.editableSegments ?? [])
    }

    private func selectSpeakerSegment(_ id: SpeakerEditableSegmentID) {
        let modifiers = NSEvent.modifierFlags
        let intent: SpeakerEditSelectionModel.Intent
        if modifiers.contains(.shift) {
            intent = .extendingRange
        } else {
            intent = .toggling
        }
        speakerSelection.select(
            id,
            intent: intent,
            orderedIDs: viewModel.speakerAttribution?.editableSegments.map(\.id) ?? []
        )
    }

    private func beginSpeakerEditing() {
        editingSpeakers = true
        if findBarVisible {
            closeFindBar()
        }
    }

    private func toggleSpeakerTurnSelection(_ ids: [SpeakerEditableSegmentID]) {
        speakerSelection.toggleTurn(
            ids,
            orderedIDs: viewModel.speakerAttribution?.editableSegments.map(\.id) ?? []
        )
    }

    private func actionSegments(fallback: SpeakerEditableSegment) -> [SpeakerEditableSegment] {
        speakerSelection.selectedIDs.contains(fallback.id) ? selectedSpeakerSegments : [fallback]
    }

    private func correctionTarget(for segment: SpeakerEditableSegment) -> SpeakerCorrectionTarget {
        SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: segment.anchorTranscriptSegmentIDs,
            wordRange: segment.wordRange
        )
    }

    private func applySpeakerAssignment(
        _ assignment: SpeakerAssignment,
        from fallback: SpeakerEditableSegment
    ) {
        let targets = actionSegments(fallback: fallback).map(correctionTarget(for:))
        viewModel.applySpeakerCorrection(.assign(targets: targets, to: assignment))
    }

    private func assignSelectedSegments(to assignment: SpeakerAssignment) {
        let targets = selectedSpeakerSegments.map(correctionTarget(for:))
        guard !targets.isEmpty else { return }
        viewModel.applySpeakerCorrection(.assign(targets: targets, to: assignment))
    }

    private func assignSpeakerTurn(
        _ segments: [SpeakerEditableSegment],
        to assignment: SpeakerAssignment
    ) {
        let targets = segments.map(correctionTarget(for:))
        guard !targets.isEmpty else { return }
        viewModel.applySpeakerCorrection(.assign(targets: targets, to: assignment))
    }

    private func presentNewSpeaker(for segments: [SpeakerEditableSegment]) {
        pendingNewSpeakerSegments = segments
        let next = (viewModel.speakerAttribution?.speakers.count ?? 0) + 1
        newSpeakerLabel = "Speaker \(next)"
        showingNewSpeakerPrompt = true
    }

    private func createPendingSpeaker() {
        let label = newSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        viewModel.applySpeakerCorrection(
            .add(
                speaker: ManualSpeaker(id: "user:\(UUID().uuidString)", label: label),
                assigning: pendingNewSpeakerSegments.map(correctionTarget(for:))
            )
        )
        pendingNewSpeakerSegments = []
        newSpeakerLabel = ""
    }

    private func presentSplitPicker(_ segment: SpeakerEditableSegment) {
        guard segment.wordRange.endIndexExclusive - segment.wordRange.startIndex > 1 else { return }
        pendingSplitWordIndex = segment.wordRange.startIndex + 1
        pendingSplitSegment = segment
    }

    private func speakerSplitSheet(_ segment: SpeakerEditableSegment) -> some View {
        let lower = segment.wordRange.startIndex + 1
        let upper = segment.wordRange.endIndexExclusive - 1
        let words = viewModel.speakerAttribution?.words ?? []
        let leftWord = words.indices.contains(pendingSplitWordIndex - 1)
            ? words[pendingSplitWordIndex - 1].word : ""
        let rightWord = words.indices.contains(pendingSplitWordIndex)
            ? words[pendingSplitWordIndex].word : ""
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Split segment")
                .font(DesignSystem.Typography.sectionTitle)
            Text("Choose the word boundary. Text and timestamps stay unchanged.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Stepper(value: $pendingSplitWordIndex, in: lower...upper) {
                Text("\(leftWord)  |  \(rightWord)")
            }
            HStack {
                Spacer()
                Button("Cancel") { pendingSplitSegment = nil }
                Button("Split") {
                    viewModel.applySpeakerCorrection(
                        .split(
                            target: correctionTarget(for: segment),
                            atWordIndex: pendingSplitWordIndex
                        )
                    )
                    pendingSplitSegment = nil
                }
                .parakeetAction(.primary)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 430)
    }

    // MARK: - Speaker Summary Panel

    @ViewBuilder
    private func speakerSummaryPanel(speakers: [SpeakerInfo]) -> some View {
        let colorMap = cachedSpeakerColorMap.isEmpty ? buildSpeakerColorMap() : cachedSpeakerColorMap
        let speakerStats = viewModel.speakerAttribution?.statistics
            ?? cachedSpeakerStats
        let mutationsDisabled = viewModel.speakerAttribution == nil || viewModel.isApplyingSpeakerCorrection

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    speakerOverviewExpanded.toggle()
                }
            } label: {
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
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SpeakerRenameAccessibility.overviewToggleLabel(isExpanded: speakerOverviewExpanded))
            .accessibilityHint(SpeakerRenameAccessibility.overviewToggleHint)
            .accessibilityIdentifier(SpeakerRenameAccessibility.overviewToggleIdentifier)

            if speakerOverviewExpanded {
                HStack {
                    Spacer()
                    Button {
                        presentNewSpeaker(for: [])
                    } label: {
                        Label("Add speaker", systemImage: "plus")
                    }
                    .parakeetAction(.secondary)
                    .disabled(mutationsDisabled)
                }
                ForEach(speakers, id: \.id) { speaker in
                    let stats = speakerStats[speaker.id]
                    HStack(spacing: DesignSystem.Spacing.md) {
                        Circle()
                            .fill(colorMap[speaker.id] ?? DesignSystem.Colors.textTertiary)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 6) {
                            speakerLabelView(
                                speaker: speaker,
                                color: colorMap[speaker.id] ?? DesignSystem.Colors.textSecondary,
                                contextID: SpeakerRenameAccessibility.overviewRenameContextIdentifier(for: speaker.id)
                            )
                            .disabled(mutationsDisabled)
                            .allowsHitTesting(!mutationsDisabled)

                            if let stats {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    metadataChip(
                                        icon: "clock", text: formatSpeakingTime(ms: stats.speakingTimeMs),
                                        tint: DesignSystem.Colors.textSecondary)
                                    metadataChip(
                                        icon: "text.word.spacing", text: "\(stats.wordCount.formatted()) words",
                                        tint: DesignSystem.Colors.textSecondary)
                                }
                            }
                        }

                        Spacer()

                        Menu {
                            Button("Rename…") {
                                beginSpeakerRename(
                                    speaker,
                                    contextID: SpeakerRenameAccessibility.overviewRenameContextIdentifier(
                                        for: speaker.id
                                    )
                                )
                            }

                            Menu("Merge into…") {
                                ForEach(speakers.filter { $0.id != speaker.id }, id: \.id) { target in
                                    Button(target.label) {
                                        viewModel.applySpeakerCorrection(
                                            .merge(
                                                sourceSpeakerID: speaker.id,
                                                targetSpeakerID: target.id
                                            )
                                        )
                                    }
                                }
                            }
                            .disabled(AudioSource(rawValue: speaker.id) != nil)

                            if (stats?.wordCount ?? 0) == 0 {
                                Button("Remove speaker", role: .destructive) {
                                    viewModel.applySpeakerCorrection(
                                        .remove(speakerID: speaker.id, reassignTo: nil)
                                    )
                                }
                                .disabled(AudioSource(rawValue: speaker.id) != nil)
                            } else {
                                Menu("Remove and reassign…") {
                                    ForEach(speakers.filter { $0.id != speaker.id }, id: \.id) { target in
                                        Button(target.label) {
                                            viewModel.applySpeakerCorrection(
                                                .remove(
                                                    speakerID: speaker.id,
                                                    reassignTo: .speaker(id: target.id)
                                                )
                                            )
                                        }
                                    }
                                    Divider()
                                    Button("Leave unassigned") {
                                        viewModel.applySpeakerCorrection(
                                            .remove(speakerID: speaker.id, reassignTo: .unassigned)
                                        )
                                    }
                                }
                                .disabled(AudioSource(rawValue: speaker.id) != nil)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(speaker.label)")
                        .disabled(mutationsDisabled)
                    }
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.45))
                    )
                }
                Text("Speaker labels are approximate.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.25))
        )
    }

    @ViewBuilder
    private func speakerLabelView(
        speaker: SpeakerInfo,
        color: Color,
        contextID: String,
        font: Font = DesignSystem.Typography.caption.weight(.semibold),
        renameButtonOpacity: Double = SpeakerRenameAccessibility.renameButtonOpacity(isVisuallyRevealed: true)
    ) -> some View {
        if editingSpeakerId == speaker.id, editingSpeakerContextID == contextID {
            TextField("Name", text: $editingSpeakerLabel)
                .font(font)
                .foregroundStyle(color)
                .textFieldStyle(.plain)
                .frame(minWidth: 60, maxWidth: 200)
                .focused($speakerRenameFocused)
                .task { speakerRenameFocused = true }
                .onSubmit {
                    commitSpeakerRename()
                }
                .onExitCommand {
                    cancelSpeakerRename()
                }
                .onChange(of: speakerRenameFocused) {
                    if !speakerRenameFocused {
                        commitSpeakerRename()
                    }
                }
                .accessibilityLabel(SpeakerRenameAccessibility.speakerNameFieldLabel)
                .accessibilityHint(SpeakerRenameAccessibility.speakerNameFieldHint)
                .accessibilityIdentifier(SpeakerRenameAccessibility.speakerNameFieldIdentifier(contextID: contextID))
        } else {
            HStack(spacing: 6) {
                Text(speaker.label)
                    .font(font)
                    .foregroundStyle(color)
                    .onTapGesture {
                        beginSpeakerRename(speaker, contextID: contextID)
                    }

                Button {
                    beginSpeakerRename(speaker, contextID: contextID)
                } label: {
                    Label(SpeakerRenameAccessibility.renameButtonLabel(for: speaker.label), systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .parakeetAction(.subtle)
                .controlSize(.small)
                .help(SpeakerRenameAccessibility.renameButtonLabel(for: speaker.label))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpeakerRenameAccessibility.renameButtonLabel(for: speaker.label))
                .accessibilityHint(SpeakerRenameAccessibility.renameButtonHint)
                .accessibilityIdentifier(SpeakerRenameAccessibility.renameButtonIdentifier(contextID: contextID))
                .opacity(renameButtonOpacity)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func beginSpeakerRename(_ speaker: SpeakerInfo, contextID: String) {
        if editingSpeakerId != nil, editingSpeakerId != speaker.id || editingSpeakerContextID != contextID {
            commitSpeakerRename()
        }
        editingSpeakerId = speaker.id
        editingSpeakerContextID = contextID
        editingSpeakerLabel = speaker.label
    }

    private func commitSpeakerRename() {
        guard let speakerId = editingSpeakerId else { return }
        let trimmed = editingSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            viewModel.renameSpeaker(id: speakerId, to: trimmed)
            if transcriptDisplayMode == .timed {
                scheduleSegmentCacheRebuild()
            }
        }
        cancelSpeakerRename()
    }

    private func cancelSpeakerRename() {
        editingSpeakerId = nil
        editingSpeakerContextID = nil
        editingSpeakerLabel = ""
        speakerRenameFocused = false
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

    // MARK: - Segment Cache

    private func handleDisappear() {
        navigationNotesActionGate.invalidate()
        promptNotesActionGate.invalidate()
        chatNotesActionGate.invalidate()
        richContextLoader.invalidate()
        let notesEditor = savedMeetingNotesViewModel
        Task<Void, Never> { @MainActor in
            _ = await notesEditor.flush()
        }
        playerViewModel.cleanup()
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        scrollPauseTask?.cancel()
    }

    private func scheduleRichAIContextLoad() {
        let transcription = activeTranscription
        let mode = currentAIContextMode
        let revision = viewModel.currentTranscriptionRevision
        let viewModel = viewModel
        let chatViewModel = chatViewModel
        richContextLoader.schedule(
            transcription: transcription,
            mode: mode,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        ) { request, text in
            guard viewModel.currentTranscriptionRevision == request.contentRevision,
                  viewModel.speakerAttribution?.correctionRevision == request.speakerCorrectionRevision
            else { return }
            guard (viewModel.currentTranscription?.id ?? transcription.id) == request.transcriptionID else {
                return
            }
            guard currentAIContextMode == request.mode else { return }
            chatViewModel.updateTranscriptText(text)
        }
    }

    private func scheduleSegmentCacheRebuild() {
        let words = activeTranscription.wordTimestamps
        let speakers = activeTranscription.speakers
        let diarizationSegments = activeTranscription.diarizationSegments
        let transcriptionID = activeTranscription.id
        let requestID = UUID()
        segmentCacheRequestID = requestID

        guard let words, !words.isEmpty else {
            applyEmptySegmentCache()
            return
        }

        cachedTranscriptRowCount = nil

        Task {
            let payload = await Task.detached(priority: .userInitiated) {
                TranscriptSegmentCachePayload.make(
                    words: words,
                    speakers: speakers,
                    diarizationSegments: diarizationSegments
                )
            }.value
            guard segmentCacheRequestID == requestID else { return }
            guard activeTranscription.id == transcriptionID else { return }
            applySegmentCache(payload)
        }
    }

    private func applySegmentCache(_ payload: TranscriptSegmentCachePayload) {
        cachedSegments = payload.segments
        cachedHasSpeakers = payload.hasSpeakers
        cachedSpeakerLabelMap = payload.speakerLabelMap
        cachedSpeakerStats = payload.speakerStats
        cachedTranscriptRowCount = payload.rowCount
        cachedSegmentStartMs = payload.segments.map(\.startMs)
        cachedSpeakerColorMap = buildSpeakerColorMap()
        cachedIdentifiedTurnCards =
            payload.hasSpeakers
            ? identifiedSpeakerTurnCards(payload.speakerTurns)
            : []
        if findBarVisible { rebuildFindBlocks() }
    }

    private func applyEmptySegmentCache() {
        segmentCacheRequestID = UUID()
        cachedSegments = []
        cachedTranscriptRowCount = 0
        cachedIdentifiedTurnCards = []
        cachedHasSpeakers = false
        cachedSpeakerColorMap = [:]
        cachedSpeakerLabelMap = [:]
        cachedSpeakerStats = [:]
        cachedSegmentStartMs = []
        if findBarVisible { rebuildFindBlocks() }
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

    /// Find the scroll target ID (segment startMs) for the given playback time.
    private func autoScrollTarget(for currentMs: Int) -> Int? {
        if cachedHasSpeakers {
            return speakerTurnCardScrollTarget(
                for: currentMs,
                in: cachedIdentifiedTurnCards
            )
        } else {
            if let idx = activeSegmentIndex(for: currentMs) {
                return cachedSegmentStartMs[idx]
            }
        }
        return nil
    }

    // MARK: - Speaker Helpers

    private func buildSpeakerColorMap() -> [String: Color] {
        let speakers = viewModel.speakerAttribution?.speakers
            ?? activeTranscription.speakers
            ?? []
        var map: [String: Color] = [:]
        for speaker in speakers {
            var stableHash: UInt64 = 14_695_981_039_346_656_037
            for byte in speaker.id.utf8 {
                stableHash ^= UInt64(byte)
                stableHash &*= 1_099_511_628_211
            }
            let slot = Int(stableHash % UInt64(DesignSystem.Colors.speakerColors.count))
            map[speaker.id] = DesignSystem.Colors.speakerColor(for: slot)
        }
        return map
    }

    private func buildSpeakerLabelMap() -> [String: String] {
        guard let speakers = activeTranscription.speakers else { return [:] }
        var map: [String: String] = [:]
        for speaker in speakers {
            map[speaker.id] = speaker.label
        }
        return map
    }

    private func syncTranscriptDisplayMode() {
        transcriptDisplayMode = (hasCleanTranscriptText || !hasTimestamps) ? .text : .timed
    }

    private var normalizedMeetingNotesDraft: String? {
        guard savedMeetingNotesViewModel.meetingID == activeTranscription.id else { return nil }
        let notes = savedMeetingNotesViewModel.text
        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return notes
    }

    private func requestMeetingNotesNavigation(_ action: MeetingNotesNavigationAction) {
        let navigate: (() -> Void)?
        switch action {
        case .navigateBack: navigate = onBack
        case .startNewTranscription: navigate = onStartNew
        }
        startMeetingNotesNavigation { navigate?() }
    }

    private func startMeetingNotesNavigation(
        isCurrent: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void
    ) {
        let selectedID = activeTranscription.id
        let notesEditor = savedMeetingNotesViewModel
        navigationNotesActionGate.start(
            flush: { await notesEditor.flush() },
            isCurrent: {
                transcription.id == selectedID
                    && viewModel.currentTranscription?.id == selectedID
                    && savedMeetingNotesViewModel === notesEditor
                    && isCurrent()
            },
            onFailure: { viewModel.selectedTab = .notes }
        ) {
            action()
        }
    }

    private func configureSavedMeetingNotes(for transcription: Transcription) {
        let previousEditor = savedMeetingNotesViewModel
        if transcription.sourceType == .meeting {
            savedMeetingNotesViewModel = SavedMeetingNotesCoordinator.shared.editor(
                meetingID: transcription.id,
                text: transcription.userNotes,
                isMeetingDeleted: { [viewModel, transcription] in
                    try await viewModel.isMeetingDeleted(id: transcription.id)
                }
            ) { [viewModel, transcription] text in
                await viewModel.updateMeetingNotes(for: transcription, to: text)
            }
        } else {
            savedMeetingNotesViewModel = SavedMeetingNotesViewModel()
        }
        // Bind the new meeting immediately; a failed old save remains owned by
        // the coordinator and can be retried on reopening or before quit.
        if previousEditor !== savedMeetingNotesViewModel, previousEditor.hasUnsavedChanges {
            Task { @MainActor in
                _ = await previousEditor.flush()
            }
        }
    }

    private func retrySavedMeetingNotes() {
        let notesEditor = savedMeetingNotesViewModel
        Task { @MainActor in
            await notesEditor.retry()
        }
    }

    private func sendChatMessage(
        _ chatViewModel: TranscriptChatViewModel,
        richPrompt: String? = nil
    ) {
        let selectedID = activeTranscription.id
        let notesEditor = savedMeetingNotesViewModel
        let inputText = chatViewModel.inputText
        let conversationID = chatViewModel.currentConversation?.id
        chatNotesActionGate.start(
            flush: { await notesEditor.flush() },
            isCurrent: {
                viewModel.currentTranscription?.id == selectedID
                    && savedMeetingNotesViewModel === notesEditor
                    && notesEditor.saveState != .deleted
                    && chatViewModel.currentConversation?.id == conversationID
                    && chatViewModel.inputText == inputText
            }
        ) {
            chatViewModel.sendMessage(richPrompt: richPrompt)
            chatInputFocused = true
        }
    }

    private func beginTranscriptEdit() {
        transcriptDraft = transcriptText
        transcriptEditError = nil
        transcriptDisplayModeBeforeEdit = transcriptDisplayMode
        editingTranscript = true
        transcriptDisplayMode = .text
        Task { @MainActor in
            transcriptEditorFocused = true
        }
    }

    private func cancelTranscriptEdit() {
        transcriptDraft = ""
        transcriptEditError = nil
        editingTranscript = false
        transcriptDisplayMode = transcriptDisplayModeBeforeEdit ?? transcriptDisplayMode
        transcriptDisplayModeBeforeEdit = nil
    }

    private func commitTranscriptEdit() {
        let trimmed = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptEditError = "Transcript text cannot be empty."
            SoundManager.shared.play(.errorSoft)
            return
        }

        if trimmed == transcriptText {
            cancelTranscriptEdit()
            return
        }

        guard viewModel.updateCurrentTranscriptText(to: transcriptDraft) else {
            transcriptEditError = "Could not save transcript edits."
            SoundManager.shared.play(.errorSoft)
            return
        }

        chatViewModel.loadTranscript(transcriptText, transcriptionId: viewModel.currentTranscription?.id)
        scheduleRichAIContextLoad()
        transcriptDraft = ""
        transcriptEditError = nil
        editingTranscript = false
        transcriptDisplayMode = .text
        transcriptDisplayModeBeforeEdit = nil
        SoundManager.shared.play(.transcriptionComplete)
    }

    private func revertTranscriptEdit() {
        guard viewModel.revertCurrentTranscriptToOriginal() else { return }
        chatViewModel.loadTranscript(transcriptText, transcriptionId: viewModel.currentTranscription?.id)
        scheduleRichAIContextLoad()
        transcriptDraft = ""
        transcriptEditError = nil
        editingTranscript = false
        transcriptDisplayMode = hasTimestamps ? .timed : .text
        transcriptDisplayModeBeforeEdit = nil
        SoundManager.shared.play(.transcriptionComplete)
    }

    // MARK: - Actions

    private func copyMeetingToClipboard() {
        let markdown = MeetingMarkdownRenderer().renderForClipboard(
            transcription: activeTranscription
        )
        TranscriptResultActions.copyText(markdown, source: .meeting)
        showCopiedFeedback()
    }

    private func copyTranscriptToClipboard() {
        TranscriptResultActions.copyText(transcriptText)
        showCopiedFeedback()
    }

    private func showCopiedFeedback() {
        copiedResetTask?.cancel()
        withAnimation(DesignSystem.Animation.hoverTransition) { copied = true }
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.Animation.hoverTransition) { copied = false }
        }
    }

    private var hasTimestamps: Bool {
        activeTranscription.hasWordTimestamps
    }

    private var hasAlignedTimestampsForExport: Bool {
        hasTimestamps && !hasEditedTranscript
    }

    private var hasSpeakerLabelsForExport: Bool {
        !hasEditedTranscript && activeTranscription.hasSpeakerLabeledWords
    }

    /// Whether "Include timestamps" applies to the current selection: the format
    /// must take transcript options *and* the transcript must have aligned
    /// timestamps to include.
    private var canIncludeTimestampsOption: Bool {
        selectedExportFormat.supportsTranscriptOptions && hasAlignedTimestampsForExport
    }

    private var canIncludeSpeakerLabelsOption: Bool {
        selectedExportFormat.supportsTranscriptOptions && hasSpeakerLabelsForExport
    }

    /// Caption shown under a disabled "Include timestamps" toggle. `nil` when the
    /// option is available, or when the format takes no options (the section is
    /// hidden in that case, so no caption is needed).
    private var timestampsUnavailableReason: String? {
        guard selectedExportFormat.supportsTranscriptOptions,
            !hasAlignedTimestampsForExport
        else { return nil }
        if !hasTimestamps { return "This transcript has no word timestamps." }
        return "Unavailable after editing the transcript text."
    }

    private var speakerLabelsUnavailableReason: String? {
        guard selectedExportFormat.supportsTranscriptOptions,
            !hasSpeakerLabelsForExport
        else { return nil }
        if activeTranscription.hasSpeakerLabeledWords {
            return "Unavailable after editing the transcript text."
        }
        return "This transcript has no speaker labels."
    }

    private var resolvedTranscriptExportOptions: TranscriptExportOptions {
        transcriptExportOptions.resolved(
            canIncludeTimestamps: hasAlignedTimestampsForExport,
            canIncludeSpeakerLabels: hasSpeakerLabelsForExport
        )
    }

    private var exportFormatOrder: [TranscriptExportFormat] {
        [.txt, .md, .srt, .vtt, .dapt, .json, .pdf, .docx]
    }

    private var exportOptionsPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Export Transcript", systemImage: "arrow.down.doc")
                    .font(DesignSystem.Typography.body.bold())

                Spacer()

                Button {
                    showingExportOptions = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close export options")
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Format")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(exportFormatOrder) { format in
                        Button {
                            selectedExportFormat = format
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: format.iconName)
                                    .frame(width: 16)
                                Text(format.shortName)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .font(DesignSystem.Typography.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        selectedExportFormat == format
                                            ? DesignSystem.Colors.accent.opacity(0.14)
                                            : DesignSystem.Colors.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        selectedExportFormat == format
                                            ? DesignSystem.Colors.accent.opacity(0.7)
                                            : DesignSystem.Colors.border.opacity(0.7),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // The Options toggles apply only to Text/Markdown. Other formats
            // have fixed mappings, so showing disabled toggles would be noise.
            if selectedExportFormat.supportsTranscriptOptions {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Options")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    exportOptionToggle(
                        "Include timestamps",
                        isOn: $transcriptExportOptions.includeTimestamps,
                        isEnabled: canIncludeTimestampsOption,
                        unavailableReason: timestampsUnavailableReason
                    )

                    exportOptionToggle(
                        "Include speaker labels",
                        isOn: $transcriptExportOptions.includeSpeakerLabels,
                        isEnabled: canIncludeSpeakerLabelsOption,
                        unavailableReason: speakerLabelsUnavailableReason
                    )

                    Toggle("Include metadata", isOn: $transcriptExportOptions.includeMetadata)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    showingExportOptions = false
                    exportToDownloads(format: selectedExportFormat)
                } label: {
                    Label("Export", systemImage: "arrow.down.doc")
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 380)
    }

    /// An export option toggle that shows its *effective* state. When the option
    /// is unavailable it renders unchecked and disabled — rather than checked and
    /// greyed, which reads as "forced on" and contradicts the export, which omits
    /// the missing data. An optional caption explains why it is unavailable.
    @ViewBuilder
    private func exportOptionToggle(
        _ title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool,
        unavailableReason: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(
                title,
                isOn: Binding(
                    get: { isEnabled && isOn.wrappedValue },
                    set: { isOn.wrappedValue = $0 }
                )
            )
            .disabled(!isEnabled)

            if let unavailableReason {
                Text(unavailableReason)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
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
                    Text(confirmation.title)
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
            .parakeetAction(.secondary)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(minWidth: 220)
    }

    private func exportGenerationToDownloads(promptResult: PromptResult, format: TranscriptExportFormat) {
        let source = activeTranscription
        do {
            let fileURL = try TranscriptResultActions.exportPromptResultToDownloads(
                promptResult: promptResult,
                source: source,
                format: format
            )
            exportErrorMessage = nil
            SoundManager.shared.play(.transcriptionComplete)
            dismissTask?.cancel()
            exportConfirmation = ExportConfirmation(
                url: fileURL,
                title: "Exported \(format.displayName)"
            )
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5.0))
                guard !Task.isCancelled else { return }
                exportConfirmation = nil
            }
        } catch let cocoaError as CocoaError where cocoaError.code == .fileNoSuchFile {
            exportErrorMessage = "Your Downloads folder could not be found."
            SoundManager.shared.play(.errorSoft)
        } catch {
            exportErrorMessage = error.localizedDescription
            SoundManager.shared.play(.errorSoft)
        }
    }

    private func exportToDownloads(format: TranscriptExportFormat) {
        // Use the ViewModel's copy which reflects any in-flight renames
        let source = activeTranscription
        do {
            let fileURL = try TranscriptResultActions.exportTranscriptToDownloads(
                transcription: source,
                format: format,
                options: format.supportsTranscriptOptions ? resolvedTranscriptExportOptions : .default
            )
            exportErrorMessage = nil
            SoundManager.shared.play(.transcriptionComplete)
            dismissTask?.cancel()
            exportConfirmation = ExportConfirmation(
                url: fileURL,
                title: "Exported \(format.displayName)"
            )
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5.0))
                guard !Task.isCancelled else { return }
                exportConfirmation = nil
            }
        } catch let cocoaError as CocoaError where cocoaError.code == .fileNoSuchFile {
            exportErrorMessage = "Your Downloads folder could not be found."
            SoundManager.shared.play(.errorSoft)
        } catch {
            exportErrorMessage = error.localizedDescription
            SoundManager.shared.play(.errorSoft)
        }
    }

    /// Drives the "Save Audio As…" item in the meeting action bar's
    /// Audio menu. Reuses the existing exportConfirmation popover on
    /// success and the existing exportErrorMessage alert on failure.
    private func saveMeetingAudioFromActionBar() {
        let source = activeTranscription
        Task { @MainActor in
            do {
                let outcome = try await MeetingAudioActions.runSaveAudioPanel(for: source)
                switch outcome {
                case .saved(let destination):
                    SoundManager.shared.play(.transcriptionComplete)
                    dismissTask?.cancel()
                    exportConfirmation = ExportConfirmation(
                        url: destination,
                        title: "Saved Audio"
                    )
                    dismissTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5.0))
                        guard !Task.isCancelled else { return }
                        exportConfirmation = nil
                    }
                case .cancelled:
                    break
                case .sourceUnavailable:
                    exportErrorMessage = "The meeting audio file is no longer available."
                    SoundManager.shared.play(.errorSoft)
                }
            } catch {
                exportErrorMessage = error.localizedDescription
                SoundManager.shared.play(.errorSoft)
            }
        }
    }

    private func deleteMeetingAudioFromActionBar() {
        viewModel.deleteMeetingAudio(activeTranscription)
    }

    private func formatTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct EngineOptionCard: View {
    let selection: SpeechEngineSelection
    let nemotronVariant: NemotronModelVariant
    let parakeetVariant: ParakeetModelVariant
    let isPrimary: Bool
    /// When this is the primary card, whether it names the engine that produced
    /// the transcript ("Original") rather than a fall-back to the user's current
    /// default ("Current"). Ignored on non-primary cards.
    let primaryReflectsTranscriptEngine: Bool
    let isAvailable: Bool
    let unavailableReason: String?
    let advisory: String?
    let onSelect: () -> Void

    @State private var hovering = false

    private var iconName: String {
        switch selection.engine {
        case .parakeet: "bolt.fill"
        case .nemotron: "sparkles"
        case .whisper: "globe"
        case .cohere: "waveform"
        }
    }

    private var subtitle: String {
        switch selection.engine {
        case .parakeet:
            switch parakeetVariant {
            case .v3: "Fast local default • word timestamps"
            case .v2: "English stability • word timestamps"
            case .unified: "Readable English • word timestamps"
            }
        case .nemotron:
            nemotronVariant.isEnglishOnly
                ? "Beta English streaming • quality still being validated"
                : "Beta multilingual streaming • quality varies by language"
        case .whisper:
            "Broad-language fallback • files and saved audio"
        case .cohere:
            "Batch plain text • no timestamps or speaker labels"
        }
    }

    private var languageDetail: String? {
        guard selection.engine == .whisper || selection.engine == .nemotron else { return nil }
        if selection.engine == .nemotron, nemotronVariant.isEnglishOnly {
            // The English-only build ignores language hints.
            return "Language: English"
        }
        let language = selection.language ?? "auto-detect"
        return "Language: \(language)"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(selection.engine.displayName)
                            .font(DesignSystem.Typography.body.weight(.semibold))
                            .foregroundStyle(titleColor)
                        if isPrimary {
                            EngineBadge(
                                text: primaryReflectsTranscriptEngine ? "Original" : "Current",
                                tint: DesignSystem.Colors.accent
                            )
                        }
                        if !isAvailable {
                            EngineBadge(text: "Unavailable", tint: DesignSystem.Colors.warningAmber)
                        }
                    }
                    .lineLimit(1)

                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let languageDetail {
                        Text(languageDetail)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }

                    if let advisory, isAvailable {
                        Text(advisory)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let unavailableReason, !isAvailable {
                        Text(unavailableReason)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, DesignSystem.Spacing.sm + 2)
            .padding(.horizontal, DesignSystem.Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .onHover { isHovering in
            guard isAvailable else { return }
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hovering = isHovering
            }
        }
        .help(helpText)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(accessibilityHint))
    }

    private var helpText: String {
        if !isAvailable {
            return unavailableReason ?? "Unavailable for this rerun."
        }
        if let advisory {
            return "\(advisory) Rerun with \(selection.engine.displayName)."
        }
        return "Rerun with \(selection.engine.displayName)."
    }

    private var iconColor: Color {
        guard isAvailable else { return DesignSystem.Colors.textTertiary }
        return DesignSystem.Colors.accent
    }

    private var titleColor: Color {
        isAvailable ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
    }

    private var backgroundFill: Color {
        if !isAvailable {
            return DesignSystem.Colors.surfaceElevated.opacity(0.5)
        }
        return hovering ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated
    }

    private var borderColor: Color {
        if !isAvailable {
            return DesignSystem.Colors.border.opacity(0.6)
        }
        return hovering ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border
    }

    private var accessibilityLabel: String {
        var parts = [selection.engine.displayName]
        if isPrimary {
            parts.append(primaryReflectsTranscriptEngine ? "engine used for this transcript" : "current engine")
        }
        if !isAvailable { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if !isAvailable {
            return unavailableReason ?? "Unavailable for this rerun."
        }
        if let advisory {
            return "\(advisory) Reruns this transcription with \(selection.engine.displayName)."
        }
        return "Reruns this transcription with \(selection.engine.displayName)."
    }
}

private struct EngineBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.28), lineWidth: 0.5)
            )
    }
}

private struct TranscriptSegmentCachePayload: Sendable {
    let segments: [TranscriptSegment]
    let speakerTurns: [SpeakerTurn]
    let speakerStats: [String: SpeakerStatistics]
    let rowCount: Int
    let hasSpeakers: Bool
    let speakerLabelMap: [String: String]

    static func make(
        words: [WordTimestamp],
        speakers: [SpeakerInfo]?,
        diarizationSegments: [DiarizationSegmentRecord]?
    ) -> TranscriptSegmentCachePayload {
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        let hasSpeakers = words.contains { $0.speakerId != nil }
        var speakerLabelMap: [String: String] = [:]
        if let speakers {
            for speaker in speakers {
                speakerLabelMap[speaker.id] = speaker.label
            }
        }
        let speakerTurns =
            hasSpeakers
            ? TranscriptSegmenter.groupIntoSpeakerTurns(
                segments: segments,
                speakerLabelProvider: { speakerID in
                    guard let speakerID else { return "Unknown" }
                    return speakerLabelMap[speakerID] ?? "Unknown"
                }
            )
            : []
        return TranscriptSegmentCachePayload(
            segments: segments,
            speakerTurns: speakerTurns,
            speakerStats: TranscriptSegmenter.computeSpeakerStats(
                diarizationSegments: diarizationSegments,
                wordTimestamps: words
            ),
            rowCount: hasSpeakers
                ? speakerTurns.reduce(0) { $0 + $1.segments.count }
                : segments.count,
            hasSpeakers: hasSpeakers,
            speakerLabelMap: speakerLabelMap
        )
    }
}

private extension String {
    func stringIndex(utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0,
            let utf16Index = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex)
        else {
            return nil
        }
        return String.Index(utf16Index, within: self)
    }
}
