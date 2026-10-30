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
            return "Backup.json"
        }

        XCTAssertFalse(nestedExportRan)
        XCTAssertEqual(statusesDuringSave, Array(repeating: VocabularyBackupViewModel.Status.exporting, count: 4))
        XCTAssertEqual(
            viewModel.status,
            .exported(wordsCount: 0, snippetsCount: 0, filename: "Backup.json")
        )
    }

    func testApplyImportIsIgnoredWhileExportAwaitsSaveAndKeepsPendingPreview() async throws {
        let sourceDatabase = try DatabaseManager()
        let sourceWordRepo = CustomWordRepository(dbQueue: sourceDatabase.dbQueue)
        try sourceWordRepo.save(CustomWord(word: "kubernetes", replacement: "Kubernetes"))
        let backupData = try VocabularyImportExportService(
            customWordRepo: sourceWordRepo,
            snippetRepo: TextSnippetRepository(dbQueue: sourceDatabase.dbQueue),
            dbQueue: sourceDatabase.dbQueue
        ).exportData()
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-backup-\(UUID().uuidString).json")
        try backupData.write(to: backupURL)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let targetDatabase = try DatabaseManager()
        let targetWordRepo = CustomWordRepository(dbQueue: targetDatabase.dbQueue)
        var importFinishedCount = 0
        let viewModel = VocabularyBackupViewModel()
        viewModel.configure(
            service: VocabularyImportExportService(
                customWordRepo: targetWordRepo,
                snippetRepo: TextSnippetRepository(dbQueue: targetDatabase.dbQueue),
                dbQueue: targetDatabase.dbQueue
            ),
            onImportFinished: { importFinishedCount += 1 }
        )

        await viewModel.loadPreview(from: backupURL)
        let preview = try XCTUnwrap(viewModel.pendingImport)
        XCTAssertEqual(preview.wordsTotal, 1)

        var applyResult: Bool?
        var previewDuringSave: VocabularyImportExportService.ImportPreview?
        await viewModel.exportVocabulary { _ in
            applyResult = await viewModel.applyImport()
            previewDuringSave = viewModel.pendingImport
            return "Backup.json"
        }

        XCTAssertEqual(applyResult, false)
        XCTAssertEqual(previewDuringSave, preview)
        XCTAssertEqual(viewModel.pendingImport, preview)
        XCTAssertEqual(importFinishedCount, 0)
        XCTAssertTrue(try targetWordRepo.fetchAll().isEmpty)
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
