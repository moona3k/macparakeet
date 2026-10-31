import Foundation
import MacParakeetCore

/// The immutable words the user saw when opening the deletion confirmation.
public struct WordDeletionRequest: Sendable {
    public let words: [CustomWord]
    public let isBulk: Bool

    public var count: Int { words.count }
}

@MainActor
@Observable
public final class CustomWordsViewModel {
    public enum LoadState: Equatable {
        case notLoaded
        case loaded
        case failed(String)
    }

    public private(set) var loadState: LoadState = .notLoaded
    public var words: [CustomWord] = []
    public var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            selectedWordIDs.removeAll()
            pendingDeletion = nil
        }
    }
    public var newWord: String = ""
    public var newReplacement: String = ""
    public var errorMessage: String?
    public private(set) var isSelecting = false
    public private(set) var selectedWordIDs: Set<UUID> = []
    public private(set) var pendingDeletion: WordDeletionRequest?
    public private(set) var isDeleting = false
    public private(set) var deletionErrorMessage: String?

    private var repo: CustomWordRepositoryProtocol?

    public init() {}

    public func configure(repo: CustomWordRepositoryProtocol) {
        self.repo = repo
        cancelSelection()
        loadWords()
    }

    public func prepareForPresentation() {
        guard !isDeleting else { return }
        cancelSelection()
        searchText = ""
        loadWords()
    }

    public var canEditWords: Bool { loadState == .loaded && !isDeleting }

    public var isSearching: Bool { !searchQuery.isEmpty }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var filteredWords: [CustomWord] {
        let query = searchQuery
        guard !query.isEmpty else { return words }
        return words.filter {
            $0.word.localizedCaseInsensitiveContains(query)
                || ($0.replacement?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public func loadWords() {
        guard let repo else { return }
        do {
            words = try repo.fetchAll()
            loadState = .loaded
            selectedWordIDs.formIntersection(filteredWords.map(\.id))
            errorMessage = nil
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    public func addWord() {
        guard let repo, canEditWords else { return }
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
            Telemetry.send(.customWordAdded)
            newWord = ""
            newReplacement = ""
            errorMessage = nil
            loadWords()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleEnabled(_ word: CustomWord) {
        guard let repo, canEditWords else { return }
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

    public var areAllFilteredWordsSelected: Bool {
        let visibleIDs = Set(filteredWords.map(\.id))
        return !visibleIDs.isEmpty && selectedWordIDs == visibleIDs
    }

    public func startSelection() {
        guard canEditWords, !filteredWords.isEmpty else { return }
        selectedWordIDs.removeAll()
        pendingDeletion = nil
        deletionErrorMessage = nil
        isSelecting = true
    }

    public func cancelSelection() {
        guard !isDeleting else { return }
        isSelecting = false
        selectedWordIDs.removeAll()
        pendingDeletion = nil
        deletionErrorMessage = nil
    }

    public func toggleSelection(for id: UUID) {
        guard isSelecting, canEditWords, filteredWords.contains(where: { $0.id == id }) else { return }
        if !selectedWordIDs.insert(id).inserted {
            selectedWordIDs.remove(id)
        }
    }

    public func toggleSelectAll() {
        guard isSelecting, canEditWords else { return }
        if areAllFilteredWordsSelected {
            selectedWordIDs.removeAll()
        } else {
            selectedWordIDs = Set(filteredWords.map(\.id))
        }
    }

    public func requestDelete(_ word: CustomWord) {
        guard canEditWords, let current = words.first(where: { $0.id == word.id }) else { return }
        pendingDeletion = WordDeletionRequest(words: [current], isBulk: false)
    }

    public func requestDeleteSelection() {
        guard isSelecting, canEditWords else { return }
        let selectedWords = filteredWords.filter { selectedWordIDs.contains($0.id) }
        guard !selectedWords.isEmpty else { return }
        pendingDeletion = WordDeletionRequest(words: selectedWords, isBulk: true)
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    public func confirmDelete(_ request: WordDeletionRequest) async {
        guard let repo, canEditWords, !request.words.isEmpty else { return }
        let ids = Set(request.words.map(\.id))
        isDeleting = true
        pendingDeletion = nil
        deletionErrorMessage = nil
        defer { isDeleting = false }

        do {
            let deletedCount = try await repo.delete(ids: ids)
            // The transaction succeeded. Do not turn a subsequent read failure
            // into a deletion failure or remove words outside the confirmed IDs.
            words.removeAll { ids.contains($0.id) }
            selectedWordIDs.removeAll()
            isSelecting = false
            if deletedCount > 0 {
                Telemetry.send(.customWordDeleted)
            }
        } catch {
            deletionErrorMessage = "Couldn't delete the selected words. \(error.localizedDescription)"
        }
    }
}
