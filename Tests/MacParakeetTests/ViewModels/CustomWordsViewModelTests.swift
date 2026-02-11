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

    func testDeleteWord() {
        viewModel.newWord = "test"
        viewModel.addWord()
        XCTAssertEqual(viewModel.words.count, 1)

        viewModel.deleteWord(viewModel.words.first!)
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
}
