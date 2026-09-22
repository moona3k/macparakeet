import Foundation
import GRDB

public struct PromptMeetingPolicy: Codable, Identifiable, Sendable, Equatable {
    public enum ScopeKind: String, Codable, Sendable, CaseIterable {
        case all
        case type
    }

    public var id: UUID
    public var promptId: UUID
    public var scopeKind: ScopeKind
    public var meetingTypeId: UUID?
    public var isAvailable: Bool
    public var isAutoRun: Bool
    public var sortOrder: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        promptId: UUID,
        scopeKind: ScopeKind,
        meetingTypeId: UUID? = nil,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.promptId = promptId
        self.scopeKind = scopeKind
        self.meetingTypeId = meetingTypeId
        self.isAvailable = isAvailable
        self.isAutoRun = isAvailable && isAutoRun
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func allMeetings(
        promptId: UUID,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int? = nil,
        now: Date = Date()
    ) -> PromptMeetingPolicy {
        PromptMeetingPolicy(
            promptId: promptId,
            scopeKind: .all,
            isAvailable: isAvailable,
            isAutoRun: isAutoRun,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Default meeting behavior for a newly-created result prompt. Creation
    /// services insert this in the same transaction as the prompt so the
    /// resolver's intentional "no rule means unavailable" behavior can never
    /// make a new prompt disappear silently.
    public static func defaultForNewPrompt(_ prompt: Prompt, now: Date = Date()) -> PromptMeetingPolicy {
        allMeetings(
            promptId: prompt.id,
            isAvailable: true,
            isAutoRun: prompt.autoRuns(for: .meeting),
            sortOrder: prompt.sortOrder,
            now: now
        )
    }

    public static func meetingType(
        promptId: UUID,
        meetingTypeId: UUID,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int? = nil,
        now: Date = Date()
    ) -> PromptMeetingPolicy {
        PromptMeetingPolicy(
            promptId: promptId,
            scopeKind: .type,
            meetingTypeId: meetingTypeId,
            isAvailable: isAvailable,
            isAutoRun: isAutoRun,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension PromptMeetingPolicy: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompt_meeting_policies"

    public enum Columns: String, ColumnExpression {
        case id, promptId, scopeKind, meetingTypeId, isAvailable, isAutoRun
        case sortOrder, createdAt, updatedAt
    }
}
