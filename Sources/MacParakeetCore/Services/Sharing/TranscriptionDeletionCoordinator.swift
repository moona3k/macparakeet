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
}
