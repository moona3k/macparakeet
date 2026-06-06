import Foundation
import MacParakeetCore
import SwiftUI

@MainActor @Observable
public final class MeetingRecordingPanelViewModel {
    public enum PanelState: Equatable {
        case hidden
        case recording
        case transcribing
        case error(String)
    }

    public enum LiveTranscriptStatus: Equatable, Sendable {
        case startingAudio
        case preparingSpeechModel(message: String?)
        case listening
        case live
        case previewUnavailable
    }

    /// Tab order chosen so the user lands in Notes by default — note-taking is
    /// the primary "active" surface in a live meeting (ADR-020 §1, §2). Transcript
    /// is the rolling reference, Ask is the on-demand thinking-partner.
    public enum LivePanelTab: String, Equatable, CaseIterable, Sendable {
        case notes
        case transcript
        case ask

        public var title: String {
            switch self {
            case .notes: return "Notes"
            case .transcript: return "Transcript"
            case .ask: return "Ask"
            }
        }
    }

    public var state: PanelState = .hidden
    public var elapsedSeconds: Int = 0
    public var micLevel: Float = 0
    public var systemLevel: Float = 0
    /// Mirrors `MeetingRecordingService.isPaused`, set by the flow
    /// coordinator's polling task.
    public var isPaused: Bool = false
    /// Meeting-local mic mute. Unlike pause, system audio keeps recording.
    public var isMicrophoneMuted: Bool = false
    public var canToggleMicrophoneMute: Bool = false
    public var previewLines: [MeetingRecordingPreviewLine] = []
    public var isTranscriptionLagging: Bool = false
    public private(set) var liveTranscriptStatus: LiveTranscriptStatus = .listening
    public var showCopiedConfirmation: Bool = false
    /// Default to `.notes` per ADR-020 §2 — opening the panel should put the
    /// cursor in the notepad, not stare the user down with raw transcript.
    public var selectedTab: LivePanelTab = .notes
    public let chatViewModel: TranscriptChatViewModel = TranscriptChatViewModel()
    public let notesViewModel: MeetingNotesViewModel = MeetingNotesViewModel()
    public let quickPromptsViewModel: QuickPromptsViewModel = QuickPromptsViewModel()
    public var onStop: (() -> Void)?
    public var onPauseToggle: (() -> Void)?
    public var onMicrophoneMuteToggle: (() -> Void)?
    public var onClose: (() -> Void)?

    private var copiedResetTask: Task<Void, Never>?
    private var previewLineWordCounts: [Int] = []
    private let transcriptAIContextModeProvider: @MainActor () -> TranscriptAIContextMode

    public init(
        transcriptAIContextModeProvider: @escaping @MainActor () -> TranscriptAIContextMode = {
            TranscriptAIContextMode.current()
        }
    ) {
        self.transcriptAIContextModeProvider = transcriptAIContextModeProvider
        // Mark the chat VM as the live in-meeting Ask surface so
        // `llm_chat_used` telemetry distinguishes Ask chat from
        // post-transcription transcript chat. Without this the two sources
        // collapse into one bucket and Ask adoption is invisible.
        chatViewModel.markAsMeetingAskSurface()

        // Thread the live notepad into the live Ask chat: the closure is
        // called by `TranscriptChatViewModel` at chat-send time, so the
        // freshest keystroke up to the moment the user hits Send is what the
        // LLM sees alongside the rolling transcript. See ADR-020 (post-revert
        // amendment) for why this is safe even though we reverted the
        // memo-steered auto-run prompt — chat is user-initiated, so empty
        // notes don't produce nonsense output.
        chatViewModel.bindUserNotesProvider { [weak notesViewModel] in
            notesViewModel?.notesText
        }
    }

