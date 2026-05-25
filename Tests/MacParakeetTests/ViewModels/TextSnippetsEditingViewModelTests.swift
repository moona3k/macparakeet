import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TextSnippetsEditingViewModelTests: XCTestCase {
    var viewModel: TextSnippetsViewModel!
    var mockRepo: MockTextSnippetRepository!

    override func setUp() async throws {
        mockRepo = MockTextSnippetRepository()
        viewModel = TextSnippetsViewModel()
        viewModel.configure(repo: mockRepo)
    }

    func testBeginEditingPopulatesFields() throws {
        let snippet = TextSnippet(trigger: "my address", expansion: "123 Main St\nCity")
        try mockRepo.save(snippet)
        viewModel.loadSnippets()

        viewModel.beginEditing(snippet)

        XCTAssertEqual(viewModel.editingSnippetID, snippet.id)
        XCTAssertEqual(viewModel.editTrigger, "my address")
        XCTAssertEqual(viewModel.editExpansion, "123 Main St\\nCity")
        XCTAssertNil(viewModel.editErrorMessage)
    }

    func testBeginEditingSecondSnippetPreservesActiveDraft() throws {
        let first = TextSnippet(trigger: "my sig", expansion: "Original")
        let second = TextSnippet(trigger: "my address", expansion: "123 Main")
        try mockRepo.save(first)
        try mockRepo.save(second)
        viewModel.loadSnippets()

        viewModel.beginEditing(first)
        viewModel.editTrigger = "draft trigger"
        viewModel.editExpansion = "Draft expansion"
        viewModel.beginEditing(second)

        XCTAssertEqual(viewModel.editingSnippetID, first.id)
        XCTAssertEqual(viewModel.editTrigger, "draft trigger")
        XCTAssertEqual(viewModel.editExpansion, "Draft expansion")
        XCTAssertEqual(viewModel.editErrorMessage, "Save or cancel the current edit first")
    }

    func testSaveEditingUpdatesSnippetAndPreservesMetadata() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snippet = TextSnippet(
            trigger: "my sig",
            expansion: "Original",
            isEnabled: false,
            useCount: 7,
            action: .returnKey,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try mockRepo.save(snippet)
        viewModel.loadSnippets()

        viewModel.beginEditing(snippet)
        viewModel.editTrigger = "my signature"
        viewModel.editExpansion = "Best regards\\nDaniel"
        viewModel.saveEditing()

        let updated = try XCTUnwrap(mockRepo.fetch(id: snippet.id))
        XCTAssertEqual(updated.id, snippet.id)
        XCTAssertEqual(updated.trigger, "my signature")
        XCTAssertEqual(updated.expansion, "Best regards\nDaniel")
        XCTAssertEqual(updated.isEnabled, false)
        XCTAssertEqual(updated.useCount, 7)
        XCTAssertEqual(updated.action, .returnKey)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertGreaterThan(updated.updatedAt, createdAt)
        XCTAssertNil(viewModel.editingSnippetID)
        XCTAssertEqual(viewModel.editTrigger, "")
        XCTAssertEqual(viewModel.editExpansion, "")
    }

    func testSaveEditingAllowsUnchangedTrigger() throws {
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        try mockRepo.save(snippet)
        viewModel.loadSnippets()

        viewModel.beginEditing(snippet)
        viewModel.editTrigger = "MY SIG"
        viewModel.editExpansion = "Updated"
        viewModel.saveEditing()

        let updated = try XCTUnwrap(mockRepo.fetch(id: snippet.id))
        XCTAssertEqual(updated.trigger, "MY SIG")
        XCTAssertEqual(updated.expansion, "Updated")
        XCTAssertNil(viewModel.editErrorMessage)
    }

    func testSaveEditingRejectsDuplicateTrigger() throws {
        let first = TextSnippet(trigger: "my sig", expansion: "Original")
        let second = TextSnippet(trigger: "my address", expansion: "123 Main")
        try mockRepo.save(first)
        try mockRepo.save(second)
        viewModel.loadSnippets()

        viewModel.beginEditing(first)
        viewModel.editTrigger = "MY ADDRESS"
        viewModel.editExpansion = "Updated"
        viewModel.saveEditing()

        let unchanged = try XCTUnwrap(mockRepo.fetch(id: first.id))
        XCTAssertEqual(unchanged.trigger, "my sig")
        XCTAssertEqual(unchanged.expansion, "Original")
        XCTAssertEqual(viewModel.editingSnippetID, first.id)
        XCTAssertEqual(viewModel.editErrorMessage, "'MY ADDRESS' already exists")
    }

    func testSaveEditingRejectsEmptyFields() throws {
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        try mockRepo.save(snippet)
        viewModel.loadSnippets()

        viewModel.beginEditing(snippet)
        viewModel.editTrigger = " "
        viewModel.saveEditing()
        XCTAssertEqual(viewModel.editErrorMessage, "Trigger phrase is required")

        viewModel.editTrigger = "my sig"
        viewModel.editExpansion = "   "
        viewModel.saveEditing()
        XCTAssertEqual(viewModel.editErrorMessage, "Expansion is required")
    }

    func testSaveEditingClearsStateWhenSnippetWasDeletedExternally() throws {
        let deleted = TextSnippet(trigger: "my sig", expansion: "Original")
        let remaining = TextSnippet(trigger: "my address", expansion: "123 Main")
        try mockRepo.save(deleted)
        try mockRepo.save(remaining)
        viewModel.loadSnippets()

        viewModel.beginEditing(deleted)
        viewModel.editTrigger = "updated sig"
        _ = try mockRepo.delete(id: deleted.id)
        viewModel.saveEditing()

        XCTAssertNil(viewModel.editingSnippetID)
        XCTAssertEqual(viewModel.editTrigger, "")
        XCTAssertEqual(viewModel.editExpansion, "")
        XCTAssertNil(viewModel.editErrorMessage)
        XCTAssertEqual(viewModel.snippets.map(\.id), [remaining.id])

        viewModel.beginEditing(remaining)
        XCTAssertEqual(viewModel.editingSnippetID, remaining.id)
        XCTAssertNil(viewModel.editErrorMessage)
    }

    func testCancelEditingClearsState() {
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        viewModel.beginEditing(snippet)
        viewModel.editErrorMessage = "Error"

        viewModel.cancelEditing()

        XCTAssertNil(viewModel.editingSnippetID)
        XCTAssertEqual(viewModel.editTrigger, "")
        XCTAssertEqual(viewModel.editExpansion, "")
        XCTAssertNil(viewModel.editErrorMessage)
    }

    func testEditingFieldChangesClearValidationError() {
        let snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        viewModel.beginEditing(snippet)

        viewModel.editErrorMessage = "Trigger phrase is required"
        viewModel.editTrigger = "my signature"
        XCTAssertNil(viewModel.editErrorMessage)

        viewModel.editErrorMessage = "Expansion is required"
        viewModel.editExpansion = "Updated"
        XCTAssertNil(viewModel.editErrorMessage)
    }
}
