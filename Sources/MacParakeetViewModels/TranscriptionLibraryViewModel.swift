import Foundation
import MacParakeetCore
import os

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All"
    case youtube = "YouTube"
    case local = "Local"
    case meeting = "Meetings"
    case favorites = "Favorites"
}

public enum TranscriptionLibraryScope: Sendable {
    case all
    case meetings
}

public enum LibrarySortOrder: Sendable {
    case dateDescending
    case dateAscending
    case titleAscending
}

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
    public var transcriptions: [Transcription] = [] { didSet { recomputeFiltered() } }
    public var filter: LibraryFilter = .all { didSet { recomputeFiltered() } }
    public var searchText: String = "" { didSet { recomputeFiltered() } }
    public var sortOrder: LibrarySortOrder = .dateDescending { didSet { recomputeFiltered() } }
    public private(set) var filteredTranscriptions: [Transcription] = []
    public private(set) var groupedTranscriptions: [(group: TranscriptionDateGroup, items: [Transcription])] = []
    public var errorMessage: String?

    /// Override for tests; production code uses `Date()`.
    public var nowProvider: @Sendable () -> Date = { Date() }
    public var calendar: Calendar = .autoupdatingCurrent

    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    public let scope: TranscriptionLibraryScope

    public init(scope: TranscriptionLibraryScope = .all) {
        self.scope = scope
    }

    public func configure(transcriptionRepo: TranscriptionRepositoryProtocol) {
        self.transcriptionRepo = transcriptionRepo
    }

    private func recomputeFiltered() {
        var result = transcriptions.filter { matchesScope($0) }

        switch filter {
        case .all: break
        case .youtube: result = result.filter { $0.sourceType == .youtube }
        case .local: result = result.filter { $0.sourceType == .file }
        case .meeting: result = result.filter { $0.sourceType == .meeting }
        case .favorites: result = result.filter(\.isFavorite)
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { t in
                t.fileName.lowercased().contains(query)
                    || (t.rawTranscript?.lowercased().contains(query) ?? false)
                    || (t.cleanTranscript?.lowercased().contains(query) ?? false)
                    || (t.channelName?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOrder {
        case .dateDescending: result.sort { $0.createdAt > $1.createdAt }
        case .dateAscending: result.sort { $0.createdAt < $1.createdAt }
        case .titleAscending: result.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        }

        filteredTranscriptions = result
        groupedTranscriptions = groupByDate(result)
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

    private func matchesScope(_ transcription: Transcription) -> Bool {
        switch scope {
        case .all:
            return true
        case .meetings:
            return transcription.sourceType == .meeting
        }
    }

    public func loadTranscriptions() {
        do {
            transcriptions = (try transcriptionRepo?.fetchAll(limit: nil) ?? [])
                .filter { $0.status != .processing }
        } catch {
            logger.error("Failed to load transcriptions: \(error.localizedDescription)")
            transcriptions = []
        }
    }

    public func toggleFavorite(_ transcription: Transcription) {
        let newValue = !transcription.isFavorite
        do {
            errorMessage = nil
            try transcriptionRepo?.updateFavorite(id: transcription.id, isFavorite: newValue)
            if let idx = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[idx].isFavorite = newValue
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
            Telemetry.send(.transcriptionDeleted)
        } catch {
            logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to delete transcription: \(error.localizedDescription)"
        }
    }
}
