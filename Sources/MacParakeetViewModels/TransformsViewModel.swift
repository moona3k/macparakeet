import Foundation
import MacParakeetCore

public enum TransformHistoryCopyTarget: Sendable, Equatable {
    case input
    case output

    public var statusLabel: String {
        switch self {
        case .input:
            return "Copied original"
        case .output:
            return "Copied result"
        }
    }
}

/// Drives the **Transforms** tab list (ADR-022). Owns the user-visible
/// ordered set of `.transform` prompts plus the "no LLM provider" state
/// surfaced in the hero card.
///
/// Editing a single Transform happens in `TransformEditorViewModel` —
/// this VM owns the *collection*; the editor VM owns one *row's draft state*.
@MainActor
@Observable
public final class TransformsViewModel {
    public nonisolated static let historyFetchLimit = 200

    public var transforms: [Prompt] = []
    public var allPrompts: [Prompt] = []
    public var errorMessage: String?

    /// Recent Transform runs, newest first. Surfaced read-only in the
    /// Transforms tab (copy, delete, clear-all). Capped at
    /// `historyFetchLimit` rows; the DB keeps the full set so power users
    /// who clear and re-fill keep their working window intact.
    public var history: [TransformHistoryEntry] = []
    public var totalHistoryCount: Int = 0
    public var historyErrorMessage: String?

    /// Pending delete confirmation. Set when the user hits delete on a
    /// (non-built-in) Transform; cleared on confirm or cancel.
    public var pendingDeleteTransform: Prompt?
    public var pendingDeleteHistoryEntry: TransformHistoryEntry?
    public var isConfirmingClearHistory: Bool = false
    public var copiedHistoryEntryID: UUID?
    public var copiedHistoryTarget: TransformHistoryCopyTarget?

    /// True when the user has at least one LLM provider configured. Drives
    /// the calm "Configure in Settings" hero state.
    public var hasLLMProvider: Bool = false

    private var repo: PromptRepositoryProtocol?
    private var historyRepo: TransformHistoryRepositoryProtocol?
    private var clipboardService: ClipboardServiceProtocol?
    private var copiedResetTask: Task<Void, Never>?

    /// Passive reloads are allowed to coalesce with each other, but never to
    /// outrank a user mutation. A `.transformHistoryChanged` reload can start
    /// after delete/clear begins and still read the old rows before the write
    /// reaches SQLite; mutation generation keeps that stale snapshot out.
    private var historyLoadGeneration: Int = 0
    private var historyMutationGeneration: Int = 0
    private var activeHistoryMutationCount: Int = 0

    public init() {}

    public func configure(
        repo: PromptRepositoryProtocol,
        historyRepo: TransformHistoryRepositoryProtocol? = nil,
        clipboardService: ClipboardServiceProtocol? = nil,
        hasLLMProvider: Bool
    ) {
        self.repo = repo
        self.historyRepo = historyRepo
        self.clipboardService = clipboardService
        self.hasLLMProvider = hasLLMProvider
        // `loadHistory()` is driven by the view (`.onAppear` and the
        // `.transformHistoryChanged` notification). Doing it here too
        // would race the view's first explicit load and clobber state
        // when the generation-guarded snapshot resolves out of order.
        Task { await load() }
    }

