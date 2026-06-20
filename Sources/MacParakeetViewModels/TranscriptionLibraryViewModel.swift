import Foundation
import MacParakeetCore
import os

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All"
    case youtube = "Video"
    case podcast = "Podcasts"
    case local = "Local"
    case meeting = "Meetings"
    case favorites = "Favorites"
}

public enum TranscriptionLibraryScope: Sendable {
    case all
    case meetings
}

public typealias LibrarySortOrder = TranscriptionLibrarySortOrder

/// Date-based bucket used to group meeting/library rows under headers like
/// "Today", "Yesterday", "Previous 7 Days". Computed against the user's
/// current calendar — never against a fixed timezone.
public enum TranscriptionDateGroup: Hashable, Sendable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(year: Int, month: Int)

    /// Sort key — relative buckets first (today, yesterday, …), then month
    /// buckets in descending date order. Tuple-based so months always sort
    /// after relative buckets regardless of year value.
    public var sortKey: (Int, Int) {
        switch self {
        case .today: return (0, 0)
        case .yesterday: return (1, 0)
        case .previous7Days: return (2, 0)
        case .previous30Days: return (3, 0)
        case .month(let year, let month):
            // Negate so newer months sort smaller within the month bucket.
            return (4, -(year * 12 + month))
        }
    }

    public static func bucket(for date: Date, now: Date, calendar: Calendar) -> TranscriptionDateGroup {
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

        if days <= 0 { return .today }
        if days == 1 { return .yesterday }
        if days <= 7 { return .previous7Days }
        if days <= 30 { return .previous30Days }

        let comps = calendar.dateComponents([.year, .month], from: date)
        return .month(year: comps.year ?? 0, month: comps.month ?? 0)
    }
}

public enum BulkTranscriptionOperation: Sendable {
    case deleteItems([Transcription])
    case deleteAudioOnly(targets: [Transcription], skipped: Int)

    public var targetCount: Int {
        switch self {
        case .deleteItems(let targets), .deleteAudioOnly(let targets, _):
            return targets.count
        }
    }

    public var skippedCount: Int {
        switch self {
        case .deleteItems:
            return 0
        case .deleteAudioOnly(_, let skipped):
            return skipped
        }
    }

    public var meetingCount: Int {
        switch self {
        case .deleteItems(let targets):
            return targets.filter { $0.sourceType == .meeting }.count
        case .deleteAudioOnly(let targets, _):
            return targets.count
        }
    }

    public var isDeleteAudioOnly: Bool {
        if case .deleteAudioOnly = self { return true }
        return false
    }
}

public struct BulkOperationResult: Sendable, Equatable {
    public let succeeded: Int
    public let failed: Int
    public let skipped: Int

    public init(succeeded: Int, failed: Int, skipped: Int = 0) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
    }
}

@MainActor @Observable
public final class TranscriptionLibraryViewModel {
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptionLibrary")
    public private(set) var transcriptions: [Transcription] = []
    public var filter: LibraryFilter = .all { didSet { reloadAfterStateChange() } }
    public var searchText: String = "" { didSet { debounceSearchReload() } }
    public var sortOrder: LibrarySortOrder = .dateDescending { didSet { reloadAfterStateChange() } }
    public private(set) var filteredTranscriptions: [Transcription] = []
    public private(set) var groupedTranscriptions: [(group: TranscriptionDateGroup, items: [Transcription])] = []
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public var errorMessage: String?
    public var pageSize = 100
    public var searchDebounceInterval: Duration = .milliseconds(300)
    public private(set) var selectedTranscriptionIDs: Set<UUID> = []
    public private(set) var isBulkSelectionModeEnabled = false
    public private(set) var isBulkOperationInProgress = false
    public private(set) var pendingBulkOperation: BulkTranscriptionOperation?

    /// Override for tests; production code uses `Date()`.
    public var nowProvider: @Sendable () -> Date = { Date() }
    public var calendar: Calendar = .autoupdatingCurrent

    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var loadTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var bulkSelectionGeneration = 0
    public let scope: TranscriptionLibraryScope

    public init(scope: TranscriptionLibraryScope = .all) {
        self.scope = scope
    }

