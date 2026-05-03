import Foundation
import GRDB

/// Namespace for import-related types. Lives at module scope because Swift
/// disallows nested types inside protocols.
public enum QuickPromptImport {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// UPSERT by id; rows in DB but not in file are left alone.
        case merge
        /// Wipe customs, restore built-ins to canonical values, then apply
        /// file. Most destructive mode — CLI prompts for confirmation unless
        /// `--json`.
        case replace
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let added: Int
        public let updated: Int
        public let deleted: Int
        public let unchanged: Int

        public init(added: Int, updated: Int, deleted: Int, unchanged: Int) {
            self.added = added
            self.updated = updated
            self.deleted = deleted
            self.unchanged = unchanged
        }
    }
}

public enum QuickPromptImportError: Error, LocalizedError, Equatable {
    case duplicateID(UUID)

    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id):
            return "Quick-prompts import contains duplicate id '\(id.uuidString)'."
        }
    }
}

/// CRUD + reconciliation + import/export for the live meeting Ask tab pills.
///
/// Mirrors `PromptRepository` shape so the patterns are familiar, but with two
/// deliberate divergences:
/// 1. **Reconciler is insert-only.** Built-ins are user-editable, so re-running
///    the reconciler on launch must never overwrite a user's edited row.
/// 2. **Restore default is the only update path for built-ins.** Per-row
///    (`restoreBuiltInDefault`) and bulk (`restoreBuiltInDefaults`) variants
///    rewrite the canonical fields in place; they never touch customs.
public protocol QuickPromptRepositoryProtocol: Sendable {
    func save(_ prompt: QuickPrompt) throws
    func fetch(id: UUID) throws -> QuickPrompt?
    func fetchAll() throws -> [QuickPrompt]
    func fetchAll(kind: QuickPrompt.Kind) throws -> [QuickPrompt]
    func fetchVisible(kind: QuickPrompt.Kind) throws -> [QuickPrompt]
    func delete(id: UUID) throws -> Bool
    func toggleVisibility(id: UUID) throws
    func reorder(ids: [UUID], within kind: QuickPrompt.Kind) throws

    /// Idempotent first-launch + upgrade-launch hydration. Inserts any built-in
    /// rows missing by canonical UUID and removes built-in rows whose UUIDs are
    /// no longer in the canonical list (retired built-ins). Never updates an
    /// existing row.
    func seedIfNeeded() throws

    /// Rewrites every built-in row in `kind` back to canonical seed values
    /// (label / prompt / groupLabel / sortOrder). Visibility is preserved —
    /// "restore default" is about content, not whether the user has hidden the
    /// pill. Customs are untouched.
    func restoreBuiltInDefaults(kind: QuickPrompt.Kind?) throws

    /// Per-row variant for the "Restore default" affordance on a single
    /// edited built-in row.
    func restoreBuiltInDefault(id: UUID) throws

    /// Apply a parsed import bundle. Returns a count summary suitable for
    /// surfacing through the CLI `--dry-run` and post-write success paths.
    /// Caller has already validated the bundle envelope via
    /// `QuickPromptBundle.validate()`.
    func applyImport(_ bundle: QuickPromptBundle, mode: QuickPromptImport.Mode, dryRun: Bool) throws -> QuickPromptImport.Summary
}

