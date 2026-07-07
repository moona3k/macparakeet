import Foundation
import MacParakeetCore

enum MeetingFinalizationReconciler {
    static let staleProcessingErrorMessage =
        "MacParakeet quit before meeting transcription finished. Your audio is saved."

    @discardableResult
    static func reconcileStaleProcessingRows(
        repository: TranscriptionRepositoryProtocol
    ) async throws -> [UUID] {
        try await Task.detached(priority: .utility) {
            let staleRows = try repository.fetchAll(limit: nil).filter {
                $0.sourceType == .meeting && $0.status == .processing
            }
            for row in staleRows {
                try repository.updateStatus(
                    id: row.id,
                    status: .error,
                    errorMessage: staleProcessingErrorMessage
                )
            }
            return staleRows.map(\.id)
        }.value
    }
}
