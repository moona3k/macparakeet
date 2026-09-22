import Foundation

public enum TranscriptionLibrarySortOrder: Sendable, Equatable {
    case dateDescending
    case dateAscending
    case titleAscending
}

public struct TranscriptionLibraryQuery: Sendable, Equatable {
    public var sourceType: Transcription.SourceType?
    public var favoritesOnly: Bool
    /// Primary meeting types to include. Multiple values use ANY semantics.
    public var meetingTypeIDs: Set<UUID>
    /// When true, include only meetings without a primary type.
    public var unclassifiedMeetingsOnly: Bool
    /// Meeting labels to include. Multiple values use ANY semantics.
    public var meetingLabelIDs: Set<UUID>
    public var searchText: String?
    public var sortOrder: TranscriptionLibrarySortOrder
    public var limit: Int
    public var offset: Int
    public var includeProcessing: Bool
    public var includeProcessingMeetings: Bool

    public init(
        sourceType: Transcription.SourceType? = nil,
        favoritesOnly: Bool = false,
        meetingTypeIDs: Set<UUID> = [],
        unclassifiedMeetingsOnly: Bool = false,
        meetingLabelIDs: Set<UUID> = [],
        searchText: String? = nil,
        sortOrder: TranscriptionLibrarySortOrder = .dateDescending,
        limit: Int = 100,
        offset: Int = 0,
        includeProcessing: Bool = false,
        includeProcessingMeetings: Bool = false
    ) {
        self.sourceType = sourceType
        self.favoritesOnly = favoritesOnly
        self.meetingTypeIDs = meetingTypeIDs
        self.unclassifiedMeetingsOnly = unclassifiedMeetingsOnly
        self.meetingLabelIDs = meetingLabelIDs
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.limit = limit
        self.offset = offset
        self.includeProcessing = includeProcessing
        self.includeProcessingMeetings = includeProcessingMeetings
    }
}

public struct TranscriptionLibraryPage: Sendable {
    public var items: [Transcription]
    public var hasMore: Bool
    /// Effective corrected transcript text for Library presentation. Items
    /// remain canonical database rows so transient projections cannot be saved
    /// back over automatic evidence.
    public var effectiveTranscriptTextByID: [UUID: String]

    public init(
        items: [Transcription],
        hasMore: Bool,
        effectiveTranscriptTextByID: [UUID: String] = [:]
    ) {
        self.items = items
        self.hasMore = hasMore
        self.effectiveTranscriptTextByID = effectiveTranscriptTextByID
    }
}

public struct TranscriptionLibraryItem: Sendable {
    public let transcription: Transcription
    public let effectiveTranscriptText: String?

    public init(transcription: Transcription, effectiveTranscriptText: String?) {
        self.transcription = transcription
        self.effectiveTranscriptText = effectiveTranscriptText
    }
}
