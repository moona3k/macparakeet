import Foundation
import OSLog

/// Single owner of settled-lock deletion. `recording.lock` may be removed on
/// the completion path only through this type, and only after verifying a
/// completed Transcription row for the session is durably saved.
public struct MeetingRecordingSettlement: Sendable {
    private static let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "MeetingRecordingSettlement"
    )

    private let lockFileStore: MeetingRecordingLockFileStoring
    private let transcriptionRepo: TranscriptionRepositoryProtocol

    public init(
        lockFileStore: MeetingRecordingLockFileStoring,
        transcriptionRepo: TranscriptionRepositoryProtocol
    ) {
        self.lockFileStore = lockFileStore
        self.transcriptionRepo = transcriptionRepo
    }

    /// Re-fetches the row by id and refuses unless it exists, is a meeting
    /// transcription for this artifact folder, and `status == .completed`.
    /// Delete I/O errors are logged and rethrown so callers can surface the
    /// failed cleanup; the lock stays protective and recovery re-settles the
    /// completed row on a later scan.
    public func settleCompletedTranscription(
        folderURL: URL,
        transcriptionID: UUID,
        sessionID: UUID
    ) async throws {
        guard let transcription = try transcriptionRepo.fetch(id: transcriptionID) else {
            throw MeetingRecordingSettlementError.missingTranscription(
                transcriptionID: transcriptionID,
                sessionID: sessionID
            )
        }
        guard transcription.sourceType == .meeting else {
            throw MeetingRecordingSettlementError.notMeetingTranscription(
                transcriptionID: transcriptionID,
                sourceType: transcription.sourceType,
                sessionID: sessionID
            )
        }
        guard transcription.status == .completed else {
            throw MeetingRecordingSettlementError.transcriptionNotCompleted(
                transcriptionID: transcriptionID,
                status: transcription.status,
                sessionID: sessionID
            )
        }
        guard Self.transcription(transcription, belongsTo: folderURL) else {
            throw MeetingRecordingSettlementError.folderMismatch(
                transcriptionID: transcriptionID,
                folderPath: folderURL.path,
                storedFolderPath: transcription.meetingArtifactFolderPath,
                storedFilePath: transcription.filePath,
                sessionID: sessionID
            )
        }

        do {
            try lockFileStore.delete(folderURL: folderURL)
        } catch {
            Self.logger.error(
                "meeting_recording_settlement_lock_delete_failed session=\(sessionID.uuidString, privacy: .public) transcription=\(transcriptionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    private static func transcription(_ transcription: Transcription, belongsTo folderURL: URL) -> Bool {
        if let folderPath = transcription.meetingArtifactFolderPath,
            MeetingArtifactPathAliases.matches(folderPath, for: folderURL)
        {
            return true
        }

        guard let filePath = transcription.filePath else { return false }
        return MeetingArtifactAudioFileNames.playbackCandidates(in: folderURL).contains { playbackURL in
            MeetingArtifactPathAliases.matches(filePath, for: playbackURL)
        }
    }
}

enum MeetingRecordingSettlementError: Error, LocalizedError, Equatable, Sendable {
    case missingTranscription(transcriptionID: UUID, sessionID: UUID)
    case notMeetingTranscription(
        transcriptionID: UUID,
        sourceType: Transcription.SourceType,
        sessionID: UUID
    )
    case transcriptionNotCompleted(
        transcriptionID: UUID,
        status: Transcription.TranscriptionStatus,
        sessionID: UUID
    )
    case folderMismatch(
        transcriptionID: UUID,
        folderPath: String,
        storedFolderPath: String?,
        storedFilePath: String?,
        sessionID: UUID
    )

    var errorDescription: String? {
        switch self {
        case let .missingTranscription(transcriptionID, sessionID):
            return "Cannot settle meeting \(sessionID): transcription \(transcriptionID) does not exist."
        case let .notMeetingTranscription(transcriptionID, sourceType, sessionID):
            return
                "Cannot settle meeting \(sessionID): transcription \(transcriptionID) has source type \(sourceType.rawValue)."
        case let .transcriptionNotCompleted(transcriptionID, status, sessionID):
            return
                "Cannot settle meeting \(sessionID): transcription \(transcriptionID) is \(status.rawValue), not completed."
        case let .folderMismatch(transcriptionID, folderPath, storedFolderPath, storedFilePath, sessionID):
            return
                "Cannot settle meeting \(sessionID): transcription \(transcriptionID) does not belong to \(folderPath) (stored folder: \(storedFolderPath ?? "nil"), stored file: \(storedFilePath ?? "nil"))."
        }
    }
}
