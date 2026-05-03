import Foundation
import MacParakeetCore

/// View-model for the live meeting Ask tab quick prompts. Doubles as:
///
/// 1. **Pill data source** — `LiveAskPaneView` reads `visibleStarters` /
///    `visibleFollowUps` to render the chip rows (replacing the old hardcoded
///    `LiveAskStarterPrompts` / `LiveAskFollowUpPrompts` enums).
/// 2. **Manage sheet state** — `AskPromptsSheet` reads `allStarters` /
///    `allFollowUps` (including hidden), the editing/creating state, and
///    invokes save/delete/reorder/restore-default.
///
/// One VM owned by the meeting panel, refreshed on sheet dismiss. Reading from
/// GRDB on every action is fine — these tables are small (≤30 rows in
/// practice) and we want the freshest state after edits.
@MainActor
@Observable
public final class QuickPromptsViewModel {
    public var allStarters: [QuickPrompt] = []
    public var allFollowUps: [QuickPrompt] = []

    /// In-progress edit state for a row in the management sheet.
    public var editingPrompt: QuickPrompt?

    /// Pending new-prompt buffer. `nil` when no creation is in progress;
    /// otherwise holds the kind being created plus draft fields.
    public var creating: Draft?

    public var errorMessage: String?

    private var repo: QuickPromptRepositoryProtocol?

    public init() {}

    public func configure(repo: QuickPromptRepositoryProtocol) {
        self.repo = repo
        refresh()
    }

    // MARK: - Read

    /// Visible starters grouped by `groupLabel`, preserving first-occurrence
    /// group order so users who reorder rows control how groups appear.
    public var visibleStarters: [QuickPrompt] {
        allStarters.filter(\.isVisible)
    }

    public var visibleFollowUps: [QuickPrompt] {
        allFollowUps.filter(\.isVisible)
    }

    /// Visible starters grouped for `LiveAskPaneView`'s `StarterPromptList`.
    /// Stable order: groups appear in the order their first member is seen
    /// (mirrors the legacy hardcoded enum behavior).
    public var visibleStarterGroups: [(label: String, prompts: [QuickPrompt])] {
        var seen: [String] = []
        var buckets: [String: [QuickPrompt]] = [:]
        for prompt in visibleStarters {
            let key = prompt.groupLabel ?? ""
            if buckets[key] == nil { seen.append(key) }
            buckets[key, default: []].append(prompt)
        }
        return seen.map { (label: $0, prompts: buckets[$0] ?? []) }
    }

    public func refresh() {
        guard let repo else { return }
        do {
            allStarters = try repo.fetchAll(kind: .starter)
            allFollowUps = try repo.fetchAll(kind: .followUp)
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

    public func startCreating(kind: QuickPrompt.Kind) {
        creating = Draft(kind: kind)
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

        let nextSortOrder: Int = {
            switch draft.kind {
            case .starter:  return (allStarters.map(\.sortOrder).max() ?? -1) + 1
            case .followUp: return (allFollowUps.map(\.sortOrder).max() ?? -1) + 1
            }
        }()

        let group: String? = draft.kind == .starter
            ? draft.groupLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            : nil

        let prompt = QuickPrompt(
            kind: draft.kind,
            label: trimmedLabel,
            prompt: trimmedPrompt,
            groupLabel: group,
            sortOrder: nextSortOrder,
            isVisible: true,
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

    /// Reorder within a kind. Caller passes the new full ordered list of ids
    /// for that kind.
    public func reorder(ids: [UUID], within kind: QuickPrompt.Kind) {
        guard let repo else { return }
        do {
            try repo.reorder(ids: ids, within: kind)
            refresh()
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

    public func restoreBuiltInDefaults(kind: QuickPrompt.Kind) {
        guard let repo else { return }
        do {
            try repo.restoreBuiltInDefaults(kind: kind)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Draft

    public struct Draft: Sendable {
        public var kind: QuickPrompt.Kind
        public var label: String
        public var prompt: String
        public var groupLabel: String

        public init(kind: QuickPrompt.Kind, label: String = "", prompt: String = "", groupLabel: String = "") {
            self.kind = kind
            self.label = label
            self.prompt = prompt
            self.groupLabel = groupLabel
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