    public func configure(transcriptionRepo: TranscriptionRepositoryProtocol) {
        self.transcriptionRepo = transcriptionRepo
    }

    public var selectedTranscriptionCount: Int {
        selectedTranscriptionIDs.count
    }

    public var hasSelectedTranscriptions: Bool {
        !selectedTranscriptionIDs.isEmpty
    }

    public var areAllLoadedVisibleTranscriptionsSelected: Bool {
        let ids = loadedVisibleTranscriptionIDs
        return !ids.isEmpty && ids.isSubset(of: selectedTranscriptionIDs)
    }

    public var selectedMeetingAudioCount: Int {
        selectedLoadedTranscriptions.filter(Self.hasAvailableMeetingAudio).count
    }

    private func groupByDate(_ items: [Transcription]) -> [(group: TranscriptionDateGroup, items: [Transcription])] {
        guard !items.isEmpty else { return [] }
        let now = nowProvider()

        // Bucket by logical group, not by adjacency. Items within each bucket
        // preserve the input order (so `titleAscending` sort produces a
        // group's items in alphabetical order). Buckets themselves sort by
        // `sortKey` so groups appear in the same order regardless of the
        // input sort.
        var bucketed: [TranscriptionDateGroup: [Transcription]] = [:]
        var encounterOrder: [TranscriptionDateGroup] = []

        for item in items {
            let group = TranscriptionDateGroup.bucket(for: item.createdAt, now: now, calendar: calendar)
            if bucketed[group] == nil {
                encounterOrder.append(group)
            }
            bucketed[group, default: []].append(item)
        }

        return encounterOrder
            .sorted { $0.sortKey < $1.sortKey }
            .map { group in (group: group, items: bucketed[group] ?? []) }
    }

    @discardableResult
    public func loadTranscriptions() -> Task<Void, Never> {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        return loadPage(offset: 0, append: false)
    }

    @discardableResult
    public func loadMoreTranscriptions() -> Task<Void, Never>? {
        guard hasMore, !isLoading else { return nil }
        return loadPage(offset: transcriptions.count, append: true)
    }

    public func toggleFavorite(_ transcription: Transcription) {
        let newValue = !transcription.isFavorite
        do {
            errorMessage = nil
            try transcriptionRepo?.updateFavorite(id: transcription.id, isFavorite: newValue)
            if let idx = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                if filter == .favorites && !newValue {
                    transcriptions.remove(at: idx)
                } else {
                    transcriptions[idx].isFavorite = newValue
                }
                publishLoadedItems(transcriptions, hasMore: hasMore)
            }
            Telemetry.send(.transcriptionFavorited(isFavorite: newValue))
        } catch {
            logger.error("Failed to update transcription favorite: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to update favorite: \(error.localizedDescription)"
        }
    }

    public func isTranscriptionSelected(_ transcription: Transcription) -> Bool {
        selectedTranscriptionIDs.contains(transcription.id)
    }

    public func toggleSelection(for transcription: Transcription) {
        guard !isBulkOperationInProgress else { return }
        bulkSelectionGeneration += 1
        if selectedTranscriptionIDs.contains(transcription.id) {
            selectedTranscriptionIDs.remove(transcription.id)
        } else {
            selectedTranscriptionIDs.insert(transcription.id)
        }
    }

    public func selectLoadedVisibleTranscriptions() {
        guard !isBulkOperationInProgress else { return }
        bulkSelectionGeneration += 1
        selectedTranscriptionIDs = loadedVisibleTranscriptionIDs
    }

    public func clearSelection() {
        guard !isBulkOperationInProgress else { return }
        bulkSelectionGeneration += 1
        selectedTranscriptionIDs = []
    }

    public func beginBulkSelection(startingWith transcription: Transcription? = nil) {
        guard !isBulkOperationInProgress else { return }
        bulkSelectionGeneration += 1
        isBulkSelectionModeEnabled = true
        if let transcription {
            selectedTranscriptionIDs.insert(transcription.id)
        }
    }

    public func exitBulkSelection() {
        guard !isBulkOperationInProgress else { return }
        finishBulkSelection()
    }

