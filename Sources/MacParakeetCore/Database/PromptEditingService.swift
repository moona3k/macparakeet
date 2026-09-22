import Foundation
import GRDB

public enum PromptEditingError: Error, Equatable, Sendable {
    case promptNotFound
    case promptDeleted
    case versionNotFound
    case versionBelongsToDifferentPrompt
    case unsupportedLabelTargeting
}

public protocol PromptEditingServiceProtocol: Sendable {
    /// Saves the definition and optional routing change atomically. Nil keeps
    /// existing policies; an empty set explicitly selects all transcriptions.
    @discardableResult
    func save(_ prompt: Prompt, targetLabelIDs: Set<UUID>?) throws -> Prompt
    @discardableResult
    func restore(promptId: UUID, versionId: UUID, changeNote: String?) throws -> Prompt
    @discardableResult
    func restoreDeleted(id: UUID) throws -> Bool
}

/// Owns every transaction that changes both prompt metadata and immutable
/// prompt versions. Drafting remains outside this service; one successful save
/// creates at most one version.
public final class PromptEditingService: PromptEditingServiceProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    @discardableResult
    public func create(
        _ prompt: Prompt,
        origin: PromptVersion.Origin = .user
    ) throws -> Prompt {
        try dbQueue.write { db in
            if try PromptQuery.fetch(id: prompt.id, includingDeleted: true, db: db) != nil {
                return try save(prompt, origin: origin, changeNote: nil, db: db)
            }
            let settings = try prompt.inferenceSettings?.validated()
            let now = prompt.createdAt
            let version = PromptVersion(
                promptId: prompt.id,
                versionNumber: 1,
                content: prompt.content,
                inferenceSettings: settings,
                modelOverride: prompt.modelOverride,
                origin: origin,
                createdAt: now
            )
            try insertPrompt(prompt, activeVersionId: version.id, db: db)
            let storedVersion = version
            try storedVersion.insert(db)
            try insertDefaultMeetingPolicy(for: prompt, db: db)
            return try requirePrompt(id: prompt.id, includingDeleted: true, db: db)
        }
    }

    @discardableResult
    public func save(
        _ prompt: Prompt,
        origin: PromptVersion.Origin = .user,
        changeNote: String? = nil
    ) throws -> Prompt {
        try dbQueue.write { db in
            guard try PromptQuery.fetch(id: prompt.id, includingDeleted: true, db: db) != nil else {
                return try createNew(prompt, origin: origin, db: db)
            }
            return try save(prompt, origin: origin, changeNote: changeNote, db: db)
        }
    }

    /// The editor's Save action is one transaction, including routing. A
    /// vanished label must not leave a new allow-all prompt or a partially
    /// updated active version behind when its foreign-key insert fails.
    @discardableResult
    public func save(_ prompt: Prompt, targetLabelIDs: Set<UUID>?) throws -> Prompt {
        try dbQueue.write { db in
            if targetLabelIDs != nil, prompt.category != .result {
                throw PromptEditingError.unsupportedLabelTargeting
            }
            let saved: Prompt
            if try PromptQuery.fetch(id: prompt.id, includingDeleted: true, db: db) == nil {
                saved = try createNew(prompt, origin: .user, db: db)
            } else {
                saved = try save(prompt, origin: .user, changeNote: nil, db: db)
            }
            if let targetLabelIDs {
                try PromptLabelPolicyRepository.replaceTargetLabels(
                    promptId: saved.id, labelIds: targetLabelIDs, in: db
                )
            }
            return saved
        }
    }

    @discardableResult
    public func restore(
        promptId: UUID,
        versionId: UUID,
        changeNote: String? = nil
    ) throws -> Prompt {
        try dbQueue.write { db in
            let prompt = try requirePrompt(id: promptId, includingDeleted: false, db: db)
            guard let source = try PromptVersion.fetchOne(db, key: versionId) else {
                throw PromptEditingError.versionNotFound
            }
            guard source.promptId == promptId else {
                throw PromptEditingError.versionBelongsToDifferentPrompt
            }
            var restored = prompt
            restored.content = source.content
            restored.inferenceSettings = source.inferenceSettings
            restored.modelOverride = source.modelOverride
            restored.updatedAt = Date()
            return try save(restored, origin: .restore, changeNote: changeNote, forceVersion: true, db: db)
        }
    }

    @discardableResult
    public func softDelete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            guard let prompt = try PromptQuery.fetch(id: id, includingDeleted: true, db: db) else {
                return false
            }
            guard prompt.deletedAt == nil else { return false }
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET deletedAt = ?, updatedAt = ?,
                        userCustomizedAt = CASE
                            WHEN isBuiltIn = 1 THEN COALESCE(userCustomizedAt, ?)
                            ELSE userCustomizedAt
                        END
                    WHERE id = ?
                    """,
                arguments: [now, now, now, id]
            )
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func restoreDeleted(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            guard let prompt = try PromptQuery.fetch(id: id, includingDeleted: true, db: db),
                prompt.deletedAt != nil
            else { return false }
            let restoredName = try uniqueRestoredName(for: prompt, db: db)
            try db.execute(
                sql: "UPDATE prompts SET name = ?, deletedAt = NULL, updatedAt = ? WHERE id = ?",
                arguments: [restoredName, Date(), id]
            )
            return db.changesCount > 0
        }
    }

    private func createNew(
        _ prompt: Prompt,
        origin: PromptVersion.Origin,
        db: Database
    ) throws -> Prompt {
        let settings = try prompt.inferenceSettings?.validated()
        let version = PromptVersion(
            promptId: prompt.id,
            versionNumber: 1,
            content: prompt.content,
            inferenceSettings: settings,
            modelOverride: prompt.modelOverride,
            origin: origin,
            createdAt: prompt.createdAt
        )
        try insertPrompt(prompt, activeVersionId: version.id, db: db)
        let storedVersion = version
        try storedVersion.insert(db)
        try insertDefaultMeetingPolicy(for: prompt, db: db)
        return try requirePrompt(id: prompt.id, includingDeleted: true, db: db)
    }

    private func save(
        _ candidate: Prompt,
        origin: PromptVersion.Origin,
        changeNote: String?,
        forceVersion: Bool = false,
        db: Database
    ) throws -> Prompt {
        let existing = try requirePrompt(id: candidate.id, includingDeleted: true, db: db)
        guard existing.deletedAt == nil else { throw PromptEditingError.promptDeleted }

        let settings = try candidate.inferenceSettings?.validated()
        let versionChanged =
            forceVersion
            || candidate.content != existing.content
            || settings != existing.inferenceSettings
            || candidate.modelOverride != existing.modelOverride
        let nameChanged = candidate.name != existing.name
        let now = candidate.updatedAt
        var activeVersionId = existing.activeVersionId

        if versionChanged {
            let nextNumber =
                (try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(versionNumber) FROM prompt_versions WHERE promptId = ?",
                    arguments: [candidate.id]
                ) ?? 0) + 1
            let version = PromptVersion(
                promptId: candidate.id,
                versionNumber: nextNumber,
                content: candidate.content,
                inferenceSettings: settings,
                modelOverride: candidate.modelOverride,
                origin: origin,
                changeNote: changeNote,
                createdAt: now
            )
            try version.insert(db)
            activeVersionId = version.id
        }

        let customizedAt: Date? = {
            guard existing.isBuiltIn, nameChanged || versionChanged else {
                return existing.userCustomizedAt
            }
            return existing.userCustomizedAt ?? now
        }()
        let isAutoRun = candidate.category == .result ? candidate.isAutoRun : false
        let appliesToSources = try Self.encodeJSON(candidate.appliesToSources)

        try db.execute(
            sql: """
                UPDATE prompts
                SET name = ?, category = ?, isVisible = ?, isAutoRun = ?,
                    sortOrder = ?, updatedAt = ?, keyboardShortcut = ?,
                    runningLabel = ?, appliesToSources = ?, includeMeetingNotes = ?,
                    collectionId = ?, activeVersionId = ?,
                    userCustomizedAt = ?
                WHERE id = ?
                """,
            arguments: [
                candidate.name,
                candidate.category.rawValue,
                candidate.isVisible,
                isAutoRun,
                candidate.sortOrder,
                now,
                candidate.keyboardShortcut,
                candidate.runningLabel,
                appliesToSources,
                candidate.category == .result ? candidate.includeMeetingNotes : false,
                candidate.collectionId,
                activeVersionId,
                customizedAt,
                candidate.id,
            ]
        )
        return try requirePrompt(id: candidate.id, includingDeleted: true, db: db)
    }

    private func insertPrompt(
        _ prompt: Prompt,
        activeVersionId: UUID,
        db: Database
    ) throws {
        let appliesToSources = try Self.encodeJSON(prompt.appliesToSources)
        try db.execute(
            sql: """
                INSERT INTO prompts (
                    id, name, category, isBuiltIn, isVisible,
                    isAutoRun, sortOrder, createdAt, updatedAt,
                    keyboardShortcut, runningLabel, appliesToSources,
                    includeMeetingNotes,
                    collectionId, activeVersionId, canonicalKey,
                    lastAppliedCanonicalRevision, userCustomizedAt, deletedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                prompt.id,
                prompt.name,
                prompt.category.rawValue,
                prompt.isBuiltIn,
                prompt.isVisible,
                prompt.category == .result ? prompt.isAutoRun : false,
                prompt.sortOrder,
                prompt.createdAt,
                prompt.updatedAt,
                prompt.keyboardShortcut,
                prompt.runningLabel,
                appliesToSources,
                prompt.category == .result ? prompt.includeMeetingNotes : false,
                prompt.collectionId,
                activeVersionId,
                prompt.canonicalKey,
                prompt.lastAppliedCanonicalRevision,
                prompt.userCustomizedAt,
                prompt.deletedAt,
            ]
        )
    }

    private func requirePrompt(
        id: UUID,
        includingDeleted: Bool,
        db: Database
    ) throws -> Prompt {
        guard let prompt = try PromptQuery.fetch(id: id, includingDeleted: includingDeleted, db: db) else {
            throw PromptEditingError.promptNotFound
        }
        return prompt
    }

    private static func encodeJSON<Value: Encodable>(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func uniqueRestoredName(for prompt: Prompt, db: Database) throws -> String {
        let originalNameExists = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM prompts
                    WHERE name = ? COLLATE NOCASE AND deletedAt IS NULL AND id != ?
                )
            """,
            arguments: [prompt.name, prompt.id]
        ) ?? false
        guard originalNameExists else { return prompt.name }

        var suffix = 1
        while true {
            let candidate = suffix == 1
                ? "\(prompt.name) (Restored)"
                : "\(prompt.name) (Restored \(suffix))"
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM prompts WHERE name = ? COLLATE NOCASE AND deletedAt IS NULL)",
                arguments: [candidate]
            ) ?? false
            if !exists { return candidate }
            suffix += 1
        }
    }

    private func insertDefaultMeetingPolicy(for prompt: Prompt, db: Database) throws {
        guard prompt.category == .result,
            try db.tableExists("prompt_meeting_policies")
        else { return }
        try db.execute(
            sql: """
                INSERT INTO prompt_meeting_policies (
                    id, promptId, scopeKind, meetingTypeId, isAvailable,
                    isAutoRun, sortOrder, createdAt, updatedAt
                ) VALUES (?, ?, 'all', NULL, 1, ?, ?, ?, ?)
                """,
            arguments: [
                UUID(),
                prompt.id,
                prompt.autoRuns(for: .meeting),
                prompt.sortOrder,
                prompt.createdAt,
                prompt.updatedAt,
            ]
        )
    }
}

enum PromptQuery {
    static let select = """
        SELECT p.id, p.name, p.category, p.isBuiltIn, p.isVisible,
               p.isAutoRun, p.sortOrder, p.createdAt, p.updatedAt,
               p.keyboardShortcut, p.runningLabel, p.appliesToSources,
               p.includeMeetingNotes,
               p.collectionId, p.activeVersionId, p.canonicalKey,
               p.lastAppliedCanonicalRevision, p.userCustomizedAt, p.deletedAt,
               v.content, v.inferenceSettings, v.modelOverride
        FROM prompts p
        JOIN prompt_versions v ON v.id = p.activeVersionId AND v.promptId = p.id
        """

    static func fetch(id: UUID, includingDeleted: Bool, db: Database) throws -> Prompt? {
        let deletedClause = includingDeleted ? "" : " AND p.deletedAt IS NULL"
        return try Prompt.fetchOne(
            db,
            sql: select + " WHERE p.id = ?" + deletedClause,
            arguments: [id]
        )
    }

    static func fetchAll(
        category: Prompt.Category? = nil,
        visibleOnly: Bool = false,
        autoRunOnly: Bool = false,
        db: Database
    ) throws -> [Prompt] {
        var conditions = ["p.deletedAt IS NULL"]
        var arguments = StatementArguments()
        if visibleOnly { conditions.append("p.isVisible = 1") }
        if autoRunOnly {
            conditions.append("p.isAutoRun = 1")
            conditions.append("p.category = ?")
            arguments += [Prompt.Category.result.rawValue]
        } else if let category {
            conditions.append("p.category = ?")
            arguments += [category.rawValue]
        }
        return try Prompt.fetchAll(
            db,
            sql: select + " WHERE " + conditions.joined(separator: " AND ")
                + " ORDER BY p.sortOrder ASC, p.name ASC",
            arguments: arguments
        )
    }
}
