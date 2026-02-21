import AppKit
import AVFoundation
import Foundation
import MacParakeetCore
import UniformTypeIdentifiers

@MainActor
@Observable
public final class DictationHistoryViewModel {
    public var groupedDictations: [(String, [Dictation])] = []
    public var searchText: String = "" {
        didSet { debounceSearch() }
    }
    private var searchDebounceTask: Task<Void, Never>?

    // MARK: - Playback State

    public var isPlaying: Bool = false
    public var playingDictationId: UUID?
    public var playbackCurrentTime: TimeInterval = 0
    public var playbackDuration: TimeInterval = 0

    public var playbackProgress: Double {
        guard playbackDuration > 0 else { return 0 }
        return playbackCurrentTime / playbackDuration
    }

    public var playbackTimeString: String {
        let currentMs = Int(playbackCurrentTime * 1000)
        let durationMs = Int(playbackDuration * 1000)
        return "\(currentMs.formattedDuration) / \(durationMs.formattedDuration)"
    }

    public var playingDictation: Dictation? {
        guard let id = playingDictationId else { return nil }
        return groupedDictations.flatMap(\.1).first { $0.id == id }
    }

    // MARK: - Copy Confirmation

    public var copiedDictationId: UUID?
    private var copiedResetTask: Task<Void, Never>?

    // MARK: - Playback Error

    public var playbackError: String?
    private var playbackErrorResetTask: Task<Void, Never>?

    // MARK: - Delete Confirmation

    public var pendingDeleteDictation: Dictation?

    public func confirmDelete() {
        guard let dictation = pendingDeleteDictation else { return }
        pendingDeleteDictation = nil
        deleteDictation(dictation)
    }

    private var dictationRepo: DictationRepositoryProtocol?
    private var audioPlayer: AVAudioPlayer?
    private var playbackDelegate: PlaybackDelegate?
    private var playbackTimerTask: Task<Void, Never>?

    public init() {}

    public func configure(dictationRepo: DictationRepositoryProtocol) {
        self.dictationRepo = dictationRepo
        loadDictations()
    }

    public func loadDictations() {
        guard let repo = dictationRepo else { return }

        let dictations: [Dictation]
        if searchText.isEmpty {
            dictations = (try? repo.fetchAll(limit: 200)) ?? []
        } else {
            dictations = (try? repo.search(query: searchText, limit: 200)) ?? []
        }

        // Group by date
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: dictations) { dictation in
            calendar.startOfDay(for: dictation.createdAt)
        }

        groupedDictations = grouped.sorted { $0.key > $1.key }.map { (key, value) in
            (formatDateHeader(key), value.sorted { $0.createdAt > $1.createdAt })
        }
    }

    public func deleteDictation(_ dictation: Dictation) {
        guard let repo = dictationRepo else { return }
        if playingDictationId == dictation.id {
            stopPlayback()
        }
        if let path = dictation.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = try? repo.delete(id: dictation.id)
        loadDictations()
    }

    public func downloadAudio(for dictation: Dictation) {
        guard let audioPath = dictation.audioPath,
              FileManager.default.fileExists(atPath: audioPath) else { return }
        let sourceURL = URL(fileURLWithPath: audioPath)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.copyItem(at: sourceURL, to: destination)
    }

    public func copyToClipboard(_ dictation: Dictation) {
        let text = dictation.cleanTranscript ?? dictation.rawTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        copiedResetTask?.cancel()
        copiedDictationId = dictation.id
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.copiedDictationId = nil
        }
    }

    // MARK: - Playback

    public func togglePlayback(for dictation: Dictation) {
        guard let audioPath = dictation.audioPath else { return }

        // If already playing this dictation, pause
        if playingDictationId == dictation.id, isPlaying {
            pausePlayback()
            return
        }

        // If paused on the same dictation, resume
        if playingDictationId == dictation.id, !isPlaying, audioPlayer != nil {
            audioPlayer?.play()
            isPlaying = true
            startPlaybackTimer()
            return
        }

        // Stop any current playback and start new
        stopPlayback()

        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            showPlaybackError("Audio file no longer exists")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = PlaybackDelegate { [weak self] in
                Task { @MainActor in
                    self?.stopPlayback()
                }
            }
            player.delegate = delegate
            player.play()

            audioPlayer = player
            playbackDelegate = delegate
            playingDictationId = dictation.id
            isPlaying = true
            playbackDuration = player.duration
            playbackCurrentTime = 0
            startPlaybackTimer()
        } catch {
            showPlaybackError("Unable to play audio")
        }
    }

    public func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        playbackTimerTask?.cancel()
        playbackTimerTask = nil
    }

    public func stopPlayback() {
        playbackTimerTask?.cancel()
        playbackTimerTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playbackDelegate = nil
        isPlaying = false
        playingDictationId = nil
        playbackCurrentTime = 0
        playbackDuration = 0
    }

    // MARK: - Private

    private func debounceSearch() {
        searchDebounceTask?.cancel()
        if searchText.isEmpty {
            // Clear immediately so the full list restores without lag
            loadDictations()
            return
        }
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            loadDictations()
        }
    }

    private func showPlaybackError(_ message: String) {
        playbackErrorResetTask?.cancel()
        playbackError = message
        playbackErrorResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.playbackError = nil
        }
    }

    private func startPlaybackTimer() {
        playbackTimerTask?.cancel()
        playbackTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                guard let self, let player = self.audioPlayer else { break }
                self.playbackCurrentTime = player.currentTime
            }
        }
    }

    private func formatDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: - PlaybackDelegate

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