    private func finishBulkSelection() {
        bulkSelectionGeneration += 1
        isBulkSelectionModeEnabled = false
        selectedTranscriptionIDs = []
        pendingBulkOperation = nil
    }

    public func cancelPendingBulkOperation() {
        guard !isBulkOperationInProgress else { return }
        pendingBulkOperation = nil
    }

    public func requestDeleteSelectedItems() {
        guard !isBulkOperationInProgress else { return }
        let targets = selectedLoadedTranscriptions
        guard !targets.isEmpty else {
            clearSelection()
            return
        }
        pendingBulkOperation = .deleteItems(targets)
    }

    public func requestDeleteSelectedMeetingAudio() {
        guard !isBulkOperationInProgress else { return }
        let selected = selectedLoadedTranscriptions
        let targets = selected.filter(Self.hasAvailableMeetingAudio)
        guard !targets.isEmpty else {
            return
        }
        pendingBulkOperation = .deleteAudioOnly(
            targets: targets,
            skipped: selected.count - targets.count
        )
    }

    @discardableResult
    public func confirmPendingBulkOperation() async -> BulkOperationResult {
        guard let operation = pendingBulkOperation else {
            return BulkOperationResult(succeeded: 0, failed: 0)
        }
        pendingBulkOperation = nil
        guard let repo = transcriptionRepo else {
            errorMessage = "Unable to update Library: database is not available."
            return BulkOperationResult(succeeded: 0, failed: operation.targetCount, skipped: operation.skippedCount)
        }

        bulkSelectionGeneration += 1
        let operationGeneration = bulkSelectionGeneration
        isBulkSelectionModeEnabled = true
        isBulkOperationInProgress = true
        errorMessage = nil

        switch operation {
        case .deleteItems(let targets):
            let result = await Task.detached(priority: .userInitiated) {
                Self.deleteTargets(targets, using: repo)
            }.value
            for _ in 0..<result.succeededIDs.count {
                Telemetry.send(.transcriptionDeleted)
            }
            if !result.succeededIDs.isEmpty {
                removeLoadedTranscriptions(withIDs: Set(result.succeededIDs))
            }
            if !result.failedIDs.isEmpty {
                isBulkOperationInProgress = false
                restoreFailedSelectionIfCurrent(result.failedIDs, operationGeneration: operationGeneration)
                errorMessage = Self.bulkDeleteFailureMessage(succeeded: result.succeededIDs.count, failed: result.failedIDs.count)
            } else {
                isBulkOperationInProgress = false
                finishBulkSelection()
            }
            return BulkOperationResult(
                succeeded: result.succeededIDs.count,
                failed: result.failedIDs.count
            )

        case .deleteAudioOnly(let targets, let skipped):
            let result = await Task.detached(priority: .userInitiated) {
                Self.detachMeetingAudioTargets(targets, using: repo)
            }.value
            if !result.succeededIDs.isEmpty {
                clearLoadedMeetingAudio(forIDs: Set(result.succeededIDs))
            }
            if !result.failedIDs.isEmpty {
                isBulkOperationInProgress = false
                restoreFailedSelectionIfCurrent(result.failedIDs, operationGeneration: operationGeneration)
                errorMessage = Self.bulkAudioDeleteFailureMessage(
                    succeeded: result.succeededIDs.count,
                    failed: result.failedIDs.count,
                    skipped: skipped
                )
            } else {
                isBulkOperationInProgress = false
                finishBulkSelection()
            }
            return BulkOperationResult(
                succeeded: result.succeededIDs.count,
                failed: result.failedIDs.count,
                skipped: skipped
            )
        }
    }