    /// Show "Copied" confirmation and auto-dismiss after 1.5s.
    /// Owns the timer so the View doesn't need @State Task.
    public func showCopiedFeedback() {
        showCopiedConfirmation = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showCopiedConfirmation = false
        }
    }

    public func updatePreviewLines(
        _ lines: [MeetingRecordingPreviewLine],
        isTranscriptionLagging: Bool = false
    ) {
        if let firstChangedIndex = Self.firstChangedLineIndex(
            oldLines: previewLines,
            newLines: lines
        ) {
            let removedWordCount = firstChangedIndex < previewLineWordCounts.count
                ? previewLineWordCounts[firstChangedIndex...].reduce(0, +)
                : 0
            let addedWordCounts = firstChangedIndex < lines.count
                ? lines[firstChangedIndex...].map { Self.wordCount(for: $0.text) }
                : []
            wordCount += addedWordCounts.reduce(0, +) - removedWordCount
            previewLineWordCounts = Array(previewLineWordCounts.prefix(firstChangedIndex)) + addedWordCounts
            previewLines = lines
            if !lines.isEmpty {
                liveTranscriptStatus = .live
            }
            // Keep the live Ask tab fed with the latest transcript without disturbing
            // chat history. The transcript AI context preference decides whether
            // future sends use rich timestamp/speaker context or plain text.
            chatViewModel.updateTranscriptText(chatTranscript)
        }
        self.isTranscriptionLagging = isTranscriptionLagging
    }

    public var transcriptText: String {
        previewLines.map { "[\($0.timestamp)] \($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }

    public var chatTranscript: String {
        switch transcriptAIContextModeProvider() {
        case .richTranscript:
            return transcriptText
        case .plainTranscript:
            return previewLines.map(\.text).joined(separator: "\n")
        }
    }

    public var canCopy: Bool {
        !previewLines.isEmpty
    }

    public private(set) var wordCount: Int = 0

    public func reset() {
        state = .hidden
        elapsedSeconds = 0
        micLevel = 0
        systemLevel = 0
        isPaused = false
        isMicrophoneMuted = false
        canToggleMicrophoneMute = false
        previewLines = []
        previewLineWordCounts = []
        wordCount = 0
        isTranscriptionLagging = false
        liveTranscriptStatus = .listening
        copiedResetTask?.cancel()
        showCopiedConfirmation = false
        selectedTab = .notes
        notesViewModel.reset()
    }

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public var canStop: Bool {
        if case .recording = state {
            return true
        }
        return false
    }

    /// Header Pause/Resume button is only meaningful while the meeting is
    /// in `.recording` panel state. Hidden during transcribing / error.
    public var canTogglePause: Bool {
        canStop
    }

    public var statusTitle: String {
        switch state {
        case .hidden, .recording:
            return isPaused ? "Paused" : "Recording"
        case .transcribing:
            return "Transcribing"
        case .error:
            return "Meeting interrupted"
        }
    }

    public var statusMessage: String {
        switch state {
        case .hidden, .recording:
            if isTranscriptionLagging {
                return "Live transcript preview is catching up. The final transcript will still include the full meeting."
            }
            return "Live transcript preview updates while the flower pill stays pinned."
        case .transcribing:
            return "Meeting audio is being transcribed and saved to your library."
        case .error(let message):
            // ADR-020 §"degradation copy refinement". The state machine fires
            // `.showError(message)` from both `startFailed` (recording never
            // started — permissions, audio engine, etc.) and
            // `transcriptionFailed` (audio captured fine; STT failed). We
            // can't reliably distinguish those paths from the message
            // string alone, so the wrapper hedges with "if any audio was
            // captured" rather than promising the recording is safe.
            // Action guidance points the user at the Library — that's the
            // single recoverable surface for either failure mode.
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "An unexpected error occurred." : trimmed
            return "\(detail)\n\nIf any audio was captured it's in your Library, where you can retry transcription or export the audio."
        }
    }

    public var compactErrorRecoveryMessage: String? {
        guard case .error = state else { return nil }
        return "Meeting interrupted. Open Library to retry transcription or export captured audio."
    }

    public var showsLaggingIndicator: Bool {
        if case .recording = state {
            return isTranscriptionLagging
        }
        return false
    }

    public var showsElapsedTime: Bool {
        if case .error = state {
            return false
        }
        return true
    }

    public var showsAudioLevels: Bool {
        // While paused, mic + system are both zeroed by the service; the orb
        // would render as a flat dot pretending to listen. Fall back to the
        // simple status indicator instead so the paused state reads honestly.
        state == .recording && !isPaused
    }

    public func updateLiveTranscriptStatus(_ status: LiveTranscriptStatus) {
        guard previewLines.isEmpty else { return }
        liveTranscriptStatus = status
    }

    public var transcriptEmptyStateTitle: String {
        if isTranscriptionLagging {
            return "Catching up..."
        }

        switch liveTranscriptStatus {
        case .startingAudio:
            return "Starting audio..."
        case .preparingSpeechModel:
            return "Preparing speech model..."
        case .listening, .live:
            return canStop ? "Listening..." : "Transcription in progress..."
        case .previewUnavailable:
            return "Live preview unavailable"
        }
    }

    public var transcriptEmptyStateDetail: String? {
        if isTranscriptionLagging {
            return "Final transcript will still include the full meeting."
        }

        switch liveTranscriptStatus {
        case .startingAudio:
            return nil
        case .preparingSpeechModel(let message):
            return Self.cleanWarmUpMessage(message) ?? "Recording continues while local transcription starts."
        case .listening, .live:
            return nil
        case .previewUnavailable:
            return "Audio keeps recording; retry transcription from Library if needed."
        }
    }

    private static func firstChangedLineIndex(
        oldLines: [MeetingRecordingPreviewLine],
        newLines: [MeetingRecordingPreviewLine]
    ) -> Int? {
        let sharedCount = min(oldLines.count, newLines.count)
        for index in 0..<sharedCount where oldLines[index] != newLines[index] {
            return index
        }
        return oldLines.count == newLines.count ? nil : sharedCount
    }

    private static func wordCount(for text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func cleanWarmUpMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = "Speech model: "
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
    }

    // MARK: - Tab badges (ADR-020 §1)

    /// All three tabs render as plain nouns. The badge taxonomy reduces to a
    /// single rule: surface state the user can't see by switching tabs.
    ///
    /// - **Notes**: word count was decoration. The notes themselves are the
    ///   canonical surface for "how much have I written?" — and the soft-cap
    ///   warning has its own footer UI in `LiveNotesPaneView`.
    /// - **Transcript**: recording state is already broadcast by the panel
    ///   header (orb, "Recording", elapsed timer, transcript word count,
    ///   Stop). A tab badge was the Nth instance of the same signal.
    /// - **Ask**: a message count is decoration. The actionable state is
    ///   "is an answer forming right now?" — covered by `isAskStreaming` and
    ///   its breathing dot, which is rendered separately by the view layer
    ///   (see `MeetingRecordingPanelView.tabLabel`).
    ///
    /// See ADR-020 §1 amendments (2026-05-02 and the Notes follow-on).
    public func badge(for tab: LivePanelTab) -> String? {
        switch tab {
        case .notes, .transcript, .ask:
            return nil
        }
    }

    /// True while the Ask conversation is mid-LLM-response. Drives the
    /// breathing dot in the Ask tab label so a user reading Notes/Transcript
    /// can see at a glance that their answer is forming. Strictly bound to
    /// `chatViewModel.isStreaming` — vanishes the moment streaming ends so
    /// the dot never decays into a stale notification badge.
    public var isAskStreaming: Bool {
        chatViewModel.isStreaming
    }
}
