import AppKit
import AVFoundation
import Foundation
import MacParakeetCore
import os
import UniformTypeIdentifiers

@MainActor
@Observable
public final class DictationHistoryViewModel {
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "DictationHistory")
    public var groupedDictations: [(String, [Dictation])] = []
    public var searchText: String = "" {
        didSet {
            // Search is a History-tab affordance. Typing while on Stats would
            // otherwise feel broken (no visible filtering happens), so flip
            // the user back to History where their results actually appear.
            if !searchText.isEmpty && selectedSubTab != .history {
                selectedSubTab = .history
            }
            debounceSearch()
        }
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

    // MARK: - Stats

    public var stats: DictationStats = .empty

    // MARK: - Sub-tabs

    public enum SubTab: String, CaseIterable, Sendable {
        case history
        case stats
    }

    public var selectedSubTab: SubTab = .history {
        didSet {
            // Selection is a History-only affordance; leaving the History
            // sub-tab tears down any active bulk-selection mode. Keyed off
            // "not History" rather than "== .stats" so a future third sub-tab
            // can't silently strand the user in bulk mode.
            if selectedSubTab != .history {
                exitBulkSelection()
            }
            if selectedSubTab == .stats {
                refreshStatsTabData()
            }
        }
    }

    // MARK: - Stats Tab Data

    /// 26 weeks × 7 days = 182 days, dense (zero-filled).
    public static let heatmapDayCount = 26 * 7

    public var dailyStats: [DailyDictationStat] = []
    public var currentStreak: Int = 0
    public var longestStreak: Int = 0
    public var topApps: [TopAppEntry] = []

    public struct TopAppEntry: Sendable, Hashable, Identifiable {
        public let bundleID: String
        public let count: Int
        public let words: Int
        public var id: String { bundleID }
    }

    // MARK: - Copy Confirmation

    public var copiedDictationId: UUID?
    private var copiedResetTask: Task<Void, Never>?

    // MARK: - Playback Error

    public var playbackError: String?
    private var playbackErrorResetTask: Task<Void, Never>?

    // MARK: - Selection

    public var selectedDictationIDs: Set<UUID> = []

    /// When true, the History list shows per-row selection controls and the
    /// bulk action bar. Bulk selection is a deliberate mode the user enters
    /// from a row's ellipsis menu — selection chrome stays hidden during
    /// ordinary browsing. Exited on confirmed bulk delete, Cancel, leaving the
    /// History sub-tab, or leaving the Dictations section.
    public var isBulkSelectionModeEnabled = false

    public var selectedDictationCount: Int {
        selectedDictationIDs.count
    }

    public var hasSelectedDictations: Bool {
        !selectedDictationIDs.isEmpty
    }

    public var areAllVisibleDictationsSelected: Bool {
        let ids = visibleDictationIDs
        return !ids.isEmpty && ids.isSubset(of: selectedDictationIDs)
    }

    // MARK: - Delete Confirmation

    public var pendingDeleteDictation: Dictation? {
        didSet {
            if pendingDeleteDictation != nil {
                pendingDeleteSelectedDictations = []
            }
        }
    }

    public var pendingDeleteSelectedDictations: [Dictation] = [] {
        didSet {
            if !pendingDeleteSelectedDictations.isEmpty {
                pendingDeleteDictation = nil
            }
        }
    }

    public var pendingDeleteCount: Int {
        if !pendingDeleteSelectedDictations.isEmpty {
            return pendingDeleteSelectedDictations.count
        }
        return pendingDeleteDictation == nil ? 0 : 1
    }

    public func cancelPendingDelete() {
        pendingDeleteDictation = nil
        pendingDeleteSelectedDictations = []
    }

    public func confirmPendingDelete() {
        if !pendingDeleteSelectedDictations.isEmpty {
            confirmDeleteSelectedDictations()
        } else {
            confirmDelete()
        }
    }

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

    public func loadDictations(shouldRefreshStats: Bool = true) {
        guard let repo = dictationRepo else { return }

        let dictations: [Dictation]
        do {
            if searchText.isEmpty {
                dictations = try repo.fetchAll(limit: 200)
            } else {
                dictations = try repo.search(query: searchText, limit: 200)
            }
        } catch {
            logger.error("Failed to load dictations: \(error.localizedDescription)")
            dictations = []
        }

        // Group by date
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: dictations) { dictation in
            calendar.startOfDay(for: dictation.createdAt)
        }

        groupedDictations = grouped.sorted { $0.key > $1.key }.map { (key, value) in
            (formatDateHeader(key), value.sorted { $0.createdAt > $1.createdAt })
        }
        pruneSelectionToVisibleDictations()

        if shouldRefreshStats {
            refreshStats()
        }
    }

    public func isDictationSelected(_ dictation: Dictation) -> Bool {
        selectedDictationIDs.contains(dictation.id)
    }

    public func toggleSelection(for dictation: Dictation) {
        if selectedDictationIDs.contains(dictation.id) {
            selectedDictationIDs.remove(dictation.id)
        } else {
            selectedDictationIDs.insert(dictation.id)
        }
    }

    public func selectAllVisibleDictations() {
        selectedDictationIDs = visibleDictationIDs
    }

    /// Empty the selection without leaving bulk mode, so the user can clear and
    /// reselect without reopening the menu. Distinct from `exitBulkSelection()`,
    /// which also tears down the mode.
    public func clearSelection() {
        selectedDictationIDs = []
    }

    /// Enter bulk-selection mode, preselecting the row the user invoked it from.
    public func beginBulkSelection(startingWith dictation: Dictation) {
        isBulkSelectionModeEnabled = true
        selectedDictationIDs.insert(dictation.id)
    }

    /// Leave bulk-selection mode and drop any selection.
    public func exitBulkSelection() {
        isBulkSelectionModeEnabled = false
        selectedDictationIDs = []
    }

    public func requestDeleteSelectedDictations() {
        let selectedDictations = visibleDictations.filter { selectedDictationIDs.contains($0.id) }
        guard !selectedDictations.isEmpty else {
            clearSelection()
            return
        }
        pendingDeleteSelectedDictations = selectedDictations
    }

    public func confirmDeleteSelectedDictations() {
        let selectedDictations = pendingDeleteSelectedDictations
        pendingDeleteSelectedDictations = []
        guard !selectedDictations.isEmpty else { return }
        // A confirmed bulk delete is a deliberate end to the bulk workflow. Tear
        // the mode down through the single exit path so the cleanup is explicit
        // and self-contained — `exitBulkSelection` clears the live selection
        // unconditionally, while the rows to delete are held in the local
        // snapshot, so deletion is unaffected.
        exitBulkSelection()
        deleteDictations(selectedDictations)
    }

    public func deleteDictation(_ dictation: Dictation) {
        guard let repo = dictationRepo else { return }
        deleteDictations([dictation], using: repo)
    }

    private func deleteDictations(_ dictations: [Dictation]) {
        guard let repo = dictationRepo else { return }
        deleteDictations(dictations, using: repo)
    }

    private func deleteDictations(
        _ dictations: [Dictation],
        using repo: DictationRepositoryProtocol
    ) {
        guard !dictations.isEmpty else { return }

        let ids = Set(dictations.map(\.id))
        if let playingDictationId, ids.contains(playingDictationId) {
            stopPlayback()
        }

        selectedDictationIDs.subtract(ids)
        let targets = dictations.map { DeleteTarget(id: $0.id, audioPath: $0.audioPath) }

        Task { [repo, targets] in
            let deletedIDs = await Self.deleteTargets(targets, using: repo)
            for _ in deletedIDs {
                Telemetry.send(.dictationDeleted)
            }
            loadDictations()
        }
    }

    private func refreshStats() {
        guard let repo = dictationRepo else { return }
        do {
            stats = try repo.stats()
        } catch {
            logger.error("Failed to load dictation stats: \(error.localizedDescription)")
            stats = .empty
        }

        // Stats sub-tab data is only refreshed eagerly when the user is
        // already viewing it, so we don't pay for heatmap reads on every
        // dictation save when the user is on the History tab. The next
        // sub-tab switch will pull fresh data.
        if selectedSubTab == .stats {
            refreshStatsTabData()
        }
    }

    public func refreshStatsTabData() {
        guard let repo = dictationRepo else { return }
        do {
            dailyStats = try repo.dailyStats(daysBack: Self.heatmapDayCount)
            currentStreak = try repo.currentDailyStreak()
            longestStreak = try repo.longestDailyStreak()
            topApps = try repo.topApps(limit: 5).map {
                TopAppEntry(bundleID: $0.app, count: $0.count, words: $0.words)
            }
        } catch {
            logger.error("Failed to load stats-tab data: \(error.localizedDescription)")
            dailyStats = []
            currentStreak = 0
            longestStreak = 0
            topApps = []
        }
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
        // Use `displayText` so the "Undo AI edit" per-row override is honored
        // — copying a row showing raw text should copy raw text, not the
        // suppressed cleaned version.
        let text = dictation.displayText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Telemetry.send(.copyToClipboard(source: .history))

        copiedResetTask?.cancel()
        copiedDictationId = dictation.id
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.copiedDictationId = nil
        }
    }

    // MARK: - Undo AI edit

    /// Toggle the per-row "Undo AI edit" override. Flipping to `true` shows
    /// `rawTranscript` on history / copy / export surfaces; flipping back to
    /// `false` re-applies the cleaned version. Persisted via the repository.
    public func toggleDisplayRawTranscript(for dictation: Dictation) {
        guard let repo = dictationRepo else { return }
        guard dictation.hasAIEdit else { return }
        let newValue = !dictation.displayRawTranscript
        do {
            _ = try repo.setDisplayRawTranscript(id: dictation.id, value: newValue)
            // Intentionally no telemetry event: adding a `TelemetryEventName`
            // case would require a companion update to the Cloudflare Worker
            // allowlist (the Worker rejects the entire batch on unknown
            // events). Keeping this PR scoped to Undo AI edit — telemetry can
            // be added as a follow-up if usage signal is needed.
        } catch {
            logger.error("Failed to toggle displayRawTranscript for \(dictation.id): \(error.localizedDescription)")
            return
        }
        // In-place update — the toggle only changes display state on one row.
        // Re-fetching + re-grouping 200 dictations to flip a Bool would
        // re-render the entire list (visible flicker on the active row's
        // crossfade animation) and burn a database read. Sort order /
        // grouping are driven by `createdAt`, which the toggle never
        // touches, so a targeted mutation is safe.
        updateDictationInPlace(id: dictation.id) { dictation in
            dictation.displayRawTranscript = newValue
        }
    }

    private func updateDictationInPlace(
        id: UUID,
        mutate: (inout Dictation) -> Void
    ) {
        for sectionIdx in groupedDictations.indices {
            if let rowIdx = groupedDictations[sectionIdx].1.firstIndex(where: { $0.id == id }) {
                mutate(&groupedDictations[sectionIdx].1[rowIdx])
                return
            }
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
            Telemetry.send(.historyReplayed)
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
            loadDictations(shouldRefreshStats: false)
            return
        }
        Telemetry.send(.historySearched)
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            loadDictations(shouldRefreshStats: false)
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

    private var visibleDictationIDs: Set<UUID> {
        Set(visibleDictations.map(\.id))
    }

    private var visibleDictations: [Dictation] {
        groupedDictations.flatMap(\.1)
    }

    private func pruneSelectionToVisibleDictations() {
        let ids = visibleDictationIDs
        selectedDictationIDs = selectedDictationIDs.intersection(ids)
    }

    private static let dateHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func formatDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return Self.dateHeaderFormatter.string(from: date)
        }
    }

    private struct DeleteTarget: Sendable {
        let id: UUID
        let audioPath: String?
    }

    private nonisolated static func deleteTargets(
        _ targets: [DeleteTarget],
        using repo: DictationRepositoryProtocol
    ) async -> [UUID] {
        await Task.detached(priority: .userInitiated) {
            let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "DictationHistory")
            var deletedIDs: [UUID] = []

            for target in targets {
                if let path = target.audioPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
                do {
                    _ = try repo.delete(id: target.id)
                    deletedIDs.append(target.id)
                } catch {
                    logger.error("Failed to delete dictation \(target.id): \(error.localizedDescription)")
                }
            }

            return deletedIDs
        }.value
    }
}

// MARK: - PlaybackDelegate

@MainActor
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.onFinish()
        }
    }
}