    public func deleteTranscription(_ transcription: Transcription) {
        do {
            errorMessage = nil
            try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)
            let deleted = try transcriptionRepo?.delete(id: transcription.id) ?? false
            guard deleted else { return }
            transcriptions.removeAll { $0.id == transcription.id }
            selectedTranscriptionIDs.remove(transcription.id)
            publishLoadedItems(transcriptions, hasMore: hasMore)
            Telemetry.send(.transcriptionDeleted)
        } catch {
            logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to delete transcription: \(error.localizedDescription)"
        }
    }

    public func deleteMeetingAudio(_ transcription: Transcription) {
        do {
            errorMessage = nil
            guard let repo = transcriptionRepo else { return }
            guard transcription.sourceType == .meeting else { return }
            let result = try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
                for: transcription,
                repository: repo
            )
            guard result.detached else {
                errorMessage = TranscriptionAssetCleanup.unmanagedMeetingAudioMessage
                return
            }
            if let idx = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[idx].meetingArtifactFolderPath = transcriptions[idx].meetingArtifactFolderPath
                    ?? MeetingArtifactStore.sessionFolderURL(for: transcription)?.standardizedFileURL.path
                transcriptions[idx].filePath = nil
                publishLoadedItems(transcriptions, hasMore: hasMore)
            }
        } catch {
            logger.error("Failed to delete meeting audio: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to delete meeting audio: \(error.localizedDescription)"
        }
    }

    private func reloadAfterStateChange() {
        exitBulkSelection()
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        loadTranscriptions()
    }

    private func debounceSearchReload() {
        exitBulkSelection()
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.searchDebounceInterval > .zero {
                try? await Task.sleep(for: self.searchDebounceInterval)
            }
            guard !Task.isCancelled else { return }
            self.searchDebounceTask = nil
            self.loadPage(offset: 0, append: false)
        }
    }

    @discardableResult
    private func loadPage(offset: Int, append: Bool) -> Task<Void, Never> {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        guard let repo = transcriptionRepo else {
            isLoading = false
            publishLoadedItems([], hasMore: false)
            return Task {}
        }
        guard let query = makeQuery(offset: offset) else {
            isLoading = false
            publishLoadedItems([], hasMore: false)
            return Task {}
        }

        isLoading = true
        errorMessage = nil

        let task = Task { @MainActor [weak self, repo, query] in
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    try repo.fetchLibraryPage(query: query)
                }.value
                guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
                let items = append ? self.transcriptions + page.items : page.items
                self.publishLoadedItems(items, hasMore: page.hasMore)
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
                self.logger.error("Failed to load transcriptions: \(error.localizedDescription, privacy: .private)")
                self.publishLoadedItems([], hasMore: false)
                self.isLoading = false
                self.errorMessage = "Failed to load transcriptions: \(error.localizedDescription)"
            }
        }
        loadTask = task
        return task
    }

    private func makeQuery(offset: Int) -> TranscriptionLibraryQuery? {
        let sourceType: Transcription.SourceType?
        let favoritesOnly: Bool

        switch (scope, filter) {
        case (.all, .all):
            sourceType = nil
            favoritesOnly = false
        case (.all, .youtube):
            sourceType = .youtube
            favoritesOnly = false
        case (.all, .podcast):
            sourceType = .podcast
            favoritesOnly = false
        case (.all, .local):
            sourceType = .file
            favoritesOnly = false
        case (.all, .meeting):
            sourceType = .meeting
            favoritesOnly = false
        case (.all, .favorites):
            sourceType = nil
            favoritesOnly = true
        case (.meetings, .all), (.meetings, .meeting):
            sourceType = .meeting
            favoritesOnly = false
        case (.meetings, .favorites):
            sourceType = .meeting
            favoritesOnly = true
        case (.meetings, .youtube), (.meetings, .podcast), (.meetings, .local):
            return nil
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionLibraryQuery(
            sourceType: sourceType,
            favoritesOnly: favoritesOnly,
            searchText: trimmedSearch.isEmpty ? nil : trimmedSearch,
            sortOrder: sortOrder,
            limit: pageSize,
            offset: offset,
            includeProcessing: false
        )
    }

    private func publishLoadedItems(_ items: [Transcription], hasMore: Bool) {
        transcriptions = items
        filteredTranscriptions = items
        groupedTranscriptions = groupByDate(items)
        self.hasMore = hasMore
        pruneSelectionToLoadedItems()
    }

    private var loadedVisibleTranscriptionIDs: Set<UUID> {
        Set(filteredTranscriptions.map(\.id))
    }

    private var selectedLoadedTranscriptions: [Transcription] {
        filteredTranscriptions.filter { selectedTranscriptionIDs.contains($0.id) }
    }

    nonisolated private static func hasAvailableMeetingAudio(_ transcription: Transcription) -> Bool {
        MeetingAudioFile.isAvailable(for: transcription)
    }

    private func pruneSelectionToLoadedItems() {
        selectedTranscriptionIDs = selectedTranscriptionIDs.intersection(loadedVisibleTranscriptionIDs)
    }

    private func removeLoadedTranscriptions(withIDs ids: Set<UUID>) {
        transcriptions.removeAll { ids.contains($0.id) }
        selectedTranscriptionIDs.subtract(ids)
        publishLoadedItems(transcriptions, hasMore: hasMore)
    }

    private func clearLoadedMeetingAudio(forIDs ids: Set<UUID>) {
        for index in transcriptions.indices where ids.contains(transcriptions[index].id) {
            transcriptions[index].meetingArtifactFolderPath = transcriptions[index].meetingArtifactFolderPath
                ?? MeetingArtifactStore.sessionFolderURL(for: transcriptions[index])?.standardizedFileURL.path
            transcriptions[index].filePath = nil
        }
        publishLoadedItems(transcriptions, hasMore: hasMore)
    }

    private func restoreFailedSelectionIfCurrent(_ failedIDs: [UUID], operationGeneration: Int) {
        guard bulkSelectionGeneration == operationGeneration else { return }
        let visibleFailedIDs = Set(failedIDs).intersection(loadedVisibleTranscriptionIDs)
        guard !visibleFailedIDs.isEmpty else { return }
        isBulkSelectionModeEnabled = true
        selectedTranscriptionIDs = visibleFailedIDs
    }

    nonisolated private static func deleteTargets(
        _ targets: [Transcription],
        using repo: TranscriptionRepositoryProtocol
    ) -> BatchTargetResult {
        var succeededIDs: [UUID] = []
        var failedIDs: [UUID] = []

        for target in targets {
            do {
                try TranscriptionDeletionCleanup.removeOwnedAssets(for: target)
                if try repo.delete(id: target.id) {
                    succeededIDs.append(target.id)
                } else {
                    failedIDs.append(target.id)
                }
            } catch {
                failedIDs.append(target.id)
            }
        }

        return BatchTargetResult(succeededIDs: succeededIDs, failedIDs: failedIDs)
    }

    nonisolated private static func detachMeetingAudioTargets(
        _ targets: [Transcription],
        using repo: TranscriptionRepositoryProtocol
    ) -> BatchTargetResult {
        var succeededIDs: [UUID] = []
        var failedIDs: [UUID] = []

        for target in targets {
            do {
                let result = try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
                    for: target,
                    repository: repo
                )
                if result.detached {
                    succeededIDs.append(target.id)
                } else {
                    failedIDs.append(target.id)
                }
            } catch {
                failedIDs.append(target.id)
            }
        }

        return BatchTargetResult(succeededIDs: succeededIDs, failedIDs: failedIDs)
    }

    nonisolated private static func bulkDeleteFailureMessage(succeeded: Int, failed: Int) -> String {
        if succeeded > 0 {
            return "Deleted \(succeeded) items. \(failed) could not be deleted."
        }
        return failed == 1 ? "1 item could not be deleted." : "\(failed) items could not be deleted."
    }

    nonisolated private static func bulkAudioDeleteFailureMessage(succeeded: Int, failed: Int, skipped: Int) -> String {
        var parts: [String] = []
        if succeeded > 0 {
            parts.append("Deleted audio for \(succeeded) \(succeeded == 1 ? "meeting" : "meetings").")
        }
        if failed > 0 {
            parts.append(failed == 1 ? "1 meeting audio file could not be deleted." : "\(failed) meeting audio files could not be deleted.")
        }
        if skipped > 0 {
            parts.append(skipped == 1 ? "1 selected item was skipped." : "\(skipped) selected items were skipped.")
        }
        return parts.joined(separator: " ")
    }
}

private struct BatchTargetResult: Sendable {
    let succeededIDs: [UUID]
    let failedIDs: [UUID]
}
