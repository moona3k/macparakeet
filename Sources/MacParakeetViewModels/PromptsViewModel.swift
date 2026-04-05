import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class PromptsViewModel {
    public var prompts: [Prompt] = []
    public var newName: String = "" {
        didSet { resetValidationError() }
    }
    public var newContent: String = "" {
        didSet { resetValidationError() }
    }
    public var errorMessage: String?
    public var pendingDeletePrompt: Prompt?
    public var editingPrompt: Prompt?

    private var repo: PromptRepositoryProtocol?

    public init() {}

    public func configure(repo: PromptRepositoryProtocol) {
        self.repo = repo
        loadPrompts()
    }

    public func loadPrompts() {
        guard let repo else { return }
        do {
            prompts = try repo.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addPrompt() {
        guard let repo else { return }
        let trimmedName = normalized(newName)
        let trimmedContent = normalized(newContent)
        guard !trimmedName.isEmpty, !trimmedContent.isEmpty else {
            errorMessage = "Prompt name and content are required."
            return
        }
        guard isUniqueName(trimmedName) else {
            errorMessage = "'\(trimmedName)' already exists"
            return
        }

        let nextSortOrder = (prompts.map(\.sortOrder).max() ?? 0) + 1
        let prompt = Prompt(
            name: trimmedName,
            content: trimmedContent,
            category: .summary,
            isBuiltIn: false,
            isVisible: true,
            sortOrder: nextSortOrder
        )

        do {
            try repo.save(prompt)
            newName = ""
            newContent = ""
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updatePrompt(_ prompt: Prompt, name: String, content: String) {
        guard let repo else { return }
        let trimmedName = normalized(name)
        let trimmedContent = normalized(content)
        guard !trimmedName.isEmpty, !trimmedContent.isEmpty else {
            errorMessage = "Prompt name and content are required."
            return
        }
        guard isUniqueName(trimmedName, excluding: prompt.id) else {
            errorMessage = "'\(trimmedName)' already exists"
            return
        }

        var updated = prompt
        updated.name = trimmedName
        updated.content = trimmedContent
        updated.updatedAt = Date()

        do {
            try repo.save(updated)
            editingPrompt = nil
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleVisibility(_ prompt: Prompt) {
        guard let repo else { return }
        if prompt.name == Prompt.defaultPrompt.name && prompt.isBuiltIn && prompt.isVisible {
            return
        }
        do {
            try repo.toggleVisibility(id: prompt.id)
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func confirmDelete() {
        guard let prompt = pendingDeletePrompt else { return }
        pendingDeletePrompt = nil
        deletePrompt(prompt)
    }

    public func deletePrompt(_ prompt: Prompt) {
        guard let repo, !prompt.isBuiltIn else { return }
        do {
            _ = try repo.delete(id: prompt.id)
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreDefaults() {
        guard let repo else { return }
        do {
            try repo.restoreDefaults()
            errorMessage = nil
            loadPrompts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isUniqueName(_ name: String, excluding promptID: UUID? = nil) -> Bool {
        !prompts.contains {
            $0.id != promptID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetValidationError() {
        errorMessage = nil
    }
}
