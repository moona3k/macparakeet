import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class VocabularyBackupViewModel {
    public struct ExportPayload: Sendable, Equatable {
        public let data: Data
        public let wordsCount: Int
        public let snippetsCount: Int

        public init(data: Data, wordsCount: Int, snippetsCount: Int) {
            self.data = data
            self.wordsCount = wordsCount
            self.snippetsCount = snippetsCount
        }
    }

    public enum Status: Equatable {
        case idle
        case exporting
        case exported(wordsCount: Int, snippetsCount: Int, filename: String)
        case importing
        case imported(VocabularyImportExportService.ImportResult)
        case failed(String)
    }

    public var status: Status = .idle
    public var pendingImport: VocabularyImportExportService.ImportPreview?
    public var conflictPolicy: VocabularyImportExportService.ConflictPolicy = .skip

    private var service: VocabularyImportExportService?
    private var onImportFinished: (() -> Void)?

    public init() {}

    public func configure(
        service: VocabularyImportExportService,
        onImportFinished: @escaping () -> Void
    ) {
        self.service = service
        self.onImportFinished = onImportFinished
    }

    public var isPresentingImportSheet: Bool { pendingImport != nil }

    public var canStartOperation: Bool {
        service != nil && !isBusy
    }

    private var isBusy: Bool {
        status == .exporting || status == .importing
    }

    public func suggestedFilename() -> String {
        service?.suggestedFilename() ?? "MacParakeet-Vocabulary.json"
    }

    /// Runs one export end to end and stays busy until it finishes. `save`
    /// presents the save panel and writes the payload, returning the saved file
    /// name, or nil if the user cancels. The status settles to `.exported`,
    /// `.idle` (cancelled), or `.failed`, so every path releases the busy state.
    public func exportVocabulary(
        save: @MainActor (ExportPayload) async throws -> String?
    ) async {
        guard !isBusy else { return }
        guard let service else {
            failMissingService()
            return
        }
        status = .exporting
        let payload: ExportPayload
        do {
            let export = try await Task.detached(priority: .userInitiated) {
                try service.exportBundleData()
            }.value
            payload = ExportPayload(
                data: export.data,
                wordsCount: export.bundle.customWords.count,
                snippetsCount: export.bundle.textSnippets.count
            )
        } catch {
            status = .failed("Couldn't create the backup: \(error.localizedDescription)")
            return
        }
        do {
            if let filename = try await save(payload) {
                status = .exported(
                    wordsCount: payload.wordsCount,
                    snippetsCount: payload.snippetsCount,
                    filename: filename
                )
            } else {
                status = .idle
            }
        } catch {
            status = .failed("Couldn't write the file: \(error.localizedDescription)")
        }
    }

    /// Loads + decodes a chosen file. On success, populates `pendingImport` so
    /// the UI shows the preview sheet. On failure, surfaces an error message.
    public func loadPreview(from url: URL) async {
        guard !isBusy else { return }
        guard let service else {
            failMissingService()
            return
        }
        status = .importing
        do {
            let preview = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try service.decodePreview(from: data)
            }.value
            pendingImport = preview
            conflictPolicy = .skip
            status = .idle
        } catch let error as VocabularyImportExportService.ImportError {
            status = .failed(error.errorDescription ?? "Couldn't read the file.")
        } catch {
            status = .failed("Couldn't read the file: \(error.localizedDescription)")
        }
    }

    public func cancelImport() {
        pendingImport = nil
        if !isBusy { status = .idle }
    }

    @discardableResult
    public func applyImport() async -> Bool {
        guard !isBusy else { return false }
        guard let service else {
            failMissingService()
            return false
        }
        guard let preview = pendingImport else {
            return false
        }
        status = .importing
        do {
            let policy = conflictPolicy
            let result = try await Task.detached(priority: .userInitiated) {
                try service.apply(preview: preview, policy: policy)
            }.value
            pendingImport = nil
            status = .imported(result)
            onImportFinished?()
            return true
        } catch let error as VocabularyImportExportService.ImportError {
            if error == .stalePreview {
                pendingImport = nil
            }
            status = .failed(error.errorDescription ?? "Couldn't apply the import.")
            return false
        } catch {
            status = .failed("Couldn't apply the import: \(error.localizedDescription)")
            return false
        }
    }

    public func dismissStatus() {
        if !isBusy { status = .idle }
    }

    private func failMissingService() {
        #if DEBUG
        assertionFailure("Missing service in VocabularyBackupViewModel")
        #endif
        status = .failed("Vocabulary backup isn't ready yet. Try again in a moment.")
    }
}
