import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class CustomWordsViewModelTests: XCTestCase {
    var viewModel: CustomWordsViewModel!
    var mockRepo: MockCustomWordRepository!

    override func setUp() async throws {
        mockRepo = MockCustomWordRepository()
        viewModel = CustomWordsViewModel()
        viewModel.configure(repo: mockRepo)
    }

    func testInitialState() {
        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.newWord, "")
        XCTAssertEqual(viewModel.newReplacement, "")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAddWord() {
        viewModel.newWord = "kubernetes"
        viewModel.newReplacement = "Kubernetes"
        viewModel.addWord()

        XCTAssertEqual(viewModel.words.count, 1)
        XCTAssertEqual(viewModel.words.first?.word, "kubernetes")
        XCTAssertEqual(viewModel.words.first?.replacement, "Kubernetes")
        XCTAssertEqual(viewModel.newWord, "")
        XCTAssertEqual(viewModel.newReplacement, "")
    }

    func testAddVocabularyAnchor() {
        viewModel.newWord = "MacParakeet"
        viewModel.addWord()

        XCTAssertEqual(viewModel.words.count, 1)
        XCTAssertNil(viewModel.words.first?.replacement)
    }

    func testAddEmptyWordIgnored() {
        viewModel.newWord = "  "
        viewModel.addWord()

        XCTAssertTrue(viewModel.words.isEmpty)
    }

    func testAddDuplicateShowsError() {
        viewModel.newWord = "test"
        viewModel.addWord()
        XCTAssertNil(viewModel.errorMessage)

        viewModel.newWord = "TEST"
        viewModel.addWord()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.words.count, 1)
    }

    func testToggleEnabled() {
        viewModel.newWord = "test"
        viewModel.newReplacement = "Test"
        viewModel.addWord()
        XCTAssertTrue(viewModel.words.first?.isEnabled ?? false)

        viewModel.toggleEnabled(viewModel.words.first!)
        XCTAssertFalse(viewModel.words.first?.isEnabled ?? true)
    }

    func testDeleteWord() async throws {
        viewModel.newWord = "test"
        viewModel.addWord()
        XCTAssertEqual(viewModel.words.count, 1)

        viewModel.requestDelete(try XCTUnwrap(viewModel.words.first))
        let request = try XCTUnwrap(viewModel.pendingDeletion)
        XCTAssertFalse(request.isBulk)
        await viewModel.confirmDelete(request)
        XCTAssertTrue(viewModel.words.isEmpty)
    }

    func testFilteredWords() {
        viewModel.newWord = "kubernetes"
        viewModel.newReplacement = "Kubernetes"
        viewModel.addWord()

        viewModel.newWord = "docker"
        viewModel.newReplacement = "Docker"
        viewModel.addWord()

        viewModel.searchText = "kube"
        XCTAssertEqual(viewModel.filteredWords.count, 1)
        XCTAssertEqual(viewModel.filteredWords.first?.word, "kubernetes")
    }

    func testFilteredWordsEmptySearch() {
        viewModel.newWord = "test"
        viewModel.addWord()

        viewModel.searchText = ""
        XCTAssertEqual(viewModel.filteredWords.count, 1)
    }

    func testSelectionIsTemporaryAndDoesNotChangeEnabledState() {
        let words = loadSelectionFixture()
        viewModel.startSelection()
        XCTAssertTrue(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedWordIDs.isEmpty)

        viewModel.toggleSelection(for: words[1].id)
        XCTAssertEqual(viewModel.selectedWordIDs, [words[1].id])
        XCTAssertFalse(viewModel.areAllFilteredWordsSelected)
        viewModel.toggleSelectAll()
        XCTAssertEqual(viewModel.selectedWordIDs, Set(words.map(\.id)))
        XCTAssertTrue(viewModel.areAllFilteredWordsSelected)
        viewModel.toggleSelectAll()
        XCTAssertTrue(viewModel.selectedWordIDs.isEmpty)

        viewModel.toggleSelection(for: words[0].id)
        viewModel.cancelSelection()
        XCTAssertFalse(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedWordIDs.isEmpty)
        XCTAssertEqual(viewModel.words.map(\.isEnabled), words.map(\.isEnabled))
        XCTAssertEqual(mockRepo.words.map(\.isEnabled), words.map(\.isEnabled))
    }

    func testSearchClearsSelectionAndConfirmationAndSelectAllUsesMatches() {
        let words = loadSelectionFixture()
        viewModel.startSelection()
        viewModel.toggleSelectAll()
        viewModel.requestDeleteSelection()
        XCTAssertNotNil(viewModel.pendingDeletion)

        viewModel.searchText = "Claude"
        XCTAssertTrue(viewModel.selectedWordIDs.isEmpty)
        XCTAssertNil(viewModel.pendingDeletion)
        viewModel.toggleSelectAll()
        XCTAssertEqual(viewModel.selectedWordIDs, [words[1].id])
        viewModel.toggleSelection(for: words[0].id)
        viewModel.toggleSelection(for: UUID())
        XCTAssertEqual(viewModel.selectedWordIDs, [words[1].id], "Hidden or unknown IDs cannot join a selection")

        viewModel.searchText = "no match"
        viewModel.toggleSelectAll()
        viewModel.requestDeleteSelection()
        XCTAssertTrue(viewModel.selectedWordIDs.isEmpty)
        XCTAssertFalse(viewModel.areAllFilteredWordsSelected)
        XCTAssertNil(viewModel.pendingDeletion)
    }

    func testCancelConfirmationPreservesWordsAndSelection() {
        let words = loadSelectionFixture()
        viewModel.startSelection()
        viewModel.toggleSelection(for: words[0].id)
        viewModel.requestDeleteSelection()
        viewModel.cancelDeletion()

        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertEqual(viewModel.selectedWordIDs, [words[0].id])
        XCTAssertEqual(mockRepo.words.count, 3)
    }

    func testConfirmedSnapshotDeletesOnlySelectedWordsAfterAlertDismisses() async throws {
        let words = loadSelectionFixture()
        viewModel.startSelection()
        viewModel.toggleSelection(for: words[1].id)
        viewModel.requestDeleteSelection()
        let request = try XCTUnwrap(viewModel.pendingDeletion)
        XCTAssertTrue(request.isBulk)
        XCTAssertEqual(request.count, 1)

        // SwiftUI clears the alert binding before its asynchronous action runs.
        viewModel.cancelDeletion()
        // A later addition or selection cannot expand the confirmed deletion.
        let added = CustomWord(word: "New import")
        try mockRepo.save(added)
        viewModel.loadWords()
        viewModel.toggleSelectAll()
        await viewModel.confirmDelete(request)

        let survivingIDs: Set<UUID> = [words[0].id, words[2].id, added.id]
        XCTAssertEqual(Set(viewModel.words.map(\.id)), survivingIDs)
        XCTAssertEqual(Set(mockRepo.words.map(\.id)), survivingIDs)
        XCTAssertFalse(viewModel.isSelecting)
        XCTAssertTrue(viewModel.selectedWordIDs.isEmpty)
        XCTAssertFalse(viewModel.isDeleting)
    }

    func testBulkDeleteFailurePreservesSelectionAndCanBeRetried() async throws {
        let words = loadSelectionFixture()
        viewModel.startSelection()
        viewModel.toggleSelectAll()
        viewModel.requestDeleteSelection()
        mockRepo.deleteError = NSError(domain: "CustomWordsTest", code: 1)
        await viewModel.confirmDelete(try XCTUnwrap(viewModel.pendingDeletion))

        XCTAssertEqual(viewModel.words.count, 3)
        XCTAssertEqual(mockRepo.words.count, 3)
        XCTAssertEqual(viewModel.selectedWordIDs, Set(words.map(\.id)))
        XCTAssertTrue(viewModel.isSelecting)
        XCTAssertFalse(viewModel.isDeleting)
        XCTAssertNotNil(viewModel.deletionErrorMessage)

        mockRepo.deleteError = nil
        viewModel.requestDeleteSelection()
        await viewModel.confirmDelete(try XCTUnwrap(viewModel.pendingDeletion))
        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertTrue(mockRepo.words.isEmpty)
        XCTAssertNil(viewModel.deletionErrorMessage)
        XCTAssertFalse(viewModel.isSelecting)
    }

    func testSuccessfulDeletionDoesNotDependOnAnotherDatabaseRead() async throws {
        let words = loadSelectionFixture()
        viewModel.requestDelete(words[0])
        let request = try XCTUnwrap(viewModel.pendingDeletion)
        mockRepo.fetchAllError = NSError(domain: "CustomWordsTest", code: 2)

        await viewModel.confirmDelete(request)

        XCTAssertEqual(viewModel.words.count, 2)
        XCTAssertEqual(mockRepo.words.count, 2)
        XCTAssertNil(viewModel.deletionErrorMessage)
    }

    func testReloadPrunesSelectionOfMissingWords() {
        let words = loadSelectionFixture()
        viewModel.startSelection()
        viewModel.toggleSelectAll()
        mockRepo.words.removeAll { $0.id == words[0].id }
        viewModel.loadWords()
        XCTAssertEqual(viewModel.selectedWordIDs, Set(words.dropFirst().map(\.id)))
    }

    func testPendingDeletionRejectsDuplicateWorkAndPreservesUnselectedWords() async throws {
        let words = loadSelectionFixture()
        let gate = WordDeletionGate()
        mockRepo.beforeBatchDelete = { await gate.suspend() }
        viewModel.startSelection()
        viewModel.toggleSelection(for: words[0].id)
        viewModel.requestDeleteSelection()
        let request = try XCTUnwrap(viewModel.pendingDeletion)
        let task = Task { await viewModel.confirmDelete(request) }
        await gate.waitUntilSuspended()

        XCTAssertTrue(viewModel.isDeleting)
        XCTAssertEqual(viewModel.words.count, 3, "No optimistic removal before the transaction succeeds")
        viewModel.cancelSelection()
        viewModel.toggleSelectAll()
        viewModel.toggleEnabled(words[1])
        await viewModel.confirmDelete(request)
        XCTAssertEqual(viewModel.selectedWordIDs, [words[0].id])
        XCTAssertFalse(mockRepo.words[1].isEnabled)

        await gate.resume()
        await task.value
        XCTAssertFalse(viewModel.isDeleting)
        XCTAssertEqual(Set(viewModel.words.map(\.id)), Set(words.dropFirst().map(\.id)))
    }

    @discardableResult
    private func loadSelectionFixture() -> [CustomWord] {
        let words = [
            CustomWord(word: "Anthropic"),
            CustomWord(word: "Clawed", replacement: "Claude", isEnabled: false),
            CustomWord(word: "Git hub", replacement: "GitHub"),
        ]
        mockRepo.words = words
        viewModel.loadWords()
        return words
    }
}

private actor WordDeletionGate {
    private var deletion: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            deletion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilSuspended() async {
        if deletion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        deletion?.resume()
        deletion = nil
    }
}
