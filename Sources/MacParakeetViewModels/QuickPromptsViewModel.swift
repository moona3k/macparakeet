import Foundation
import MacParakeetCore

/// View-model for the live meeting Ask tab quick prompts. Doubles as:
///
/// 1. **Pill data source** — `LiveAskPaneView` reads `visiblePinned` (strip)
///    and `visiblePromptGroups` (empty state + sparkle popover).
/// 2. **Manage sheet state** — `AskPromptsSheet` reads `allPrompts` (including
///    hidden), the editing/creating state, and invokes save / delete /
///    reorder / pin / restore-default.
///
/// One VM owned by the meeting panel, refreshed on sheet dismiss. Reading from
/// GRDB on every action is fine — these tables are small (≤30 rows in
/// practice) and we want the freshest state after edits.
@MainActor
@Observable
public final class QuickPromptsViewModel {
    /// Full library, ordered (unpinned ASC by sortOrder, then pinned ASC).
    public var allPrompts: [QuickPrompt] = []

    /// In-progress edit state for a row in the management sheet.
    public var editingPrompt: QuickPrompt?

    /// Pending new-prompt buffer. `nil` when no creation is in progress;
    /// otherwise holds the draft fields plus a default pin state.
    public var creating: Draft?

    public var errorMessage: String?

    private var repo: QuickPromptRepositoryProtocol?

    public init() {}

    public func configure(repo: QuickPromptRepositoryProtocol) {
        self.repo = repo
        refresh()
    }

    // MARK: - Read

    // `allPrompts` is loaded via `repo.fetchAll()` which orders by
    // `(isPinned ASC, sortOrder ASC)` — unpinned first, then pinned, sortOrder
    // ascending within each bucket. The accessors below trust that order.

    /// Visible pinned prompts in pinned-bucket sortOrder. Drives the
    /// horizontally-scrollable after-response strip. Pinning is unbounded;
    /// the strip's edge-fade affordance handles overflow.
    public var visiblePinned: [QuickPrompt] {
        allPrompts.filter { $0.isVisible && $0.isPinned }
    }

    /// All visible prompts grouped for the empty-state list and sparkle
    /// popover. Stable group order: groups appear in the order their first
    /// member is seen, with unpinned groups before the unnamed pinned cluster
    /// (which falls naturally to the end given pinned prompts seed without a
    /// `groupLabel`).
    ///
    /// Bucketing is **case-insensitive** so "capture" and "CAPTURE" merge into
    /// one group. The first occurrence's casing wins for the displayed label.
    /// Save-time canonicalization in the repository keeps storage consistent,
    /// but this view-layer fold is also belt-and-suspenders for any imported
    /// rows that bypass `normalizedForWrite`.
    public var visiblePromptGroups: [(label: String, prompts: [QuickPrompt])] {
        let visible = allPrompts.filter(\.isVisible)
        var seen: [String] = []
        var labelByKey: [String: String] = [:]
        var buckets: [String: [QuickPrompt]] = [:]
        for prompt in visible {
            let displayLabel = prompt.groupLabel ?? ""
            let key = displayLabel.lowercased()
            if buckets[key] == nil {
                seen.append(key)
                labelByKey[key] = displayLabel
            }
            buckets[key, default: []].append(prompt)
        }
        return seen.map { key in
            (label: labelByKey[key] ?? "", prompts: buckets[key] ?? [])
        }
    }

    /// Editor zone — pinned subset (always full subset, including hidden
    /// rows so the editor can show what's pinned but currently hidden).
    public var allPinned: [QuickPrompt] {
        allPrompts.filter(\.isPinned)
    }

    /// Editor zone — the rest. Hidden rows included for the same reason.
    public var allUnpinned: [QuickPrompt] {
        allPrompts.filter { !$0.isPinned }
    }

    public var pinnedCount: Int { allPrompts.filter(\.isPinned).count }

    public func refresh() {
        guard let repo else { return }
        do {
            allPrompts = try repo.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mutations

    /// Save in-progress edit. Validates label/prompt non-empty.
    @discardableResult
    public func saveEdit(_ prompt: QuickPrompt) -> Bool {
        guard let repo else { return false }
        let trimmedLabel = prompt.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedPrompt.isEmpty else {
            errorMessage = "Label and prompt are required."
            return false
        }

        var updated = prompt
        updated.label = trimmedLabel
        updated.prompt = trimmedPrompt
        if let group = updated.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) {
            updated.groupLabel = group.isEmpty ? nil : group
        }
        updated.updatedAt = Date()

        do {
            try repo.save(updated)
            editingPrompt = nil
            errorMessage = nil
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func startCreating(pinned: Bool = false) {
        creating = Draft(isPinned: pinned)
        errorMessage = nil
    }

    @discardableResult
    public func commitCreating() -> Bool {
        guard let repo, let draft = creating else { return false }
        let trimmedLabel = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedPrompt.isEmpty else {
            errorMessage = "Label and prompt are required."
            return false
        }

        // New prompts always start unpinned regardless of the draft hint.
        // Pinning is an explicit follow-up action.
        let nextSortOrder = (allUnpinned.map(\.sortOrder).max() ?? -1) + 1

        let group: String? = draft.groupLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let prompt = QuickPrompt(
            label: trimmedLabel,
            prompt: trimmedPrompt,
            groupLabel: group,
            sortOrder: nextSortOrder,
            isVisible: true,
            isPinned: false,
            isBuiltIn: false
        )

        do {
            try repo.save(prompt)
            creating = nil
            errorMessage = nil
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func cancelCreating() {
        creating = nil
        errorMessage = nil
    }

    public func toggleVisibility(_ prompt: QuickPrompt) {
        guard let repo else { return }
        do {
            try repo.toggleVisibility(id: prompt.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ prompt: QuickPrompt) {
        guard let repo, !prompt.isBuiltIn else { return }
        do {
            _ = try repo.delete(id: prompt.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reorder within a pin-bucket. Caller passes the new full ordered list of
    /// ids for that bucket. Pinned and unpinned reorder independently.
    public func reorder(ids: [UUID], pinned: Bool) {
        guard let repo else { return }
        do {
            try repo.reorder(ids: ids, pinned: pinned)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pin or unpin a prompt. Pinning is unbounded.
    public func togglePin(_ prompt: QuickPrompt) {
        guard let repo else { return }
        let target = !prompt.isPinned
        do {
            switch try repo.setPinned(id: prompt.id, isPinned: target) {
            case .ok:
                refresh()
            case .notFound:
                errorMessage = "Prompt no longer exists."
                refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreSingleDefault(_ prompt: QuickPrompt) {
        guard let repo, prompt.isBuiltIn else { return }
        do {
            try repo.restoreBuiltInDefault(id: prompt.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreAllBuiltInDefaults() {
        guard let repo else { return }
        do {
            try repo.restoreBuiltInDefaults()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Draft

    public struct Draft: Sendable {
        public var label: String
        public var prompt: String
        public var groupLabel: String
        /// Hint for the create sheet only; new prompts always persist as
        /// unpinned regardless. Kept as a field so future flows could change
        /// the default behavior without rewiring.
        public var isPinned: Bool

        public init(label: String = "", prompt: String = "", groupLabel: String = "", isPinned: Bool = false) {
            self.label = label
            self.prompt = prompt
            self.groupLabel = groupLabel
            self.isPinned = isPinned
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
