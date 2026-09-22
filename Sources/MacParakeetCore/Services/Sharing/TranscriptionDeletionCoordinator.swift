import Foundation

/// Local deletion never waits for the network. The durable stop intent comes
/// first; failed file cleanup leaves the source retryable but does not undo stop.
public enum TranscriptionDeletionCoordinator {
    @discardableResult
    public static func delete(
        _ transcription: Transcription,
        repository: TranscriptionRepositoryProtocol,
        credentials: ShareCredentialStoring = ShareCredentialStore(),
        removeAssets: ((Transcription) throws -> Void)? = nil
    ) throws -> Bool {
        try TranscriptionAssetCleanup.withMeetingMediaMutationLease(for: transcription) {
            let childProcessingLease = try splitChildProcessingLease(for: transcription)
            defer { childProcessingLease?.release() }

            let shareIds = try repository.prepareForDeletion(id: transcription.id)
            for id in shareIds { try credentials.removeContentKey(forRemoteShareId: id) }
            if let removeAssets {
                try removeAssets(transcription)
            } else {
                try TranscriptionAssetCleanup.removeOwnedAssetsUnlocked(for: transcription, fileManager: .default)
            }
            return try repository.delete(id: transcription.id)
        }
    }

    /// Split-child deletion takes the broad media-root lease first (outside
    /// this helper), then this narrow child lease. Automation holds the child
    /// lease across provider work; its later artifact refresh may attempt the
    /// media lease only nonblockingly. Neither path waits while holding the
    /// other lease, which prevents deadlock while ensuring deletion cannot
    /// complete during a provider call.
    private static func splitChildProcessingLease(
        for transcription: Transcription
    ) throws -> MeetingSplitChildProcessingLease? {
        guard transcription.sourceType == .meeting,
              transcription.splitProvenance != nil,
              let folderURL = MeetingArtifactStore.sessionFolderURL(for: transcription)
        else {
            return nil
        }
        return try MeetingSplitChildProcessingLease.acquire(
            childId: transcription.id,
            recordingsRootURL: folderURL.standardizedFileURL.deletingLastPathComponent()
        )
    }
}
