import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class VocabularyBackupViewModelTests: XCTestCase {
    func testBackupWaitsForConfigurationAndAllowsEmptyExport() async throws {
        let viewModel = VocabularyBackupViewModel()
        XCTAssertFalse(viewModel.canStartOperation)

        let database = try DatabaseManager()
        let service = VocabularyImportExportService(
            customWordRepo: CustomWordRepository(dbQueue: database.dbQueue),
            snippetRepo: TextSnippetRepository(dbQueue: database.dbQueue),
            dbQueue: database.dbQueue
        )
        viewModel.configure(service: service, onImportFinished: {})
        XCTAssertTrue(viewModel.canStartOperation)

        let payload = await viewModel.makeExportPayload()
        let export = try XCTUnwrap(payload)
        XCTAssertEqual(export.wordsCount, 0)
        XCTAssertEqual(export.snippetsCount, 0)
        XCTAssertFalse(export.data.isEmpty)
        XCTAssertTrue(viewModel.canStartOperation)
    }

    func testBackupControlsWaitForCurrentOperationAndRecoverAfterFailure() throws {
        let viewModel = VocabularyBackupViewModel()
        let database = try DatabaseManager()
        viewModel.configure(
            service: VocabularyImportExportService(
                customWordRepo: CustomWordRepository(dbQueue: database.dbQueue),
                snippetRepo: TextSnippetRepository(dbQueue: database.dbQueue),
                dbQueue: database.dbQueue
            ),
            onImportFinished: {}
        )
        viewModel.status = .exporting
        XCTAssertFalse(viewModel.canStartOperation)
        viewModel.status = .importing
        XCTAssertFalse(viewModel.canStartOperation)
        viewModel.status = .failed("Couldn't read the vocabulary")
        XCTAssertTrue(viewModel.canStartOperation)
    }
}