    /// Refresh the list from the repository. Built-ins are seeded by the
    /// reconciler at launch — this view never sees an empty list under
    /// normal operation.
    @discardableResult
    public func load() async -> Bool {
        guard let repo else { return false }
        do {
            let loaded = try await Task.detached(priority: .utility) { [repo] in
                let all = try repo.fetchAll()
                let transforms = all
                    .filter { $0.isVisible && $0.category == .transform }
                    .sorted(by: { lhs, rhs in
                        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    })
                return (all: all, transforms: transforms)
            }.value
            allPrompts = loaded.all
            transforms = loaded.transforms
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func setHasLLMProvider(_ value: Bool) {
        hasLLMProvider = value
    }

    // MARK: - Mutations

    /// Save a new or edited Transform. Wraps the underlying GRDB save and
    /// reloads the list so the UI reflects the change. Does NOT register
    /// the hotkey — the coordinator's `reloadBindings()` is invoked by the
    /// view layer after this returns successfully.
    @discardableResult
    public func save(_ prompt: Prompt) async -> Bool {
        guard let repo else { return false }
        do {
            try await Task.detached(priority: .utility) { [repo, prompt] in
                try repo.save(prompt)
            }.value
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Delete a non-built-in Transform. Built-ins are protected — the
    /// underlying repository refuses them; this helper short-circuits so
    /// the UI can hide the action entirely.
    @discardableResult
    public func delete(_ prompt: Prompt) async -> Bool {
        guard let repo, !prompt.isBuiltIn else { return false }
        do {
            let deleted = try await Task.detached(priority: .utility) { [repo, id = prompt.id] in
                try repo.delete(id: id)
            }.value
            if deleted {
                errorMessage = nil
                await load()
            }
            return deleted
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Confirm a pending delete that was queued via `pendingDeleteTransform`.
    @discardableResult
    public func confirmPendingDelete() async -> Bool {
        guard let pending = pendingDeleteTransform else { return false }
        pendingDeleteTransform = nil
        return await delete(pending)
    }

    // MARK: - History

    /// Refresh the recent runs window from the repository. Capped at
    /// `historyFetchLimit`; `totalHistoryCount` carries the full count for
    /// the "showing N of M" footer.
    public func loadHistory() async {
        guard let historyRepo else {
            historyLoadGeneration += 1
            history = []
            totalHistoryCount = 0
            return
        }
        historyLoadGeneration += 1
        let myLoadGeneration = historyLoadGeneration
        let mutationGenerationAtStart = historyMutationGeneration
        let startedDuringMutation = activeHistoryMutationCount > 0
        do {
            let snapshot = try await Self.fetchHistorySnapshot(
                repo: historyRepo,
                limit: Self.historyFetchLimit
            )
            guard shouldApplyHistoryLoad(
                loadGeneration: myLoadGeneration,
                mutationGenerationAtStart: mutationGenerationAtStart,
                startedDuringMutation: startedDuringMutation
            ) else { return }
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            historyErrorMessage = nil
        } catch {
            guard shouldApplyHistoryLoad(
                loadGeneration: myLoadGeneration,
                mutationGenerationAtStart: mutationGenerationAtStart,
                startedDuringMutation: startedDuringMutation
            ) else { return }
            history = []
            totalHistoryCount = 0
            historyErrorMessage = error.localizedDescription
        }
    }

    public func deleteHistoryEntry(_ entry: TransformHistoryEntry) async {
        guard let historyRepo else { return }
        let myGeneration = beginHistoryMutation()
        defer { endHistoryMutation() }
        do {
            let snapshot = try await Self.deleteHistoryEntryAndFetchSnapshot(
                repo: historyRepo,
                id: entry.id,
                limit: Self.historyFetchLimit
            )
            guard myGeneration == historyMutationGeneration else { return }
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            historyErrorMessage = nil
        } catch {
            guard myGeneration == historyMutationGeneration else { return }
            historyErrorMessage = error.localizedDescription
        }
    }

    public func clearHistory() async {
        guard let historyRepo else { return }
        let myGeneration = beginHistoryMutation()
        defer { endHistoryMutation() }
        do {
            let snapshot = try await Self.clearHistoryAndFetchSnapshot(
                repo: historyRepo,
                limit: Self.historyFetchLimit
            )
            guard myGeneration == historyMutationGeneration else { return }
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            isConfirmingClearHistory = false
            historyErrorMessage = nil
        } catch {
            guard myGeneration == historyMutationGeneration else { return }
            historyErrorMessage = error.localizedDescription
        }
    }

    private func beginHistoryMutation() -> Int {
        historyMutationGeneration += 1
        activeHistoryMutationCount += 1
        return historyMutationGeneration
    }

    private func endHistoryMutation() {
        activeHistoryMutationCount = max(0, activeHistoryMutationCount - 1)
    }

    private func shouldApplyHistoryLoad(
        loadGeneration: Int,
        mutationGenerationAtStart: Int,
        startedDuringMutation: Bool
    ) -> Bool {
        !startedDuringMutation
            && loadGeneration == historyLoadGeneration
            && mutationGenerationAtStart == historyMutationGeneration
            && activeHistoryMutationCount == 0
    }

    /// Copy a prior run's output back to the clipboard.
    public func copyOutputToClipboard(_ entry: TransformHistoryEntry) async {
        await copyHistoryTextToClipboard(entry, target: .output)
    }

    /// Copy a prior run's original selected text back to the clipboard.
    public func copyInputToClipboard(_ entry: TransformHistoryEntry) async {
        await copyHistoryTextToClipboard(entry, target: .input)
    }

    /// Copy a prior run's text back to the clipboard, with a brief affordance
    /// keyed by entry ID and text target so the UI can show precise feedback.
    public func copyHistoryTextToClipboard(
        _ entry: TransformHistoryEntry,
        target: TransformHistoryCopyTarget
    ) async {
        guard let clipboardService else {
            historyErrorMessage = "Clipboard service is unavailable."
            return
        }
        let text = switch target {
        case .input:
            entry.inputText
        case .output:
            entry.outputText
        }
        guard await clipboardService.copyToClipboard(text) else {
            historyErrorMessage = "Could not copy text to the clipboard."
            return
        }
        historyErrorMessage = nil
        copiedResetTask?.cancel()
        copiedHistoryEntryID = entry.id
        copiedHistoryTarget = target
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.copiedHistoryEntryID = nil
            self.copiedHistoryTarget = nil
        }
    }

    private static func fetchHistorySnapshot(
        repo: TransformHistoryRepositoryProtocol,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            try repo.fetchRecentWithCount(limit: limit)
        }.value
    }

    private static func deleteHistoryEntryAndFetchSnapshot(
        repo: TransformHistoryRepositoryProtocol,
        id: UUID,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            _ = try repo.delete(id: id)
            return try repo.fetchRecentWithCount(limit: limit)
        }.value
    }

    private static func clearHistoryAndFetchSnapshot(
        repo: TransformHistoryRepositoryProtocol,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            try repo.deleteAll()
            return try repo.fetchRecentWithCount(limit: limit)
        }.value
    }

    /// Reset a built-in Transform's content / shortcut / runningLabel back
    /// to its canonical defaults from `Prompt.builtInPrompts()`. No-op for
    /// custom Transforms (they don't have a default to revert to).
    @discardableResult
    public func resetBuiltIn(
        _ prompt: Prompt,
        reservedHotkeys: [TransformShortcutReservedHotkey] = []
    ) async -> Bool {
        guard prompt.isBuiltIn, let repo else { return false }
        guard let canonical = Prompt.builtInPrompts().first(where: { $0.id == prompt.id }) else {
            return false
        }
        do {
            let result = try await Task.detached(priority: .utility) { [repo, prompt, canonical, reservedHotkeys] in
                if let shortcut = canonical.shortcut {
                    let persisted = try repo.fetchAll()
                    if let conflict = transformShortcutConflict(
                        for: shortcut,
                        excluding: prompt.id,
                        in: persisted
                    ) {
                        return ResetBuiltInResult.conflict(
                            shortcut: shortcut,
                            conflict: .transform(name: conflict.name)
                        )
                    }
                    if let conflict = reservedHotkeyConflict(for: shortcut, in: reservedHotkeys) {
                        return ResetBuiltInResult.conflict(
                            shortcut: shortcut,
                            conflict: .reservedHotkey(name: conflict.name)
                        )
                    }
                }

                var restored = prompt
                restored.name = canonical.name
                restored.content = canonical.content
                restored.keyboardShortcut = canonical.keyboardShortcut
                restored.runningLabel = canonical.runningLabel
                restored.sortOrder = canonical.sortOrder
                restored.updatedAt = Date()
                try repo.save(restored)
                return .saved
            }.value

            switch result {
            case .saved:
                errorMessage = nil
                await load()
                return true
            case .conflict(let shortcut, let conflict):
                errorMessage = defaultShortcutConflictMessage(
                    shortcut: shortcut,
                    canonicalName: canonical.name,
                    conflict: conflict
                )
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Re-seed missing built-in Transforms only (does NOT overwrite user
    /// edits to existing built-ins). The header's *Reset to defaults*
    /// affordance maps to this.
    @discardableResult
    public func reseedMissingBuiltIns(
        reservedHotkeys: [TransformShortcutReservedHotkey] = []
    ) async -> Bool {
        guard let repo else { return false }
        let canonical = Prompt.builtInPrompts().filter { $0.category == .transform }
        do {
            let clearedShortcuts = try await Task.detached(priority: .utility) { [repo, canonical, reservedHotkeys] in
                var persisted = try repo.fetchAll()
                var existingIDs = Set(persisted.map(\.id))
                var cleared: [String] = []
                for var prompt in canonical where !existingIDs.contains(prompt.id) {
                    if let shortcut = prompt.shortcut,
                       let conflict = transformShortcutConflict(for: shortcut, excluding: prompt.id, in: persisted) {
                        prompt.keyboardShortcut = nil
                        cleared.append("\(prompt.name) (\(shortcut.displayString), used by \(conflict.name))")
                    } else if let shortcut = prompt.shortcut,
                              let conflict = reservedHotkeyConflict(for: shortcut, in: reservedHotkeys) {
                        prompt.keyboardShortcut = nil
                        cleared.append("\(prompt.name) (\(shortcut.displayString), conflicts with \(conflict.name))")
                    }
                    try repo.save(prompt)
                    existingIDs.insert(prompt.id)
                    persisted.append(prompt)
                }
                return cleared
            }.value
            await load()
            if !clearedShortcuts.isEmpty {
                errorMessage = "Restored missing defaults without conflicting shortcuts: \(clearedShortcuts.joined(separator: ", "))."
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Convenience accessors

    public var customTransforms: [Prompt] {
        transforms.filter { !$0.isBuiltIn }
    }

    public var builtInTransforms: [Prompt] {
        transforms.filter(\.isBuiltIn)
    }

    /// Bindings map for the registry — `[Prompt.ID: KeyboardShortcut]`.
    /// View layer hands this to `TransformsCoordinator.reloadBindings()`
    /// after a save / delete / reseed.
    public var shortcutBindings: [UUID: KeyboardShortcut] {
        var bindings: [UUID: KeyboardShortcut] = [:]
        for transform in transforms {
            if let shortcut = transform.shortcut {
                bindings[transform.id] = shortcut
            }
        }
        return bindings
    }
}

private func transformShortcutConflict(
    for candidate: KeyboardShortcut,
    excluding promptID: UUID,
    in prompts: [Prompt]
) -> Prompt? {
    prompts.first { prompt in
        guard prompt.id != promptID,
              prompt.category == .transform,
              prompt.isVisible,
              let shortcut = prompt.shortcut
        else { return false }
        return transformShortcutsMatch(shortcut, candidate)
    }
}

private func transformShortcutsMatch(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
    lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
}

private enum ResetBuiltInResult: Sendable {
    case saved
    case conflict(shortcut: KeyboardShortcut, conflict: DefaultShortcutConflict)
}

private enum DefaultShortcutConflict: Sendable {
    case transform(name: String)
    case reservedHotkey(name: String)
}

private func reservedHotkeyConflict(
    for shortcut: KeyboardShortcut,
    in reservedHotkeys: [TransformShortcutReservedHotkey]
) -> TransformShortcutReservedHotkey? {
    let candidate = shortcut.hotkeyTrigger
    return reservedHotkeys.first { reserved in
        !reserved.trigger.isDisabled && candidate.overlaps(with: reserved.trigger)
    }
}

private func defaultShortcutConflictMessage(
    shortcut: KeyboardShortcut,
    canonicalName: String,
    conflict: DefaultShortcutConflict
) -> String {
    switch conflict {
    case .transform(let name):
        return "Default shortcut \(shortcut.displayString) is already used by Transform “\(name)”. Change that shortcut before resetting \(canonicalName)."
    case .reservedHotkey(let name):
        return "Default shortcut \(shortcut.displayString) conflicts with \(name). Change that hotkey before resetting \(canonicalName)."
    }
}
