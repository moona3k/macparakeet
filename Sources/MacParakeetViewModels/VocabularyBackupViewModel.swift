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

    public func suggestedFilename() -> String {
        service?.suggestedFilename() ?? "MacParakeet-Vocabulary.json"
    }

    /// Builds export bytes. Caller wires the returned payload to NSSavePanel.
    public func makeExportPayload() async -> ExportPayload? {
        guard let service else {
            failMissingService()
            return nil
        }
        status = .exporting
        do {
            let export = try await Task.detached(priority: .userInitiated) {
                try service.exportBundleData()
            }.value
            status = .idle
            return ExportPayload(
                data: export.data,
                wordsCount: export.bundle.customWords.count,
                snippetsCount: export.bundle.textSnippets.count
            )
        } catch {
            status = .failed("Couldn't create the backup: \(error.localizedDescription)")
            return nil
        }
    }

    public func confirmExportSucceeded(filename: String, wordsCount: Int, snippetsCount: Int) {
        status = .exported(
            wordsCount: wordsCount,
            snippetsCount: snippetsCount,
            filename: filename
        )
    }

    /// Loads + decodes a chosen file. On success, populates `pendingImport` so
    /// the UI shows the preview sheet. On failure, surfaces an error message.
    public func loadPreview(from url: URL) async {
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
        status = .idle
    }

    @discardableResult
    public func applyImport() async -> Bool {
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
        } catch {
            status = .failed("Couldn't apply the import: \(error.localizedDescription)")
            return false
        }
    }

    public func dismissStatus() {
        status = .idle
    }

    private func failMissingService() {
        #if DEBUG
        assertionFailure("Missing service in VocabularyBackupViewModel")
        #endif
        status = .failed("Vocabulary backup isn't ready yet. Try again in a moment.")
    }
}
