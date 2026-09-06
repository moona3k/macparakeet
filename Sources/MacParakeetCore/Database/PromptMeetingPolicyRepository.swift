import Foundation
import GRDB

public protocol PromptMeetingPolicyRepositoryProtocol: Sendable {
    func save(_ policy: PromptMeetingPolicy) throws
    func fetch(id: UUID) throws -> PromptMeetingPolicy?
    func fetchPolicies(promptId: UUID) throws -> [PromptMeetingPolicy]
    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptMeetingPolicy]
    func fetchEffectivePolicy(promptId: UUID, meetingTypeId: UUID?) throws -> PromptMeetingPolicy?
    @discardableResult
    func setAllMeetingsPolicy(
        promptId: UUID,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int?
    ) throws -> PromptMeetingPolicy
    @discardableResult
    func setPolicy(
        promptId: UUID,
        meetingTypeId: UUID,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int?
    ) throws -> PromptMeetingPolicy
    func delete(id: UUID) throws -> Bool
    func deletePolicies(promptId: UUID) throws
}

public extension PromptMeetingPolicyRepositoryProtocol {
    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptMeetingPolicy] {
        try promptIds.flatMap { try fetchPolicies(promptId: $0) }
    }
}

public final class PromptMeetingPolicyRepository: PromptMeetingPolicyRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ policy: PromptMeetingPolicy) throws {
        guard Self.hasValidScope(policy) else {
            throw MeetingClassificationRepositoryError.invalidPolicyScope
        }
        var normalized = policy
        normalized.isAutoRun = policy.isAvailable && policy.isAutoRun
        try dbQueue.write { db in
            try normalized.save(db)
        }
    }

    public func fetch(id: UUID) throws -> PromptMeetingPolicy? {
        try dbQueue.read { db in
            try PromptMeetingPolicy.fetchOne(db, key: id)
        }
    }

    public func fetchPolicies(promptId: UUID) throws -> [PromptMeetingPolicy] {
        try dbQueue.read { db in
            try PromptMeetingPolicy
                .filter(PromptMeetingPolicy.Columns.promptId == promptId)
                .order(
                    PromptMeetingPolicy.Columns.scopeKind.asc,
                    PromptMeetingPolicy.Columns.sortOrder.asc,
                    PromptMeetingPolicy.Columns.createdAt.asc
                )
                .fetchAll(db)
        }
    }

    public func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptMeetingPolicy] {
        guard !promptIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try PromptMeetingPolicy
                .filter(promptIds.contains(PromptMeetingPolicy.Columns.promptId))
                .order(
                    PromptMeetingPolicy.Columns.promptId.asc,
                    PromptMeetingPolicy.Columns.scopeKind.asc,
                    PromptMeetingPolicy.Columns.sortOrder.asc,
                    PromptMeetingPolicy.Columns.createdAt.asc
                )
                .fetchAll(db)
        }
    }

    public func fetchEffectivePolicy(promptId: UUID, meetingTypeId: UUID?) throws -> PromptMeetingPolicy? {
        try dbQueue.read { db in
            if let meetingTypeId,
                let exact =
                    try PromptMeetingPolicy
                    .filter(PromptMeetingPolicy.Columns.promptId == promptId)
                    .filter(PromptMeetingPolicy.Columns.scopeKind == PromptMeetingPolicy.ScopeKind.type.rawValue)
                    .filter(PromptMeetingPolicy.Columns.meetingTypeId == meetingTypeId)
                    .fetchOne(db)
            {
                return exact
            }
            return
                try PromptMeetingPolicy
                .filter(PromptMeetingPolicy.Columns.promptId == promptId)
                .filter(PromptMeetingPolicy.Columns.scopeKind == PromptMeetingPolicy.ScopeKind.all.rawValue)
                .filter(PromptMeetingPolicy.Columns.meetingTypeId == nil)
                .fetchOne(db)
        }
    }

    @discardableResult
    public func setAllMeetingsPolicy(
        promptId: UUID,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int? = nil
    ) throws -> PromptMeetingPolicy {
        try dbQueue.write { db in
            let existing =
                try PromptMeetingPolicy
                .filter(PromptMeetingPolicy.Columns.promptId == promptId)
                .filter(PromptMeetingPolicy.Columns.scopeKind == PromptMeetingPolicy.ScopeKind.all.rawValue)
                .filter(PromptMeetingPolicy.Columns.meetingTypeId == nil)
                .fetchOne(db)
            let now = Date()
            let policy = PromptMeetingPolicy(
                id: existing?.id ?? UUID(),
                promptId: promptId,
                scopeKind: .all,
                isAvailable: isAvailable,
                isAutoRun: isAutoRun,
                sortOrder: sortOrder,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try policy.save(db)
            return policy
        }
    }

    @discardableResult
    public func setPolicy(
        promptId: UUID,
        meetingTypeId: UUID,
        isAvailable: Bool,
        isAutoRun: Bool,
        sortOrder: Int? = nil
    ) throws -> PromptMeetingPolicy {
        try dbQueue.write { db in
            let existing =
                try PromptMeetingPolicy
                .filter(PromptMeetingPolicy.Columns.promptId == promptId)
                .filter(PromptMeetingPolicy.Columns.scopeKind == PromptMeetingPolicy.ScopeKind.type.rawValue)
                .filter(PromptMeetingPolicy.Columns.meetingTypeId == meetingTypeId)
                .fetchOne(db)
            let now = Date()
            let policy = PromptMeetingPolicy(
                id: existing?.id ?? UUID(),
                promptId: promptId,
                scopeKind: .type,
                meetingTypeId: meetingTypeId,
                isAvailable: isAvailable,
                isAutoRun: isAutoRun,
                sortOrder: sortOrder,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try policy.save(db)
            return policy
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try PromptMeetingPolicy.deleteOne(db, key: id)
        }
    }

    public func deletePolicies(promptId: UUID) throws {
        _ = try dbQueue.write { db in
            try PromptMeetingPolicy
                .filter(PromptMeetingPolicy.Columns.promptId == promptId)
                .deleteAll(db)
        }
    }

    private static func hasValidScope(_ policy: PromptMeetingPolicy) -> Bool {
        switch policy.scopeKind {
        case .all:
            return policy.meetingTypeId == nil
        case .type:
            return policy.meetingTypeId != nil
        }
    }
}
