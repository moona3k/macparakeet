import Foundation

public enum TranscriptionLibrarySortOrder: Sendable, Equatable {
    case dateDescending
    case dateAscending
    case titleAscending
}

/// How much of each row a Library page loads.
public enum TranscriptionLibraryPayload: Sendable, Equatable {
    /// Complete database rows.
    case full
    /// Rows without the word, segment, and diarization timing JSON, which no
    /// list or grid presents and which dominates decode time. Transcript text
    /// and all metadata are kept, so search and presentation are unchanged.
    /// Reload a row by ID before persisting it, exporting it, or showing it
    /// in transcript detail.
    case summary

    /// Columns that `.summary` loads as `NULL`.
    public static let summaryOmittedColumns: Set<String> = [
        Transcription.Columns.wordTimestamps.rawValue,
        Transcription.Columns.transcriptSegments.rawValue,
        Transcription.Columns.diarizationSegments.rawValue,
    ]
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
    public var payload: TranscriptionLibraryPayload

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
        includeProcessingMeetings: Bool = false,
        payload: TranscriptionLibraryPayload = .full
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
        self.payload = payload
    }
}

public struct TranscriptionLibraryPage: Sendable {
    public var items: [Transcription]
    public var hasMore: Bool
    /// Effective corrected transcript text for Library presentation. Items
    /// are never corrected projections, so a projection cannot be saved back
    /// over automatic evidence. `.full` items are complete database rows;
    /// `.summary` items omit timing JSON (see `TranscriptionLibraryPayload`).
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
