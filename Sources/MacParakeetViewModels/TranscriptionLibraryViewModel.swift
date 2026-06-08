import Foundation
import MacParakeetCore
import os

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All"
    case youtube = "Video"
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

    /// Override for tests; production code uses `Date()`.
    public var nowProvider: @Sendable () -> Date = { Date() }
    public var calendar: Calendar = .autoupdatingCurrent

    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var loadTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var loadGeneration = 0
    public let scope: TranscriptionLibraryScope

    public init(scope: TranscriptionLibraryScope = .all) {
        self.scope = scope
    }

    public func configure(transcriptionRepo: TranscriptionRepositoryProtocol) {
        self.transcriptionRepo = transcriptionRepo
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

    public func deleteTranscription(_ transcription: Transcription) {
        do {
            errorMessage = nil
            try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)
            let deleted = try transcriptionRepo?.delete(id: transcription.id) ?? false
            guard deleted else { return }
            transcriptions.removeAll { $0.id == transcription.id }
            publishLoadedItems(transcriptions, hasMore: hasMore)
            Telemetry.send(.transcriptionDeleted)
        } catch {
            logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to delete transcription: \(error.localizedDescription)"
        }
    }

    private func reloadAfterStateChange() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        loadTranscriptions()
    }

    private func debounceSearchReload() {
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
        case (.meetings, .youtube), (.meetings, .local):
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
    }
}
