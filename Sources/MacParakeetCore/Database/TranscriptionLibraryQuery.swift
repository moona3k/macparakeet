import Foundation

public enum TranscriptionLibrarySortOrder: Sendable, Equatable {
    case dateDescending
    case dateAscending
    case titleAscending
}

public struct TranscriptionLibraryQuery: Sendable, Equatable {
    public var sourceType: Transcription.SourceType?
    public var favoritesOnly: Bool
    public var searchText: String?
    public var sortOrder: TranscriptionLibrarySortOrder
    public var limit: Int
    public var offset: Int
    public var includeProcessing: Bool

    public init(
        sourceType: Transcription.SourceType? = nil,
        favoritesOnly: Bool = false,
        searchText: String? = nil,
        sortOrder: TranscriptionLibrarySortOrder = .dateDescending,
        limit: Int = 100,
        offset: Int = 0,
        includeProcessing: Bool = false
    ) {
        self.sourceType = sourceType
        self.favoritesOnly = favoritesOnly
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.limit = limit
        self.offset = offset
        self.includeProcessing = includeProcessing
    }
}

public struct TranscriptionLibraryPage: Sendable {
    public var items: [Transcription]
    public var hasMore: Bool

    public init(items: [Transcription], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}
