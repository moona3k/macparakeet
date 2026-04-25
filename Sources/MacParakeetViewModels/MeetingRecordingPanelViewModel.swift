import Foundation
import SwiftUI

@MainActor @Observable
public final class MeetingRecordingPanelViewModel {
    public enum PanelState: Equatable {
        case hidden
        case recording
        case transcribing
        case error(String)
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
    public var previewLines: [MeetingRecordingPreviewLine] = []
    public var isTranscriptionLagging: Bool = false
    public var showCopiedConfirmation: Bool = false
    /// Default to `.notes` per ADR-020 §2 — opening the panel should put the
    /// cursor in the notepad, not stare the user down with raw transcript.
    public var selectedTab: LivePanelTab = .notes
    public let chatViewModel: TranscriptChatViewModel = TranscriptChatViewModel()
    public let notesViewModel: MeetingNotesViewModel = MeetingNotesViewModel()
    public var onStop: (() -> Void)?
    public var onClose: (() -> Void)?

    private var copiedResetTask: Task<Void, Never>?
    private var previewLineWordCounts: [Int] = []

    public init() {}

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
            // Keep the live Ask tab fed with the latest transcript without disturbing
            // chat history. Bracketed timestamps stripped — LLMs do better without them.
            chatViewModel.updateTranscriptText(chatTranscript)
        }
        self.isTranscriptionLagging = isTranscriptionLagging
    }

    public var transcriptText: String {
        previewLines.map { "[\($0.timestamp)] \($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }

    /// Cleaner transcript shape for LLM consumption: speaker label + text, no timestamps.
    public var chatTranscript: String {
        previewLines.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
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
        previewLines = []
        previewLineWordCounts = []
        wordCount = 0
        isTranscriptionLagging = false
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

    public var statusTitle: String {
        switch state {
        case .hidden, .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .error:
            return "Recording Error"
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
            return message
        }
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
        state == .recording
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
}
