import Foundation
import MacParakeetCore

public struct TransformShortcutReservedHotkey: Sendable, Equatable {
    public let name: String
    public let trigger: HotkeyTrigger

    public init(name: String, trigger: HotkeyTrigger) {
        self.name = name
        self.trigger = trigger
    }
}

/// Drives the **Transforms** tab (ADR-022 + Workbench). Owns the ordered set of
/// `.transform` prompts, the selected workbench draft, local history, structured
/// rules, and writing samples.
@MainActor
@Observable
public final class TransformsViewModel {
    public nonisolated static let historyFetchLimit = 200
    public nonisolated static let minimumWritingSampleWords = 50

    public var transforms: [Prompt] = []
    public var profiles: [UUID: TransformProfile] = [:]
    public var history: [TransformHistoryEntry] = []
    public var totalHistoryCount: Int = 0
    public var writingSamples: [WritingSample] = []
    public var errorMessage: String?
    public var historyErrorMessage: String?
    public var writingSampleErrorMessage: String?

    public var selectedTransformID: UUID?
    public var isCreatingDraft = false

    public var draftName: String = ""
    public var draftContent: String = ""
    public var draftRunningLabel: String = ""
    public var draftShortcut: KeyboardShortcut?
    public var draftEnabledRuleIDs: Set<String> = []
    public var draftCustomInstructions: String = ""
    public var draftUseWritingSamples: Bool = false

    public var nameError: String?
    public var contentError: String?
    public var shortcutError: String?

    public var pendingDeleteTransform: Prompt?
    public var pendingDeleteHistoryEntry: TransformHistoryEntry?
    public var pendingDeleteWritingSample: WritingSample?
    public var isConfirmingClearHistory: Bool = false
    public var copiedHistoryEntryID: UUID?

    public var isAddingWritingSample: Bool = false
    public var writingSampleTitle: String = ""
    public var writingSampleText: String = ""

    public var hasLLMProvider: Bool = false

    private var repo: PromptRepositoryProtocol?
    private var profileRepo: TransformProfileRepositoryProtocol?
    private var historyRepo: TransformHistoryRepositoryProtocol?
    private var clipboardService: ClipboardServiceProtocol?
    private var writingSampleRepo: WritingSampleRepositoryProtocol?
    private var copiedResetTask: Task<Void, Never>?

    public init() {}

    public func configure(
        repo: PromptRepositoryProtocol,
        profileRepo: TransformProfileRepositoryProtocol? = nil,
        historyRepo: TransformHistoryRepositoryProtocol? = nil,
        clipboardService: ClipboardServiceProtocol? = nil,
        writingSampleRepo: WritingSampleRepositoryProtocol? = nil,
        hasLLMProvider: Bool
    ) {
        self.repo = repo
        self.profileRepo = profileRepo
        self.historyRepo = historyRepo
        self.clipboardService = clipboardService
        self.writingSampleRepo = writingSampleRepo
        self.hasLLMProvider = hasLLMProvider
        load()
        loadProfiles()
        loadWritingSamples()
        if let selectedTransform {
            loadDraft(from: selectedTransform)
        } else {
            ensureSelection()
        }
        Task {
            await loadHistory()
        }
    }

