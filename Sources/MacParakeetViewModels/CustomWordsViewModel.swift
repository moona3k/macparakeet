import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class CustomWordsViewModel {
    public var words: [CustomWord] = []
    public var searchText: String = ""
    public var newWord: String = ""
    public var newReplacement: String = ""
    public var errorMessage: String?
    public var pendingDeleteWord: CustomWord?

    private var repo: CustomWordRepositoryProtocol?

    public init() {}

    public func configure(repo: CustomWordRepositoryProtocol) {
        self.repo = repo
        loadWords()
    }

    public var filteredWords: [CustomWord] {
        guard !searchText.isEmpty else { return words }
        return words.filter {
            $0.word.localizedCaseInsensitiveContains(searchText)
                || ($0.replacement?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    public func loadWords() {
        guard let repo else { return }
        do {
            words = try repo.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addWord() {
        guard let repo else { return }
        let trimmedWord = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return }

        // Duplicate check (case-insensitive)
        if words.contains(where: { $0.word.caseInsensitiveCompare(trimmedWord) == .orderedSame }) {
            errorMessage = "'\(trimmedWord)' already exists"
            return
        }

        let trimmedReplacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = CustomWord(
            word: trimmedWord,
            replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement
        )

        do {
            try repo.save(word)
            newWord = ""
            newReplacement = ""
            errorMessage = nil
            loadWords()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleEnabled(_ word: CustomWord) {
        guard let repo else { return }
        var updated = word
        updated.isEnabled.toggle()
        updated.updatedAt = Date()
        do {
            try repo.save(updated)
            loadWords()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func confirmDelete() {
        guard let word = pendingDeleteWord else { return }
        pendingDeleteWord = nil
        deleteWord(word)
    }

    public func deleteWord(_ word: CustomWord) {
        guard let repo else { return }
        do {
            _ = try repo.delete(id: word.id)
            loadWords()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
