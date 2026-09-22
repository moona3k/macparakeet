import Foundation
import GRDB

public protocol PromptRepositoryProtocol: Sendable {
    func save(_ prompt: Prompt) throws
    func fetch(id: UUID) throws -> Prompt?
    func fetchIncludingDeleted(id: UUID) throws -> Prompt?
    func fetchDeleted() throws -> [Prompt]
    func fetchAll() throws -> [Prompt]
    func fetchVisible(category: Prompt.Category?) throws -> [Prompt]
    func fetchAutoRunPrompts() throws -> [Prompt]
    /// Auto-run `.result` prompts that apply to the given transcription source
    /// (unscoped prompts apply to all sources). Used by the post-transcription
    /// auto-run trigger so meeting-scoped prompts don't fire on file/YouTube.
    func fetchAutoRunPrompts(for sourceType: Transcription.SourceType) throws -> [Prompt]
    func delete(id: UUID) throws -> Bool
    func toggleVisibility(id: UUID) throws
    func toggleAutoRun(id: UUID) throws
    /// Enable/disable auto-run of a `.result` prompt for a single source,
    /// adjusting `appliesToSources` so other sources are unaffected.
    func setAutoRun(id: UUID, source: Transcription.SourceType, enabled: Bool) throws
    /// Enable/disable automatic meeting-note context for a `.result` prompt.
    /// Transform prompts ignore this setting.
    func setIncludeMeetingNotes(id: UUID, enabled: Bool) throws
    func restoreDefaults() throws
}

public extension PromptRepositoryProtocol {
    func setIncludeMeetingNotes(id: UUID, enabled: Bool) throws {
        guard var prompt = try fetch(id: id), prompt.category == .result else { return }
        prompt.includeMeetingNotes = enabled
        prompt.updatedAt = Date()
        try save(prompt)
    }

    func fetchIncludingDeleted(id: UUID) throws -> Prompt? {
        try fetch(id: id)
    }

    func fetchDeleted() throws -> [Prompt] {
        []
    }
}

