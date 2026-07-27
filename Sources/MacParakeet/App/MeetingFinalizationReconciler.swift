import Foundation
import MacParakeetCore

enum MeetingFinalizationReconciler {
    static let staleProcessingErrorMessage =
        "MacParakeet quit before meeting transcription finished. Your audio is saved."

    @discardableResult
    static func reconcileStaleProcessingRows(
        repository: TranscriptionRepositoryProtocol,
        excludingTranscriptionIDs protectedIDs: Set<UUID> = [],
        lockFileStore: MeetingRecordingLockFileStore = MeetingRecordingLockFileStore()
    ) async throws -> [UUID] {
        try await Task.detached(priority: .utility) {
            let processingRows = try repository.fetchMeetings(withStatus: .processing)
                .filter { !protectedIDs.contains($0.id) }
            var reconciledIDs: [UUID] = []

            for row in processingRows {
                if let folderPath = row.meetingArtifactFolderPath,
                   !folderPath.isEmpty,
                   try lockFileStore.hasLiveOwner(
                       folderURL: URL(fileURLWithPath: folderPath, isDirectory: true)
                   ) {
                    continue
                }

                let didReconcile = try repository.transitionStatus(
                    id: row.id,
                    from: .processing,
                    to: .error,
                    errorMessage: staleProcessingErrorMessage
                )
                if didReconcile {
                    reconciledIDs.append(row.id)
                }
            }
            return reconciledIDs
        }.value
    }
}
