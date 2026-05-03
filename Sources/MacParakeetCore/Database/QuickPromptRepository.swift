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

/// Outcome of a `setPinned` attempt. The cap-exceeded case carries the current
/// pinned roster so the GUI can populate its swap-picker without a follow-up
/// fetch.
public enum SetPinnedResult: Equatable, Sendable {
    case ok
    case capExceeded(currentlyPinned: [QuickPrompt])
    case notFound
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
    func fetchVisible() throws -> [QuickPrompt]
    /// Visible pinned rows for the after-response strip. Caps at
    /// `QuickPrompt.pinnedCap` so legacy/imported over-cap data never expands
    /// the strip beyond its designed capacity.
    func fetchPinned() throws -> [QuickPrompt]
    func delete(id: UUID) throws -> Bool
    func toggleVisibility(id: UUID) throws

    /// Toggle a single row's `isPinned`. Pinning enforces `QuickPrompt.pinnedCap`;
    /// when the cap is exceeded, the call returns `.capExceeded` with the
    /// current pinned roster — no write occurs. Unpinning is always allowed.
    @discardableResult
    func setPinned(id: UUID, isPinned: Bool) throws -> SetPinnedResult

    /// Insert a new prompt and pin it (or not) in a single transaction. Used by
    /// the CLI's `add --pinned` so the caller never observes a half-applied
    /// state where the row exists but the pin failed the cap check. The
    /// caller's `prompt.sortOrder` is recomputed inside the transaction to
    /// land at the end of the target bucket.
    @discardableResult
    func saveAndPin(_ prompt: QuickPrompt, isPinned: Bool) throws -> SetPinnedResult

    /// Atomic pin-swap — unpin one row and pin another in the same transaction.
    /// Used by the GUI's swap-picker when the user attempts to pin a 6th
    /// prompt at cap. No-op (returns `.notFound`) if either id is missing.
    @discardableResult
    func swapPin(unpinID: UUID, pinID: UUID) throws -> SetPinnedResult

    /// Reorder rows within a pin-bucket. Caller passes the new full ordered
    /// list of ids for that bucket. Pinned and unpinned buckets are reordered
    /// independently — the editor sheet has separate reorder arrows per zone.
    func reorder(ids: [UUID], pinned: Bool) throws

    /// Idempotent first-launch + upgrade-launch hydration. Inserts any built-in
    /// rows missing by canonical UUID and removes built-in rows whose UUIDs are
    /// no longer in the canonical list (retired built-ins). Never updates an
    /// existing row.
    func seedIfNeeded() throws

