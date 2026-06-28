import Foundation
import GRDB

public protocol PromptRepositoryProtocol: Sendable {
    func save(_ prompt: Prompt) throws
    func fetch(id: UUID) throws -> Prompt?
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
    func restoreDefaults() throws
}

public final class PromptRepository: PromptRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ prompt: Prompt) throws {
        try dbQueue.write { db in
            try prompt.save(db)
        }
    }

    public func fetch(id: UUID) throws -> Prompt? {
        try dbQueue.read { db in
            try Prompt.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [Prompt] {
        try dbQueue.read { db in
            try Prompt
                .order(Prompt.Columns.sortOrder.asc, Prompt.Columns.name.asc)
                .fetchAll(db)
        }
    }

    public func fetchVisible(category: Prompt.Category? = nil) throws -> [Prompt] {
        try dbQueue.read { db in
            var request = Prompt
                .filter(Prompt.Columns.isVisible == true)
                .order(Prompt.Columns.sortOrder.asc, Prompt.Columns.name.asc)
            if let category {
                request = request.filter(Prompt.Columns.category == category.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchAutoRunPrompts() throws -> [Prompt] {
        try dbQueue.read { db in
            try Prompt
                .filter(Prompt.Columns.isAutoRun == true)
                .filter(Prompt.Columns.isVisible == true)
                .filter(Prompt.Columns.category == Prompt.Category.result.rawValue)
                .order(Prompt.Columns.sortOrder.asc, Prompt.Columns.name.asc)
                .fetchAll(db)
        }
    }

    public func fetchAutoRunPrompts(for sourceType: Transcription.SourceType) throws -> [Prompt] {
        // `appliesToSources` is JSON (set membership isn't expressible in the
        // GRDB query builder), so filter the small auto-run set in Swift via
        // the model's centralized rule.
        try fetchAutoRunPrompts().filter { $0.autoRuns(for: sourceType) }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            guard let prompt = try Prompt.fetchOne(db, key: id) else { return false }
            guard !prompt.isBuiltIn else { return false }
            return try Prompt.deleteOne(db, key: id)
        }
    }

    public func toggleVisibility(id: UUID) throws {
        try dbQueue.write { db in
            guard var prompt = try Prompt.fetchOne(db, key: id) else { return }
            prompt.isVisible.toggle()
            if !prompt.isVisible {
                prompt.isAutoRun = false
            }
            prompt.updatedAt = Date()
            try prompt.update(db)
        }
    }

    public func toggleAutoRun(id: UUID) throws {
        try dbQueue.write { db in
            guard var prompt = try Prompt.fetchOne(db, key: id) else { return }
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
            try prompt.update(db)
        }
    }

    public func setAutoRun(id: UUID, source: Transcription.SourceType, enabled: Bool) throws {
        try dbQueue.write { db in
            guard var prompt = try Prompt.fetchOne(db, key: id) else { return }
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
            try prompt.update(db)
        }
    }

    public func restoreDefaults() throws {
        try dbQueue.write { db in
            // Result-prompt built-ins ship unscoped (appliesToSources = NULL →
            // all sources), so restoring defaults clears any per-source
            // narrowing the user applied via the Meetings "After each meeting"
            // card. Transform built-ins have their own restore/reset surface and
            // are deliberately left untouched here.
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET isVisible = 1, appliesToSources = NULL, updatedAt = ?
                    WHERE isBuiltIn = 1 AND category = ?
                    """,
                arguments: [Date(), Prompt.Category.result.rawValue]
            )
        }
    }
}
