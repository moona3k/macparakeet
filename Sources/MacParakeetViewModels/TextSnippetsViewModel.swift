import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class TextSnippetsViewModel {
    public var snippets: [TextSnippet] = []
    public var searchText: String = ""
    public var newTrigger: String = ""
    public var newExpansion: String = ""
    public var errorMessage: String?
    public var editingSnippetID: UUID?
    public var editTrigger: String = "" {
        didSet {
            if oldValue != editTrigger {
                editErrorMessage = nil
            }
        }
    }
    public var editExpansion: String = "" {
        didSet {
            if oldValue != editExpansion {
                editErrorMessage = nil
            }
        }
    }
    public var editErrorMessage: String?
    public var pendingDeleteSnippet: TextSnippet?

    private var repo: TextSnippetRepositoryProtocol?

    public init() {}

    public func configure(repo: TextSnippetRepositoryProtocol) {
        self.repo = repo
        loadSnippets()
    }

    public var filteredSnippets: [TextSnippet] {
        guard !searchText.isEmpty else { return snippets }
        return snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(searchText)
                || $0.expansion.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var canSaveEditing: Bool {
        !editTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !processedExpansion(from: editExpansion).isEmpty
    }

    public func loadSnippets() {
        guard let repo else { return }
        do {
            snippets = try repo.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addSnippet() {
        guard let repo else { return }
        let trimmedTrigger = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawExpansion = newExpansion.trimmingCharacters(in: .whitespaces)
        let processedExpansion = rawExpansion.replacingOccurrences(of: "\\n", with: "\n")
        guard !trimmedTrigger.isEmpty, !processedExpansion.isEmpty else { return }

        // Duplicate check (case-insensitive)
        if snippets.contains(where: { $0.trigger.caseInsensitiveCompare(trimmedTrigger) == .orderedSame }) {
            errorMessage = "'\(trimmedTrigger)' already exists"
            return
        }

        let snippet = TextSnippet(trigger: trimmedTrigger, expansion: processedExpansion)

        do {
            try repo.save(snippet)
            Telemetry.send(.snippetAdded)
            newTrigger = ""
            newExpansion = ""
            errorMessage = nil
            loadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleEnabled(_ snippet: TextSnippet) {
        guard let repo else { return }
        var updated = snippet
        updated.isEnabled.toggle()
        updated.updatedAt = Date()
        do {
            try repo.save(updated)
            loadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func beginEditing(_ snippet: TextSnippet) {
        if let editingSnippetID, editingSnippetID != snippet.id {
            editErrorMessage = "Save or cancel the current edit first"
            return
        }
        editingSnippetID = snippet.id
        editTrigger = snippet.trigger
        editExpansion = editableExpansion(from: snippet.expansion)
        editErrorMessage = nil
        errorMessage = nil
    }

    public func cancelEditing() {
        editingSnippetID = nil
        editTrigger = ""
        editExpansion = ""
        editErrorMessage = nil
    }

    public func saveEditing() {
        guard let repo, let editingSnippetID else { return }
        let trimmedTrigger = editTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let processedExpansion = processedExpansion(from: editExpansion)
        guard !trimmedTrigger.isEmpty else {
            editErrorMessage = "Trigger phrase is required"
            return
        }
        guard !processedExpansion.isEmpty else {
            editErrorMessage = "Expansion is required"
            return
        }

        if snippets.contains(where: {
            $0.id != editingSnippetID
                && $0.trigger.caseInsensitiveCompare(trimmedTrigger) == .orderedSame
        }) {
            editErrorMessage = "'\(trimmedTrigger)' already exists"
            return
        }

        do {
            guard var snippet = try repo.fetch(id: editingSnippetID) else {
                cancelEditing()
                loadSnippets()
                return
            }
            snippet.trigger = trimmedTrigger
            snippet.expansion = processedExpansion
            snippet.updatedAt = Date()
            try repo.save(snippet)
            Telemetry.send(.snippetEdited)
            cancelEditing()
            loadSnippets()
        } catch {
            editErrorMessage = error.localizedDescription
        }
    }

    public func confirmDelete() {
        guard let snippet = pendingDeleteSnippet else { return }
        pendingDeleteSnippet = nil
        deleteSnippet(snippet)
    }

    public func deleteSnippet(_ snippet: TextSnippet) {
        guard let repo else { return }
        do {
            _ = try repo.delete(id: snippet.id)
            Telemetry.send(.snippetDeleted)
            if editingSnippetID == snippet.id {
                cancelEditing()
            }
            loadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func processedExpansion(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    private func editableExpansion(from expansion: String) -> String {
        expansion.replacingOccurrences(of: "\n", with: "\\n")
    }
}