public final class PromptRepository: PromptRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ prompt: Prompt) throws {
        try PromptEditingService(dbQueue: dbQueue).save(prompt)
    }

    public func fetch(id: UUID) throws -> Prompt? {
        try dbQueue.read { db in
            try PromptQuery.fetch(id: id, includingDeleted: false, db: db)
        }
    }

    /// Administrative/trash lookup. Normal fetch APIs intentionally exclude
    /// soft-deleted prompts.
    public func fetchIncludingDeleted(id: UUID) throws -> Prompt? {
        try dbQueue.read { db in
            try PromptQuery.fetch(id: id, includingDeleted: true, db: db)
        }
    }

    public func fetchDeleted() throws -> [Prompt] {
        try dbQueue.read { db in
            try Prompt.fetchAll(
                db,
                sql: PromptQuery.select
                    + " WHERE p.deletedAt IS NOT NULL ORDER BY p.updatedAt DESC, p.name ASC"
            )
        }
    }

    public func fetchAll() throws -> [Prompt] {
        try dbQueue.read { db in
            try PromptQuery.fetchAll(db: db)
        }
    }

    public func fetchVisible(category: Prompt.Category? = nil) throws -> [Prompt] {
        try dbQueue.read { db in
            try PromptQuery.fetchAll(category: category, visibleOnly: true, db: db)
        }
    }

    public func fetchAutoRunPrompts() throws -> [Prompt] {
        try dbQueue.read { db in
            try PromptQuery.fetchAll(visibleOnly: true, autoRunOnly: true, db: db)
        }
    }

    public func fetchAutoRunPrompts(for sourceType: Transcription.SourceType) throws -> [Prompt] {
        // `appliesToSources` is JSON (set membership isn't expressible in the
        // GRDB query builder), so filter the small auto-run set in Swift via
        // the model's centralized rule.
        try fetchAutoRunPrompts().filter { $0.autoRuns(for: sourceType) }
    }

    public func delete(id: UUID) throws -> Bool {
        try PromptEditingService(dbQueue: dbQueue).softDelete(id: id)
    }

    public func toggleVisibility(id: UUID) throws {
        try dbQueue.write { db in
            guard var prompt = try PromptQuery.fetch(id: id, includingDeleted: false, db: db) else { return }
            prompt.isVisible.toggle()
            if !prompt.isVisible {
                prompt.isAutoRun = false
            }
            prompt.updatedAt = Date()
            try updateMetadata(prompt, db: db)
        }
    }

    public func toggleAutoRun(id: UUID) throws {
        try dbQueue.write { db in
            guard var prompt = try PromptQuery.fetch(id: id, includingDeleted: false, db: db) else { return }
            guard prompt.category == .result else { return }

            prompt.isAutoRun.toggle()
            if prompt.isAutoRun {
                // Auto-run prompts must be visible. This global toggle means
                // "all sources", so enabling clears any per-source scoping.
                // IMPORTANT cross-surface behavior: a prompt narrowed to a
                // single source elsewhere (e.g. `.meeting` via the Meetings
                // "After each meeting" card, reachable from this view's Manage
                // deep-link) is widened back to all sources here. That's
                // deliberate — it's the reset path. Don't "fix" it to preserve
                // scope without revisiting that UX (see ADR-020 2026-05 amendment).
                prompt.isVisible = true
                prompt.appliesToSources = nil
            }
            prompt.updatedAt = Date()
            try updateMetadata(prompt, db: db)
        }
    }

    public func setAutoRun(id: UUID, source: Transcription.SourceType, enabled: Bool) throws {
        try dbQueue.write { db in
            guard var prompt = try PromptQuery.fetch(id: id, includingDeleted: false, db: db) else { return }
            guard prompt.category == .result else { return }

            if enabled {
                prompt.isVisible = true
                if !prompt.isAutoRun {
                    // Was fully off — scope to just this source so enabling it
                    // here never leaks auto-run onto other transcription types.
                    prompt.isAutoRun = true
                    prompt.appliesToSources = [source]
                } else if prompt.appliesToSources != nil {
                    prompt.appliesToSources?.insert(source)
                }
                // else: already auto-run + unscoped (all sources) → already on.

                // Normalize a set that now covers every source back to the
                // canonical "all sources" form (nil). Keeps an explicit full
                // set from going stale — a future SourceType case is then
                // auto-included rather than silently excluded.
                if prompt.appliesToSources == Set(Transcription.SourceType.allCases) {
                    prompt.appliesToSources = nil
                }
            } else {
                if prompt.appliesToSources == nil {
                    // Currently all sources — narrow to everything but `source`.
                    prompt.appliesToSources = Set(Transcription.SourceType.allCases).subtracting([source])
                } else {
                    prompt.appliesToSources?.remove(source)
                }
                // No sources left → no longer auto-runs anywhere; reset to a
                // clean off state (nil scope is meaningless when off).
                if prompt.appliesToSources?.isEmpty == true {
                    prompt.isAutoRun = false
                    prompt.appliesToSources = nil
                }
            }
            prompt.updatedAt = Date()
            try updateMetadata(prompt, db: db)
        }
    }

    public func setIncludeMeetingNotes(id: UUID, enabled: Bool) throws {
        try dbQueue.write { db in
            guard let prompt = try PromptQuery.fetch(id: id, includingDeleted: false, db: db),
                prompt.category == .result
            else { return }
            try db.execute(
                sql: "UPDATE prompts SET includeMeetingNotes = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                arguments: [enabled, Date(), id]
            )
        }
    }

    public func restoreDefaults() throws {
        try dbQueue.write { db in
            let now = Date()
            // Result-prompt built-ins ship unscoped (appliesToSources = NULL →
            // all sources), so restoring defaults clears any per-source
            // narrowing the user applied via the Meetings "After each meeting"
            // card. Built-in Transforms keep their dedicated restore/reset
            // surface, but the legacy `prompts restore-defaults` behavior still
            // re-shows hidden Transform built-ins during the 2.x compatibility
            // window.
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET isVisible = 1, appliesToSources = NULL, updatedAt = ?
                    WHERE isBuiltIn = 1 AND category = ? AND deletedAt IS NULL
                    """,
                arguments: [now, Prompt.Category.result.rawValue]
            )
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET isVisible = 1, updatedAt = ?
                    WHERE isBuiltIn = 1 AND category = ? AND deletedAt IS NULL
                    """,
                arguments: [now, Prompt.Category.transform.rawValue]
            )
        }
    }

    private func updateMetadata(_ prompt: Prompt, db: Database) throws {
        let encodedSources: String? = try prompt.appliesToSources.map { sources in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(sources), as: UTF8.self)
        }
        try db.execute(
            sql: """
                UPDATE prompts
                SET isVisible = ?, isAutoRun = ?, appliesToSources = ?, updatedAt = ?
                WHERE id = ? AND deletedAt IS NULL
                """,
            arguments: [
                prompt.isVisible,
                prompt.isAutoRun,
                encodedSources,
                prompt.updatedAt,
                prompt.id,
            ]
        )
    }
}