    /// Rewrites every built-in row back to canonical seed values
    /// (label / prompt / groupLabel / sortOrder / isPinned). Visibility is
    /// preserved — "restore default" is about content, not whether the user
    /// has hidden the pill. Customs are untouched, so canonical re-pinning is
    /// applied only while it fits within `QuickPrompt.pinnedCap`.
    func restoreBuiltInDefaults() throws

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
            var copy = try normalizedForWrite(prompt, db: db)
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
                .order(QuickPrompt.Columns.isPinned.asc, QuickPrompt.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    public func fetchVisible() throws -> [QuickPrompt] {
        try dbQueue.read { db in
            try QuickPrompt
                .filter(QuickPrompt.Columns.isVisible == true)
                .order(QuickPrompt.Columns.isPinned.asc, QuickPrompt.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    public func fetchPinned() throws -> [QuickPrompt] {
        try dbQueue.read { db in
            try QuickPrompt
                .filter(QuickPrompt.Columns.isPinned == true)
                .filter(QuickPrompt.Columns.isVisible == true)
                .order(QuickPrompt.Columns.sortOrder.asc)
                .limit(QuickPrompt.pinnedCap)
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

    @discardableResult
    public func setPinned(id: UUID, isPinned: Bool) throws -> SetPinnedResult {
        try dbQueue.write { db in
            guard var prompt = try QuickPrompt.fetchOne(db, key: id) else {
                return .notFound
            }
            // Unpinning is always allowed; idempotent re-pin / re-unpin is a
            // cheap no-op that still bumps updatedAt for convergence.
            if isPinned && !prompt.isPinned {
                let pinnedCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM quick_prompts WHERE isPinned = 1"
                ) ?? 0
                if pinnedCount >= QuickPrompt.pinnedCap {
                    let current = try QuickPrompt
                        .filter(QuickPrompt.Columns.isPinned == true)
                        .order(QuickPrompt.Columns.sortOrder.asc)
                        .fetchAll(db)
                    return .capExceeded(currentlyPinned: current)
                }
                // Pinning lands the row at the end of the pinned bucket so the
                // user's recent action is the rightmost pill. Sort within the
                // bucket can be tweaked via `reorder(ids:pinned:)`.
                let maxPinnedSort = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM quick_prompts WHERE isPinned = 1"
                ) ?? -1
                prompt.sortOrder = maxPinnedSort + 1
            } else if !isPinned && prompt.isPinned {
                // Unpinning lands the row at the end of the unpinned bucket
                // for the same reason — preserves the "I just touched this"
                // visual cue in the editor's ALL PROMPTS zone.
                let maxUnpinnedSort = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM quick_prompts WHERE isPinned = 0"
                ) ?? -1
                prompt.sortOrder = maxUnpinnedSort + 1
            }
            prompt.isPinned = isPinned
            prompt.updatedAt = Date()
            try prompt.update(db)
            return .ok
        }
    }

    @discardableResult
    public func saveAndPin(_ prompt: QuickPrompt, isPinned: Bool) throws -> SetPinnedResult {
        try dbQueue.write { db in
            if isPinned {
                let pinnedCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM quick_prompts WHERE isPinned = 1"
                ) ?? 0
                if pinnedCount >= QuickPrompt.pinnedCap {
                    let current = try QuickPrompt
                        .filter(QuickPrompt.Columns.isPinned == true)
                        .order(QuickPrompt.Columns.sortOrder.asc)
                        .fetchAll(db)
                    return .capExceeded(currentlyPinned: current)
                }
            }
            var copy = try normalizedForWrite(prompt, db: db)
            copy.isPinned = isPinned
            let bucketFlag = isPinned ? 1 : 0
            let maxSort = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM quick_prompts WHERE isPinned = ?",
                arguments: [bucketFlag]
            ) ?? -1
            copy.sortOrder = maxSort + 1
            copy.updatedAt = Date()
            try copy.save(db)
            return .ok
        }
    }

    @discardableResult
    public func swapPin(unpinID: UUID, pinID: UUID) throws -> SetPinnedResult {
        do {
            return try dbQueue.write { db -> SetPinnedResult in
                guard var toUnpin = try QuickPrompt.fetchOne(db, key: unpinID),
                      var toPin = try QuickPrompt.fetchOne(db, key: pinID) else {
                    return .notFound
                }
                // No-op if both ids point at the same row — defensive against
                // a stale picker offering the same pill twice.
                if unpinID == pinID { return .ok }
                let now = Date()

                // Unpin first to free a slot.
                if toUnpin.isPinned {
                    let maxUnpinnedSort = try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM quick_prompts WHERE isPinned = 0"
                    ) ?? -1
                    toUnpin.isPinned = false
                    toUnpin.sortOrder = maxUnpinnedSort + 1
                    toUnpin.updatedAt = now
                    try toUnpin.update(db)
                }

                // Pin the replacement at the end of the pinned bucket. The
                // unpin above is already staged within this transaction, so
                // the cap check below sees the freed slot. If `toUnpin` was
                // not actually pinned, the cap may still be hit — throw to
                // roll back.
                if !toPin.isPinned {
                    let pinnedCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM quick_prompts WHERE isPinned = 1"
                    ) ?? 0
                    if pinnedCount >= QuickPrompt.pinnedCap {
                        let current = try QuickPrompt
                            .filter(QuickPrompt.Columns.isPinned == true)
                            .order(QuickPrompt.Columns.sortOrder.asc)
                            .fetchAll(db)
                        throw SwapPinAborted.stillFull(current: current)
                    }
                    let maxPinnedSort = try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM quick_prompts WHERE isPinned = 1"
                    ) ?? -1
                    toPin.isPinned = true
                    toPin.sortOrder = maxPinnedSort + 1
                    toPin.updatedAt = now
                    try toPin.update(db)
                }
                return .ok
            }
        } catch SwapPinAborted.stillFull(let current) {
            return .capExceeded(currentlyPinned: current)
        }
    }

    public func reorder(ids: [UUID], pinned: Bool) throws {
        try dbQueue.write { db in
            let now = Date()
            let pinnedFlag = pinned ? 1 : 0
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE quick_prompts
                        SET sortOrder = ?, updatedAt = ?
                        WHERE id = ? AND isPinned = ?
                        """,
                    arguments: [index, now, id, pinnedFlag]
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

    public func restoreBuiltInDefaults() throws {
        let now = Date()
        let canonical = QuickPrompt.builtInPrompts(now: now)
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
    /// hide. Restoring default pin state must not create a 6th pinned prompt:
    /// if a user filled the slot with a custom prompt, content still restores
    /// but the built-in stays unpinned. If the row is missing entirely, this
    /// is a no-op (the reconciler will re-insert it on the next
    /// `seedIfNeeded()`).
    private func restoreOne(seed: QuickPrompt, db: Database, now: Date) throws {
        guard let existing = try QuickPrompt.fetchOne(db, key: seed.id) else { return }
        let restoredPinned = try restoredPinState(seed: seed, existing: existing, db: db)

        try db.execute(
            sql: """
                UPDATE quick_prompts
                SET label = ?, prompt = ?, groupLabel = ?, sortOrder = ?, isPinned = ?, isBuiltIn = 1, updatedAt = ?
                WHERE id = ?
                """,
            arguments: [
                seed.label,
                seed.prompt,
                seed.groupLabel,
                seed.sortOrder,
                restoredPinned,
                now,
                seed.id,
            ]
        )
    }

    private func restoredPinState(seed: QuickPrompt, existing: QuickPrompt, db: Database) throws -> Bool {
        guard seed.isPinned else { return false }
        if existing.isPinned { return true }

        let pinnedExcludingRow = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM quick_prompts WHERE isPinned = 1 AND id <> ?",
            arguments: [seed.id]
        ) ?? 0
        return pinnedExcludingRow < QuickPrompt.pinnedCap
    }

    // MARK: Import

    public func applyImport(
        _ bundle: QuickPromptBundle,
        mode: QuickPromptImport.Mode,
        dryRun: Bool
    ) throws -> QuickPromptImport.Summary {
        let now = Date()
        let materialized = bundle.prompts.map {
            QuickPromptBundle.materialize($0, now: now)
        }
        var incomingIDs = Set<UUID>()
        for entry in materialized {
            guard incomingIDs.insert(entry.id).inserted else {
                throw QuickPromptImportError.duplicateID(entry.id)
            }
        }

        return try dbQueue.write { db in
            // Normalize inside the write block so case-insensitive group
            // canonicalization sees the freshest existing rows.
            let incoming = try materialized.map { try normalizedForWrite($0, db: db) }
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
        lhs.label == rhs.label
            && lhs.prompt == rhs.prompt
            && lhs.groupLabel == rhs.groupLabel
            && lhs.sortOrder == rhs.sortOrder
            && lhs.isVisible == rhs.isVisible
            && lhs.isPinned == rhs.isPinned
            && lhs.isBuiltIn == rhs.isBuiltIn
    }

    /// Write a merged row, preserving the existing row's `createdAt` so import
    /// does not reset history. Reserved built-in UUIDs keep their canonical
    /// pin-state and built-in status; custom rows cannot forge that status.
    /// Caller is responsible for passing a `normalizedForWrite`-normalized entry.
    private func writeMerged(entry: QuickPrompt, existing: QuickPrompt, db: Database, now: Date) throws {
        var merged = entry
        merged.createdAt = existing.createdAt
        merged.updatedAt = now
        try merged.save(db)
    }

    /// Caller is responsible for passing a `normalizedForWrite`-normalized entry.
    private func writeNew(entry: QuickPrompt, db: Database, now: Date) throws {
        var fresh = entry
        fresh.createdAt = now
        fresh.updatedAt = now
        try fresh.save(db)
    }

    /// Settle every cross-cutting field that should be canonicalized before a
    /// row hits the DB:
    /// - `isBuiltIn` is forced from the canonical UUID set.
    /// - `groupLabel` is trimmed, nil-empty, and snapped to the canonical
    ///   casing of any existing case-insensitive match.
    ///
    /// Pin state is intentionally **not** coerced — even for built-ins. Pin is
    /// user-controlled; imports that forge a built-in's pin state are clipped
    /// in `QuickPromptBundle.materialize`, and re-coercing here would silently
    /// revert a user's manual unpin the next time they edited the row.
    private func normalizedForWrite(_ prompt: QuickPrompt, db: Database) throws -> QuickPrompt {
        var normalized = prompt
        normalized.isBuiltIn = QuickPrompt.builtInPrompt(id: prompt.id) != nil

        if let raw = normalized.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            // Case-insensitive match against the rest of the table; if found,
            // adopt that casing so "capture" and "CAPTURE" don't fork into two
            // visually-distinct buckets. Excludes the row itself so a user
            // editing the canonical "CAPTURE" row to "Capture" can rename it.
            let canonical = try String.fetchOne(
                db,
                sql: """
                    SELECT groupLabel FROM quick_prompts
                    WHERE id <> ?
                      AND groupLabel IS NOT NULL
                      AND LOWER(groupLabel) = LOWER(?)
                    ORDER BY rowid LIMIT 1
                    """,
                arguments: [prompt.id, raw]
            )
            normalized.groupLabel = canonical ?? raw
        } else {
            normalized.groupLabel = nil
        }
        return normalized
    }
}

/// Internal swap-pin abort signal. Caught at the `swapPin` API boundary and
/// converted to `SetPinnedResult.capExceeded` so callers see one result shape.
private enum SwapPinAborted: Error {
    case stillFull(current: [QuickPrompt])
}
