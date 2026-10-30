import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class VocabularyBackupViewModelTests: XCTestCase {
    private struct SaveFailure: LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    private func makeConfiguredViewModel(
        customWordRepo: CustomWordRepositoryProtocol? = nil
    ) throws -> VocabularyBackupViewModel {
        let viewModel = VocabularyBackupViewModel()
        let database = try DatabaseManager()
        let wordRepo: CustomWordRepositoryProtocol = customWordRepo ?? CustomWordRepository(dbQueue: database.dbQueue)
        viewModel.configure(
            service: VocabularyImportExportService(
                customWordRepo: wordRepo,
                snippetRepo: TextSnippetRepository(dbQueue: database.dbQueue),
                dbQueue: database.dbQueue
            ),
            onImportFinished: {}
        )
        return viewModel
    }

    func testBackupWaitsForConfigurationAndAllowsEmptyExport() async throws {
        let viewModel = VocabularyBackupViewModel()
        XCTAssertFalse(viewModel.canStartOperation)

        let configured = try makeConfiguredViewModel()
        XCTAssertTrue(configured.canStartOperation)

        var savedPayload: VocabularyBackupViewModel.ExportPayload?
        await configured.exportVocabulary { payload in
            savedPayload = payload
            return "Backup.json"
        }

        let export = try XCTUnwrap(savedPayload)
        XCTAssertEqual(export.wordsCount, 0)
        XCTAssertEqual(export.snippetsCount, 0)
        XCTAssertFalse(export.data.isEmpty)
        XCTAssertTrue(configured.canStartOperation)
    }

    func testExportStaysBusyUntilSaveFinishesThenReportsSuccess() async throws {
        let viewModel = try makeConfiguredViewModel()

        var statusWhileSaving: VocabularyBackupViewModel.Status?
        var couldStartWhileSaving: Bool?
        await viewModel.exportVocabulary { _ in
            statusWhileSaving = viewModel.status
            couldStartWhileSaving = viewModel.canStartOperation
            return "Backup.json"
        }

        XCTAssertEqual(statusWhileSaving, .exporting)
        XCTAssertEqual(couldStartWhileSaving, false)
        XCTAssertEqual(
            viewModel.status,
            .exported(wordsCount: 0, snippetsCount: 0, filename: "Backup.json")
        )
        XCTAssertTrue(viewModel.canStartOperation)
    }

    func testCancelledSaveReleasesBusyStateAndAllowsAnotherExport() async throws {
        let viewModel = try makeConfiguredViewModel()

        await viewModel.exportVocabulary { _ in nil }
        XCTAssertEqual(viewModel.status, .idle)
        XCTAssertTrue(viewModel.canStartOperation)

        var secondSaveRan = false
        await viewModel.exportVocabulary { _ in
            secondSaveRan = true
            return "Backup.json"
        }
        XCTAssertTrue(secondSaveRan)
    }

    func testFailedSaveReportsErrorAndReleasesBusyState() async throws {
        let viewModel = try makeConfiguredViewModel()

        await viewModel.exportVocabulary { _ in throw SaveFailure() }

        XCTAssertEqual(viewModel.status, .failed("Couldn't write the file: disk full"))
        XCTAssertTrue(viewModel.canStartOperation)
    }

    func testFailedBackupCreationNeverReachesSaveAndReleasesBusyState() async throws {
        let customWordRepo = MockCustomWordRepository()
        customWordRepo.fetchAllError = SaveFailure()
        let viewModel = try makeConfiguredViewModel(customWordRepo: customWordRepo)

        var saveRan = false
        await viewModel.exportVocabulary { _ in
            saveRan = true
            return "Backup.json"
        }

        XCTAssertFalse(saveRan)
        XCTAssertEqual(viewModel.status, .failed("Couldn't create the backup: disk full"))
        XCTAssertTrue(viewModel.canStartOperation)
    }

    func testOperationsAreIgnoredWhileExportAwaitsSave() async throws {
        let viewModel = try makeConfiguredViewModel()

        var nestedExportRan = false
        var statusesDuringSave: [VocabularyBackupViewModel.Status] = []
        var applyResult: Bool?
        await viewModel.exportVocabulary { _ in
            await viewModel.exportVocabulary { _ in
                nestedExportRan = true
                return "Nested.json"
            }
            statusesDuringSave.append(viewModel.status)

            await viewModel.loadPreview(from: URL(fileURLWithPath: "/nonexistent/backup.json"))
            statusesDuringSave.append(viewModel.status)

            viewModel.dismissStatus()
            statusesDuringSave.append(viewModel.status)

            viewModel.cancelImport()
            statusesDuringSave.append(viewModel.status)

            applyResult = await viewModel.applyImport()
            statusesDuringSave.append(viewModel.status)
            return "Backup.json"
        }

        XCTAssertFalse(nestedExportRan)
        XCTAssertEqual(statusesDuringSave, Array(repeating: VocabularyBackupViewModel.Status.exporting, count: 5))
        XCTAssertEqual(applyResult, false)
        XCTAssertEqual(
            viewModel.status,
            .exported(wordsCount: 0, snippetsCount: 0, filename: "Backup.json")
        )
    }

    func testBackupControlsWaitForCurrentOperationAndRecoverAfterFailure() throws {
        let viewModel = try makeConfiguredViewModel()
        viewModel.status = .exporting
        XCTAssertFalse(viewModel.canStartOperation)
        viewModel.status = .importing
        XCTAssertFalse(viewModel.canStartOperation)
        viewModel.status = .failed("Couldn't read the vocabulary")
        XCTAssertTrue(viewModel.canStartOperation)
    }
}
