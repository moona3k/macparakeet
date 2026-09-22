import Foundation
import GRDB

public struct MeetingType: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var colorToken: String?
    public var iconName: String?
    public var sortOrder: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorToken: String? = nil,
        iconName: String? = nil,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.iconName = iconName
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension MeetingType: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_types"

    public enum Columns: String, ColumnExpression {
        case id, name, colorToken, iconName, sortOrder, isArchived, createdAt, updatedAt
    }
}

public struct MeetingLabel: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var colorToken: String?
    public var sortOrder: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorToken: String? = nil,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension MeetingLabel: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_labels"

    public enum Columns: String, ColumnExpression {
        case id, name, colorToken, sortOrder, isArchived, createdAt, updatedAt
    }
}

public struct TranscriptionMeetingLabel: Codable, Sendable, Equatable {
    public var transcriptionId: UUID
    public var labelId: UUID

    public init(transcriptionId: UUID, labelId: UUID) {
        self.transcriptionId = transcriptionId
        self.labelId = labelId
    }
}

extension TranscriptionMeetingLabel: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcription_meeting_labels"

    public enum Columns: String, ColumnExpression {
        case transcriptionId, labelId
    }
}

public struct MeetingClassification: Sendable, Equatable {
    public var meetingType: MeetingType?
    public var labels: [MeetingLabel]

    public init(meetingType: MeetingType?, labels: [MeetingLabel]) {
        self.meetingType = meetingType
        self.labels = labels
    }
}
