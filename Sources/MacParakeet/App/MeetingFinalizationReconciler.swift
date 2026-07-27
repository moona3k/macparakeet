import Foundation
import MacParakeetCore
import OSLog

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

enum MeetingFinalizationReconciler {
    private static let logger = Logger(
        subsystem: "com.macparakeet",
        category: "MeetingFinalizationReconciler"
    )

    static let staleProcessingErrorMessage =
        "MacParakeet quit before meeting transcription finished. Your audio is saved."

    @discardableResult
    static func reconcileStaleProcessingRows(
        repository: any MeetingFinalizationStatusRepository,
        excludingTranscriptionIDs protectedIDs: Set<UUID> = [],
        ownershipCoordinator: any MeetingFinalizationReconciliationCoordinating =
            MeetingRecordingLockFileStore()
    ) async throws -> [UUID] {
        try await Task.detached(priority: .utility) {
            let processingRows = try repository.fetchMeetings(withStatus: .processing)
                .filter { !protectedIDs.contains($0.id) }
            var reconciledIDs: [UUID] = []

            for row in processingRows {
                do {
                    let transition: @Sendable () throws -> Bool = {
                        try repository.transitionStatus(
                            id: row.id,
                            from: .processing,
                            to: .error,
                            errorMessage: staleProcessingErrorMessage
                        )
                    }
                    let didReconcile: Bool
                    if let folderPath = row.meetingArtifactFolderPath,
                        !folderPath.isEmpty
                    {
                        didReconcile = try ownershipCoordinator.reconcileIfUnowned(
                            folderURL: URL(fileURLWithPath: folderPath, isDirectory: true),
                            transition: transition
                        )
                    } else {
                        didReconcile = try transition()
                    }
                    if didReconcile {
                        reconciledIDs.append(row.id)
                    }
                } catch {
                    logger.error(
                        """
                        Failed to reconcile stale meeting \(row.id.uuidString, privacy: .public): \
                        \(error.localizedDescription, privacy: .private)
                        """
                    )
                }
            }
            return reconciledIDs
        }.value
    }
}