public final class QuickPromptRepository: QuickPromptRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: CRUD

    public func save(_ prompt: QuickPrompt) throws {
        try dbQueue.write { db in
            var copy = prompt
            copy = normalizedForWrite(copy)
            copy.updatedAt = Date()
            try copy.save(db)
        }
    }

    public func fetch(id: UUID) throws -> QuickPrompt? {
        try dbQueue.read { db in
            try QuickPrompt.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [QuickPrompt] {
        try dbQueue.read { db in
            try QuickPrompt
                .order(QuickPrompt.Columns.kind.asc, QuickPrompt.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    public func fetchAll(kind: QuickPrompt.Kind) throws -> [QuickPrompt] {
        try dbQueue.read { db in
            try QuickPrompt
                .filter(QuickPrompt.Columns.kind == kind.rawValue)
                .order(QuickPrompt.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    public func fetchVisible(kind: QuickPrompt.Kind) throws -> [QuickPrompt] {
        try dbQueue.read { db in
            try QuickPrompt
                .filter(QuickPrompt.Columns.kind == kind.rawValue)
                .filter(QuickPrompt.Columns.isVisible == true)
                .order(QuickPrompt.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            guard let existing = try QuickPrompt.fetchOne(db, key: id) else { return false }
            guard !existing.isBuiltIn else { return false }
            return try QuickPrompt.deleteOne(db, key: id)
        }
    }

    public func toggleVisibility(id: UUID) throws {
        try dbQueue.write { db in
            guard var prompt = try QuickPrompt.fetchOne(db, key: id) else { return }
            prompt.isVisible.toggle()
            prompt.updatedAt = Date()
            try prompt.update(db)
        }
    }

    public func reorder(ids: [UUID], within kind: QuickPrompt.Kind) throws {
        try dbQueue.write { db in
            let now = Date()
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE quick_prompts
                        SET sortOrder = ?, updatedAt = ?
                        WHERE id = ? AND kind = ?
                        """,
                    arguments: [index, now, id, kind.rawValue]
                )
            }
        }
    }

    // MARK: Reconciliation

    public func seedIfNeeded() throws {
        let canonical = QuickPrompt.builtInPrompts()
        let canonicalIDs = Set(canonical.map(\.id))

        try dbQueue.write { db in
            for prompt in canonical {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM quick_prompts WHERE id = ?)",
                    arguments: [prompt.id]
                ) ?? false
                if !exists {
                    try prompt.insert(db)
                }
            }

            // Retire built-ins removed from the canonical list. Customs are
            // never touched here — `isBuiltIn = 1` filter is load-bearing.
            if canonicalIDs.isEmpty {
                try db.execute(sql: "DELETE FROM quick_prompts WHERE isBuiltIn = 1")
            } else {
                let placeholders = canonicalIDs.map { _ in "?" }.joined(separator: ",")
                let arguments: [DatabaseValueConvertible] = canonicalIDs.map { $0 }
                try db.execute(
                    sql: """
                        DELETE FROM quick_prompts
                        WHERE isBuiltIn = 1
                          AND id NOT IN (\(placeholders))
                        """,
                    arguments: StatementArguments(arguments)
                )
            }
        }
    }

    public func restoreBuiltInDefaults(kind: QuickPrompt.Kind?) throws {
        let now = Date()
        let canonical: [QuickPrompt]
        if let kind {
            canonical = QuickPrompt.builtInPrompts(kind: kind, now: now)
        } else {
            canonical = QuickPrompt.builtInPrompts(now: now)
        }
        try dbQueue.write { db in
            for seed in canonical {
                try restoreOne(seed: seed, db: db, now: now)
            }
        }
    }

    public func restoreBuiltInDefault(id: UUID) throws {
        guard let seed = QuickPrompt.builtInPrompts().first(where: { $0.id == id }) else { return }
        let now = Date()
        try dbQueue.write { db in
            try restoreOne(seed: seed, db: db, now: now)
        }
    }

    /// Rewrite canonical fields for a single built-in seed. Visibility is
    /// **preserved** — restoring default content shouldn't override an explicit
    /// hide. If the row is missing entirely, this is a no-op (the reconciler
    /// will re-insert it on the next `seedIfNeeded()`).
    private func restoreOne(seed: QuickPrompt, db: Database, now: Date) throws {
        try db.execute(
            sql: """
                UPDATE quick_prompts
                SET kind = ?, label = ?, prompt = ?, groupLabel = ?, sortOrder = ?, isBuiltIn = 1, updatedAt = ?
                WHERE id = ?
                """,
            arguments: [
                seed.kind.rawValue,
                seed.label,
                seed.prompt,
                seed.groupLabel,
                seed.sortOrder,
                now,
                seed.id,
            ]
        )
    }

    // MARK: Import

    public func applyImport(
        _ bundle: QuickPromptBundle,
        mode: QuickPromptImport.Mode,
        dryRun: Bool
    ) throws -> QuickPromptImport.Summary {
        let now = Date()
        let incoming = bundle.prompts.map {
            normalizedForWrite(QuickPromptBundle.materialize($0, now: now))
        }
        var incomingIDs = Set<UUID>()
        for entry in incoming {
            guard incomingIDs.insert(entry.id).inserted else {
                throw QuickPromptImportError.duplicateID(entry.id)
            }
        }

        return try dbQueue.write { db in
            let existing = try QuickPrompt.fetchAll(db)
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let canonicalSeeds = QuickPrompt.builtInPrompts(now: now)
            let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalSeeds.map { ($0.id, $0) })

            var added = 0
            var updated = 0
            var deleted = 0
            var unchanged = 0

            switch mode {
            case .merge:
                for entry in incoming {
                    if let prior = existingByID[entry.id] {
                        if !areEquivalent(prior, entry) {
                            if !dryRun { try writeMerged(entry: entry, existing: prior, db: db, now: now) }
                            updated += 1
                        } else {
                            unchanged += 1
                        }
                    } else {
                        if !dryRun { try writeNew(entry: entry, db: db, now: now) }
                        added += 1
                    }
                }
                // Rows in DB but not in file are preserved on merge.
                unchanged += existing.filter { !incomingIDs.contains($0.id) }.count

            case .replace:
                // 1. Delete every custom row.
                let customIDs = existing.filter { !$0.isBuiltIn }.map(\.id)
                deleted = customIDs.count
                updated += existing.reduce(0) { count, row in
                    guard row.isBuiltIn, let canonical = canonicalByID[row.id] else { return count }
                    return areEquivalent(row, canonical) ? count : count + 1
                }
                if !dryRun {
                    let placeholders = customIDs.map { _ in "?" }.joined(separator: ",")
                    if !customIDs.isEmpty {
                        try db.execute(
                            sql: "DELETE FROM quick_prompts WHERE id IN (\(placeholders))",
                            arguments: StatementArguments(customIDs.map { $0 as DatabaseValueConvertible })
                        )
                    }
                    // 2. Re-seed built-ins to canonical so the slate is truly clean.
                    for seed in canonicalSeeds {
                        try seed.save(db)
                    }
                }
                // 3. Now apply the file as a merge over the cleaned-up state.
                let cleanByID = canonicalByID
                for entry in incoming {
                    if let prior = cleanByID[entry.id] {
                        if !areEquivalent(prior, entry) {
                            if !dryRun { try writeMerged(entry: entry, existing: prior, db: db, now: now) }
                            updated += 1
                        } else {
                            unchanged += 1
                        }
                    } else {
                        if !dryRun { try writeNew(entry: entry, db: db, now: now) }
                        added += 1
                    }
                }
            }

            return .init(added: added, updated: updated, deleted: deleted, unchanged: unchanged)
        }
    }

    /// Two prompts are "equivalent for import purposes" when every meaningful
    /// content field matches; timestamps don't count. Used to classify
    /// merge/replace results without spurious updates.
    private func areEquivalent(_ lhs: QuickPrompt, _ rhs: QuickPrompt) -> Bool {
        lhs.kind == rhs.kind
            && lhs.label == rhs.label
            && lhs.prompt == rhs.prompt
            && lhs.groupLabel == rhs.groupLabel
            && lhs.sortOrder == rhs.sortOrder
            && lhs.isVisible == rhs.isVisible
            && lhs.isBuiltIn == rhs.isBuiltIn
    }

    /// Write a merged row, preserving the existing row's `createdAt` so import
    /// does not reset history. Reserved built-in UUIDs keep their canonical kind
    /// and built-in status; custom rows cannot forge that status.
    private func writeMerged(entry: QuickPrompt, existing: QuickPrompt, db: Database, now: Date) throws {
        var merged = normalizedForWrite(entry)
        merged.createdAt = existing.createdAt
        merged.updatedAt = now
        try merged.save(db)
    }

    private func writeNew(entry: QuickPrompt, db: Database, now: Date) throws {
        var fresh = normalizedForWrite(entry)
        fresh.createdAt = now
        fresh.updatedAt = now
        try fresh.save(db)
    }

    private func normalizedForWrite(_ prompt: QuickPrompt) -> QuickPrompt {
        var normalized = prompt
        if let canonical = QuickPrompt.builtInPrompt(id: prompt.id) {
            normalized.kind = canonical.kind
            normalized.isBuiltIn = true
        } else {
            normalized.isBuiltIn = false
        }
        if normalized.kind == .followUp {
            normalized.groupLabel = nil
        }
        // Empty / whitespace-only group strings collapse to nil so the GUI never
        // renders an empty capsule and equality checks match canonical seeds
        // whose groupLabel is genuinely nil.
        if let trimmed = normalized.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           trimmed.isEmpty {
            normalized.groupLabel = nil
        }
        return normalized
    }
}
