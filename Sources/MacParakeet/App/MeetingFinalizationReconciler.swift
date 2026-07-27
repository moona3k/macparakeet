import Foundation
import MacParakeetCore

/// The narrow persistence capability startup reconciliation needs.
///
/// `transitionStatus` must compare and update within one database transaction.
/// A read followed by an unconditional write can regress a row that another
/// app process completed between those operations.
protocol MeetingFinalizationStatusRepository: Sendable {
    func fetchMeetings(
        withStatus status: Transcription.TranscriptionStatus
    ) throws -> [Transcription]

    @discardableResult
    func transitionStatus(
        id: UUID,
        from expectedStatus: Transcription.TranscriptionStatus,
        to status: Transcription.TranscriptionStatus,
        errorMessage: String?
    ) throws -> Bool
}

extension TranscriptionRepository: MeetingFinalizationStatusRepository {}

/// Answers ownership for one canonical meeting-artifact folder.
protocol MeetingFinalizationOwnershipChecking: Sendable {
    func hasLiveOwner(folderURL: URL) throws -> Bool
}

extension MeetingRecordingLockFileStore: MeetingFinalizationOwnershipChecking {}

enum MeetingFinalizationReconciler {
    static let staleProcessingErrorMessage =
        "MacParakeet quit before meeting transcription finished. Your audio is saved."

    @discardableResult
    static func reconcileStaleProcessingRows(
        repository: any MeetingFinalizationStatusRepository,
        excludingTranscriptionIDs protectedIDs: Set<UUID> = [],
        ownershipChecker: any MeetingFinalizationOwnershipChecking = MeetingRecordingLockFileStore()
    ) async throws -> [UUID] {
        try await Task.detached(priority: .utility) {
            let processingRows = try repository.fetchMeetings(withStatus: .processing)
                .filter { !protectedIDs.contains($0.id) }
            var reconciledIDs: [UUID] = []

            for row in processingRows {
                if let folderPath = row.meetingArtifactFolderPath,
                   !folderPath.isEmpty,
                   try ownershipChecker.hasLiveOwner(
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
