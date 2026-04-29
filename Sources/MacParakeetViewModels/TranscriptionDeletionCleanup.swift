import Foundation
import MacParakeetCore

enum TranscriptionDeletionCleanup {
    static func removeOwnedAssets(for transcription: Transcription) throws {
        try TranscriptionAssetCleanup.removeOwnedAssets(for: transcription)
    }
}
