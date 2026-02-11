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
        let trimmedExpansion = newExpansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedExpansion.isEmpty else { return }

        // Duplicate check (case-insensitive)
        if snippets.contains(where: { $0.trigger.caseInsensitiveCompare(trimmedTrigger) == .orderedSame }) {
            errorMessage = "'\(trimmedTrigger)' already exists"
            return
        }

        let snippet = TextSnippet(trigger: trimmedTrigger, expansion: trimmedExpansion)

        do {
            try repo.save(snippet)
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

    public func deleteSnippet(_ snippet: TextSnippet) {
        guard let repo else { return }
        do {
            _ = try repo.delete(id: snippet.id)
            loadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
