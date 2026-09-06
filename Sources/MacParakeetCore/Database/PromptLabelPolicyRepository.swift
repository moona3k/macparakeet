import Foundation
import GRDB

public protocol PromptLabelPolicyRepositoryProtocol: Sendable {
    func fetchPolicies(promptId: UUID) throws -> [PromptLabelPolicy]
    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy]
    func replaceTargetLabels(promptId: UUID, labelIds: Set<UUID>) throws
}

public extension PromptLabelPolicyRepositoryProtocol {
    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy] {
        try promptIds.flatMap { try fetchPolicies(promptId: $0) }
    }
}

public final class PromptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetchPolicies(promptId: UUID) throws -> [PromptLabelPolicy] {
        try dbQueue.read { db in
            try PromptLabelPolicy
                .filter(PromptLabelPolicy.Columns.promptId == promptId)
                .order(PromptLabelPolicy.Columns.scopeKind.asc, PromptLabelPolicy.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy] {
        guard !promptIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try PromptLabelPolicy
                .filter(promptIds.contains(PromptLabelPolicy.Columns.promptId))
                .order(
                    PromptLabelPolicy.Columns.promptId.asc,
                    PromptLabelPolicy.Columns.scopeKind.asc,
                    PromptLabelPolicy.Columns.createdAt.asc
                )
                .fetchAll(db)
        }
    }

    /// Changes one rule without erasing other label exceptions. A nil label
    /// selects the fallback used when no explicit label rule matches.
    @discardableResult
    public func setAvailability(promptId: UUID, labelId: UUID?, isAvailable: Bool) throws -> PromptLabelPolicy {
        try dbQueue.write { db in
            let scope: PromptLabelPolicy.ScopeKind = labelId == nil ? .all : .label
            let now = Date()
            // With no rules the resolver permits every transcription. Preserve
            // that implicit fallback when adding the first explicit exception.
            if labelId != nil,
                try PromptLabelPolicy.filter(PromptLabelPolicy.Columns.promptId == promptId).fetchCount(db) == 0 {
                try PromptLabelPolicy(
                    promptId: promptId, scopeKind: .all, isAvailable: true,
                    createdAt: now, updatedAt: now
                ).insert(db)
            }
            let existing = try PromptLabelPolicy
                .filter(PromptLabelPolicy.Columns.promptId == promptId)
                .filter(PromptLabelPolicy.Columns.scopeKind == scope.rawValue)
                .filter(PromptLabelPolicy.Columns.labelId == labelId)
                .fetchOne(db)
            let policy = PromptLabelPolicy(
                id: existing?.id ?? UUID(), promptId: promptId, scopeKind: scope,
                labelId: labelId, isAvailable: isAvailable,
                createdAt: existing?.createdAt ?? now, updatedAt: now
            )
            try policy.save(db)
            return policy
        }
    }

    /// Replaces the simple Prompt Manager targeting model atomically. No rows
    /// means "all transcriptions". A non-empty selection writes an unavailable
    /// fallback plus one available rule per selected label.
    public func replaceTargetLabels(promptId: UUID, labelIds: Set<UUID>) throws {
        try dbQueue.write { db in
            _ = try PromptLabelPolicy
                .filter(PromptLabelPolicy.Columns.promptId == promptId)
                .deleteAll(db)

            guard !labelIds.isEmpty else { return }
            let now = Date()
            try PromptLabelPolicy(
                promptId: promptId,
                scopeKind: .all,
                isAvailable: false,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            for labelId in labelIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                try PromptLabelPolicy(
                    promptId: promptId,
                    scopeKind: .label,
                    labelId: labelId,
                    isAvailable: true,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }
    }
}
