import Foundation
import MacParakeetCore

enum MeetingFinalizationReconciler {
    static let staleProcessingErrorMessage =
        "MacParakeet quit before meeting transcription finished. Your audio is saved."

    @discardableResult
    static func reconcileStaleProcessingRows(
        repository: TranscriptionRepositoryProtocol,
        excludingTranscriptionIDs protectedIDs: Set<UUID> = []
    ) async throws -> [UUID] {
        try await Task.detached(priority: .utility) {
            let staleRows = try repository.fetchMeetings(withStatus: .processing)
                .filter { !protectedIDs.contains($0.id) }
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
