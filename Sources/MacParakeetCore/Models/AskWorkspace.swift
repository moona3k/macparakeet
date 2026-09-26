import Foundation

/// Ask history is independent of Library records. A section freezes the source
/// membership used by its messages; changing membership starts another section.
public struct AskConversation: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var sections: [AskContextSection]
    public var messages: [AskMessage]
    public var draft: String
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        sections: [AskContextSection] = [AskContextSection()],
        messages: [AskMessage] = [],
        draft: String = "",
        revision: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.sections = sections
        self.messages = messages
        self.draft = draft
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var activeSection: AskContextSection? { sections.last }
}

public struct AskContextSection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var sourceIDs: [UUID]
    public var createdAt: Date

    public init(id: UUID = UUID(), sourceIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.sourceIDs = sourceIDs
        self.createdAt = createdAt
    }
}

public struct AskMessage: Codable, Identifiable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public enum Status: String, Codable, Sendable { case complete, incomplete, failed, cancelled }

    public var id: UUID
    public var sectionID: UUID
    public var role: Role
    public var status: Status
    public var content: String
    public var citations: [AskEvidenceReference]
    public var sourceRevisions: [UUID: String]
    public var failureReason: String?
    public var provider: AskProviderDisclosure?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sectionID: UUID,
        role: Role,
        status: Status = .complete,
        content: String,
        citations: [AskEvidenceReference] = [],
        sourceRevisions: [UUID: String] = [:],
        failureReason: String? = nil,
        provider: AskProviderDisclosure? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sectionID = sectionID
        self.role = role
        self.status = status
        self.content = content
        self.citations = citations
        self.sourceRevisions = sourceRevisions
        self.failureReason = failureReason
        self.provider = provider
        self.createdAt = createdAt
    }
}

/// A citation stores identity only. Its text is read from the current source.
public struct AskEvidenceReference: Codable, Sendable, Equatable, Hashable {
    public var sourceID: UUID
    public var sourceRevision: String
    public var segmentIndex: Int
    public var sourceTitle: String?
    public var recordedAt: Date?

    public init(
        sourceID: UUID, sourceRevision: String, segmentIndex: Int,
        sourceTitle: String? = nil, recordedAt: Date? = nil
    ) {
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.segmentIndex = segmentIndex
        self.sourceTitle = sourceTitle
        self.recordedAt = recordedAt
    }
}

public enum AskEvidenceStatus: String, Codable, Sendable {
    case available
    case unavailable
    case outOfScope
    case stale
    case invalid
}

public struct AskSourceFilter: Sendable, Equatable {
    public var searchText: String
    public var sourceType: Transcription.SourceType?
    public var since: Date?
    public var until: Date?
    public var labelIDs: Set<UUID>
    public var limit: Int
    public var offset: Int

    public init(
        searchText: String = "",
        sourceType: Transcription.SourceType? = nil,
        since: Date? = nil,
        until: Date? = nil,
        labelIDs: Set<UUID> = [],
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.searchText = searchText
        self.sourceType = sourceType
        self.since = since
        self.until = until
        self.labelIDs = labelIDs
        self.limit = limit
        self.offset = offset
    }
}

public struct AskSourceDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var recordedAt: Date
    public var sourceType: Transcription.SourceType
    public var durationMs: Int?
    public var labelIDs: [UUID]
    public var preview: String?
    public var isAvailable: Bool

    public init(
        id: UUID,
        title: String,
        recordedAt: Date,
        sourceType: Transcription.SourceType,
        durationMs: Int?,
        labelIDs: [UUID],
        preview: String?,
        isAvailable: Bool
    ) {
        self.id = id
        self.title = title
        self.recordedAt = recordedAt
        self.sourceType = sourceType
        self.durationMs = durationMs
        self.labelIDs = labelIDs
        self.preview = preview
        self.isAvailable = isAvailable
    }
}

public struct AskSourceSnapshot: Codable, Sendable, Equatable {
    public var descriptor: AskSourceDescriptor
    public var revision: String
    public var passageCount: Int
    public var status: AskEvidenceStatus

    public init(
        descriptor: AskSourceDescriptor,
        revision: String,
        passageCount: Int,
        status: AskEvidenceStatus
    ) {
        self.descriptor = descriptor
        self.revision = revision
        self.passageCount = passageCount
        self.status = status
    }
}

public struct AskPassage: Codable, Sendable, Equatable {
    public var reference: AskEvidenceReference
    public var text: String
    public var speaker: String?
    public var startMs: Int?
    public var endMs: Int?

    public init(
        reference: AskEvidenceReference,
        text: String,
        speaker: String?,
        startMs: Int?,
        endMs: Int?
    ) {
        self.reference = reference
        self.text = text
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct AskSummary: Codable, Sendable, Equatable {
    public var id: UUID
    public var sourceID: UUID
    public var title: String
    public var content: String
    public var createdAt: Date
    public var isUserEdited: Bool

    public init(
        id: UUID,
        sourceID: UUID,
        title: String,
        content: String,
        createdAt: Date,
        isUserEdited: Bool
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.isUserEdited = isUserEdited
    }
}