    public func load() {
        guard let repo else { return }
        do {
            transforms = try repo
                .fetchVisible(category: .transform)
                .sorted(by: { lhs, rhs in
                    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                })
            errorMessage = nil
            ensureSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadProfiles() {
        guard let profileRepo else { return }
        do {
            profiles = Dictionary(uniqueKeysWithValues: try profileRepo.fetchAll().map { ($0.promptId, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadHistory() async {
        guard let historyRepo else {
            history = []
            totalHistoryCount = 0
            return
        }
        do {
            let snapshot = try await Self.fetchHistorySnapshot(
                repo: historyRepo,
                limit: Self.historyFetchLimit
            )
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            historyErrorMessage = nil
        } catch {
            history = []
            totalHistoryCount = 0
            historyErrorMessage = error.localizedDescription
        }
    }

    public func loadWritingSamples() {
        guard let writingSampleRepo else { return }
        do {
            writingSamples = try writingSampleRepo.fetchAll()
            writingSampleErrorMessage = nil
        } catch {
            writingSamples = []
            writingSampleErrorMessage = error.localizedDescription
        }
    }

    public func setHasLLMProvider(_ value: Bool) {
        hasLLMProvider = value
    }

    public func selectTransform(_ prompt: Prompt) {
        selectedTransformID = prompt.id
        isCreatingDraft = false
        loadDraft(from: prompt)
    }

    public func startCreatingTransform() {
        selectedTransformID = nil
        isCreatingDraft = true
        let draft = Prompt(
            name: "New Transform",
            content: "",
            category: .transform,
            sortOrder: 200
        )
        draftName = ""
        draftContent = ""
        draftRunningLabel = ""
        draftShortcut = nil
        let profile = TransformProfile.defaultProfile(for: draft)
        draftEnabledRuleIDs = profile.enabledRuleIDs
        draftCustomInstructions = ""
        draftUseWritingSamples = false
        clearValidation()
    }

    public func cancelCreate() {
        isCreatingDraft = false
        ensureSelection(force: true)
    }

    @discardableResult
    public func saveDraft(
        reservedHotkeys: [TransformShortcutReservedHotkey],
        collisionChecker: TransformShortcutCollisionChecking
    ) -> Bool {
        validateDraft(reservedHotkeys: reservedHotkeys, collisionChecker: collisionChecker)
        guard isDraftValid, let repo else { return false }

        let now = Date()
        let trimmedName = normalizedDraftName
        let trimmedContent = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = draftRunningLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = draftCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved: Prompt
        if isCreatingDraft {
            saved = Prompt(
                id: UUID(),
                name: trimmedName,
                content: trimmedContent,
                category: .transform,
                isBuiltIn: false,
                isVisible: true,
                isAutoRun: false,
                sortOrder: nextCustomSortOrder,
                createdAt: now,
                updatedAt: now,
                keyboardShortcut: draftShortcut?.encodedString(),
                runningLabel: trimmedLabel.isEmpty ? nil : trimmedLabel
            )
        } else if let original = selectedTransform {
            var updated = original
            updated.name = trimmedName
            updated.content = trimmedContent
            updated.keyboardShortcut = draftShortcut?.encodedString()
            updated.runningLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
            updated.updatedAt = now
            saved = updated
        } else {
            return false
        }

        do {
            try repo.save(saved)
            var profile = profiles[saved.id] ?? TransformProfile.defaultProfile(for: saved)
            profile.promptId = saved.id
            profile.setEnabledRuleIDs(draftEnabledRuleIDs)
            profile.customInstructions = trimmedInstructions.isEmpty ? nil : trimmedInstructions
            profile.useWritingSamples = draftUseWritingSamples
            profile.updatedAt = now
            if profile.createdAt > now {
                profile.createdAt = now
            }
            try profileRepo?.save(profile)
            profiles[saved.id] = profile
            isCreatingDraft = false
            selectedTransformID = saved.id
            errorMessage = nil
            load()
            loadDraft(from: saved)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func delete(_ prompt: Prompt) -> Bool {
        guard let repo, !prompt.isBuiltIn else { return false }
        do {
            let deleted = try repo.delete(id: prompt.id)
            if deleted {
                _ = try? profileRepo?.delete(promptId: prompt.id)
                profiles[prompt.id] = nil
                errorMessage = nil
                load()
                ensureSelection(force: true)
            }
            return deleted
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func confirmPendingDelete() {
        guard let pending = pendingDeleteTransform else { return }
        pendingDeleteTransform = nil
        delete(pending)
    }

    public func confirmPendingHistoryDelete() async {
        guard let pending = pendingDeleteHistoryEntry else { return }
        pendingDeleteHistoryEntry = nil
        await deleteHistoryEntry(pending)
    }

    public func confirmPendingWritingSampleDelete() {
        guard let pending = pendingDeleteWritingSample else { return }
        pendingDeleteWritingSample = nil
        deleteWritingSample(pending)
    }

    public func deleteHistoryEntry(_ entry: TransformHistoryEntry) async {
        guard let historyRepo else { return }
        do {
            let snapshot = try await Self.deleteHistoryEntryAndFetchSnapshot(
                repo: historyRepo,
                id: entry.id,
                limit: Self.historyFetchLimit
            )
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    public func clearHistory() async {
        guard let historyRepo else { return }
        do {
            let snapshot = try await Self.clearHistoryAndFetchSnapshot(
                repo: historyRepo,
                limit: Self.historyFetchLimit
            )
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            isConfirmingClearHistory = false
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    public func clearSelectedHistory() async {
        guard let historyRepo else { return }
        guard let selectedTransformID else {
            isConfirmingClearHistory = false
            return
        }
        do {
            let snapshot = try await Self.deleteHistoryForTransformAndFetchSnapshot(
                repo: historyRepo,
                transformId: selectedTransformID,
                limit: Self.historyFetchLimit
            )
            history = snapshot.entries
            totalHistoryCount = snapshot.totalCount
            isConfirmingClearHistory = false
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    public func copyOutputToClipboard(_ entry: TransformHistoryEntry) async {
        guard let clipboardService else {
            historyErrorMessage = "Clipboard service is unavailable."
            return
        }

        guard await clipboardService.copyToClipboard(entry.outputText) else {
            historyErrorMessage = "Could not copy transformed text to the clipboard."
            return
        }

        historyErrorMessage = nil
        copiedResetTask?.cancel()
        copiedHistoryEntryID = entry.id
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.copiedHistoryEntryID = nil
        }
    }

    private static func fetchHistorySnapshot(
        repo: TransformHistoryRepositoryProtocol,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            let entries = try repo.fetchRecent(limit: limit)
            let totalCount = try repo.count()
            return (entries, totalCount)
        }.value
    }

    private static func deleteHistoryEntryAndFetchSnapshot(
        repo: TransformHistoryRepositoryProtocol,
        id: UUID,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            _ = try repo.delete(id: id)
            let entries = try repo.fetchRecent(limit: limit)
            let totalCount = try repo.count()
            return (entries, totalCount)
        }.value
    }

    private static func deleteHistoryForTransformAndFetchSnapshot(
        repo: TransformHistoryRepositoryProtocol,
        transformId: UUID,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            try repo.deleteAll(transformId: transformId)
            let entries = try repo.fetchRecent(limit: limit)
            let totalCount = try repo.count()
            return (entries, totalCount)
        }.value
    }

    private static func clearHistoryAndFetchSnapshot(
        repo: TransformHistoryRepositoryProtocol,
        limit: Int
    ) async throws -> (entries: [TransformHistoryEntry], totalCount: Int) {
        try await Task.detached(priority: .userInitiated) {
            try repo.deleteAll()
            let entries = try repo.fetchRecent(limit: limit)
            let totalCount = try repo.count()
            return (entries, totalCount)
        }.value
    }

    /// Reset a built-in Transform's content / shortcut / runningLabel back
    /// to its canonical defaults from `Prompt.builtInPrompts()`. No-op for
    /// custom Transforms (they don't have a default to revert to).
    @discardableResult
    public func resetBuiltIn(_ prompt: Prompt) -> Bool {
        guard prompt.isBuiltIn, repo != nil else { return false }
        guard let canonical = Prompt.builtInPrompts().first(where: { $0.id == prompt.id }) else {
            return false
        }
        var restored = prompt
        restored.name = canonical.name
        restored.content = canonical.content
        restored.keyboardShortcut = canonical.keyboardShortcut
        restored.runningLabel = canonical.runningLabel
        restored.sortOrder = canonical.sortOrder
        restored.updatedAt = Date()
        do {
            _ = try profileRepo?.delete(promptId: prompt.id)
            profiles[prompt.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        let saved = save(restored)
        if saved {
            selectedTransformID = restored.id
            loadDraft(from: restored)
        }
        return saved
    }

    @discardableResult
    public func save(_ prompt: Prompt) -> Bool {
        guard let repo else { return false }
        do {
            try repo.save(prompt)
            errorMessage = nil
            load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func reseedMissingBuiltIns() {
        guard let repo else { return }
        let existingIDs = Set(transforms.map(\.id))
        let canonical = Prompt.builtInPrompts().filter { $0.category == .transform }
        for prompt in canonical where !existingIDs.contains(prompt.id) {
            do {
                try repo.save(prompt)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        load()
    }

    public func saveWritingSample() -> Bool {
        guard let writingSampleRepo else { return false }
        let text = writingSampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = WritingSample.countWords(in: text)
        guard words >= Self.minimumWritingSampleWords else {
            writingSampleErrorMessage = "Add at least \(Self.minimumWritingSampleWords) words so MacParakeet can learn from the sample."
            return false
        }
        let title = writingSampleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let sample = WritingSample(
            title: title.isEmpty ? "Writing sample \(writingSamples.count + 1)" : title,
            text: text,
            wordCount: words,
            createdAt: now,
            updatedAt: now
        )
        do {
            try writingSampleRepo.save(sample)
            writingSampleTitle = ""
            writingSampleText = ""
            isAddingWritingSample = false
            writingSampleErrorMessage = nil
            loadWritingSamples()
            return true
        } catch {
            writingSampleErrorMessage = error.localizedDescription
            return false
        }
    }

    public func deleteWritingSample(_ sample: WritingSample) {
        guard let writingSampleRepo else { return }
        do {
            _ = try writingSampleRepo.delete(id: sample.id)
            writingSamples.removeAll { $0.id == sample.id }
            writingSampleErrorMessage = nil
        } catch {
            writingSampleErrorMessage = error.localizedDescription
        }
    }

    public func validateDraft(
        reservedHotkeys: [TransformShortcutReservedHotkey],
        collisionChecker: TransformShortcutCollisionChecking
    ) {
        validateName()
        validateContent()
        validateShortcut(reservedHotkeys: reservedHotkeys, collisionChecker: collisionChecker)
    }

    public var selectedTransform: Prompt? {
        guard let selectedTransformID else { return nil }
        return transforms.first(where: { $0.id == selectedTransformID })
    }

    public var activeRules: [TransformRule] {
        TransformRule.rules(for: selectedTransform ?? draftPromptForRules)
    }

    public var selectedHistory: [TransformHistoryEntry] {
        guard let selectedTransformID else { return [] }
        return history.filter { $0.transformId == selectedTransformID }
    }

    public var normalizedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isDraftValid: Bool {
        normalizedDraftName.isEmpty == false
            && draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && nameError == nil
            && contentError == nil
            && shortcutError == nil
    }

    public var isDraftDirty: Bool {
        guard !isCreatingDraft, let prompt = selectedTransform else { return false }

        let normalizedContent = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRunningLabel = draftRunningLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstructions = draftCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = profiles[prompt.id] ?? .defaultProfile(for: prompt)

        return normalizedDraftName != prompt.name
            || normalizedContent != prompt.content.trimmingCharacters(in: .whitespacesAndNewlines)
            || normalizedRunningLabel != (prompt.runningLabel ?? "")
            || draftShortcut != prompt.shortcut
            || draftEnabledRuleIDs != profile.enabledRuleIDs
            || normalizedInstructions != (profile.customInstructions ?? "")
            || draftUseWritingSamples != profile.useWritingSamples
    }

    public var customTransforms: [Prompt] {
        transforms.filter { !$0.isBuiltIn }
    }

    public var builtInTransforms: [Prompt] {
        transforms.filter(\.isBuiltIn)
    }

    public var shortcutBindings: [UUID: KeyboardShortcut] {
        var bindings: [UUID: KeyboardShortcut] = [:]
        for transform in transforms {
            if let shortcut = transform.shortcut {
                bindings[transform.id] = shortcut
            }
        }
        return bindings
    }

    private var nextCustomSortOrder: Int {
        max(200, (customTransforms.map(\.sortOrder).max() ?? 199) + 1)
    }

    private var draftPromptForRules: Prompt {
        Prompt(
            name: normalizedDraftName.isEmpty ? "Custom" : normalizedDraftName,
            content: draftContent,
            category: .transform
        )
    }

    private func ensureSelection(force: Bool = false) {
        if isCreatingDraft && !force { return }
        if let selectedTransformID,
           transforms.contains(where: { $0.id == selectedTransformID }),
           !force {
            return
        }
        guard let first = transforms.first else { return }
        selectTransform(first)
    }

    private func loadDraft(from prompt: Prompt) {
        draftName = prompt.name
        draftContent = prompt.content
        draftRunningLabel = prompt.runningLabel ?? ""
        draftShortcut = prompt.shortcut
        let profile = profiles[prompt.id] ?? .defaultProfile(for: prompt)
        draftEnabledRuleIDs = profile.enabledRuleIDs
        draftCustomInstructions = profile.customInstructions ?? ""
        draftUseWritingSamples = profile.useWritingSamples
        clearValidation()
    }

    private func validateName() {
        let trimmed = normalizedDraftName
        if trimmed.isEmpty {
            nameError = "Give your Transform a name."
            return
        }
        let editingID = isCreatingDraft ? nil : selectedTransformID
        let duplicate = transforms.contains { other in
            other.id != editingID
                && other.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        nameError = duplicate ? "Another Transform already uses this name." : nil
    }

    private func validateContent() {
        let trimmed = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        contentError = trimmed.isEmpty ? "Give your Transform a prompt to run on the selected text." : nil
    }

    private func validateShortcut(
        reservedHotkeys: [TransformShortcutReservedHotkey],
        collisionChecker: TransformShortcutCollisionChecking
    ) {
        guard let candidate = draftShortcut else {
            shortcutError = nil
            return
        }
        let editingID = isCreatingDraft ? nil : selectedTransformID
        let bindings: [UUID: KeyboardShortcut] = Dictionary(uniqueKeysWithValues:
            transforms.compactMap { prompt in
                guard let shortcut = prompt.shortcut else { return nil }
                return (prompt.id, shortcut)
            }
        )
        shortcutError = collisionChecker.checkForEditor(
            candidate: candidate,
            existing: bindings,
            excludingPromptID: editingID,
            reservedHotkeys: reservedHotkeys
        )?.message
    }

    private func clearValidation() {
        nameError = nil
        contentError = nil
        shortcutError = nil
    }
}
