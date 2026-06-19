import Foundation
import os

public struct MeetingAudioRetentionSweepResult: Sendable, Equatable {
    public let evaluatedCount: Int
    public let eligibleCount: Int
    public let detachedCount: Int
    public let skippedLockedCount: Int
    public let skippedUnmanagedCount: Int
    public let failedCount: Int
}

public final class MeetingAudioRetentionSweeper: @unchecked Sendable {
    private let repository: TranscriptionRepositoryProtocol
    private let fileManager: FileManager
    private let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "MeetingAudioRetention"
    )

    public init(
        repository: TranscriptionRepositoryProtocol,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.fileManager = fileManager
    }

    public func sweep(
        retention: MeetingAudioRetention,
        now: Date = Date()
    ) throws -> MeetingAudioRetentionSweepResult {
        guard retention.automaticallyDeletesAudio else {
            return MeetingAudioRetentionSweepResult(
                evaluatedCount: 0,
                eligibleCount: 0,
                detachedCount: 0,
                skippedLockedCount: 0,
                skippedUnmanagedCount: 0,
                failedCount: 0
            )
        }

        let cutoff = cutoffDate(for: retention, now: now)
        let transcriptions = try repository.fetchMeetingAudioRetentionCandidates(createdAtOrBefore: cutoff)
        var candidates: [MeetingAudioRetentionPolicy.Candidate] = []
        var skippedLockedCount = 0

        for transcription in transcriptions {
            let hasLock = transcription.filePath
                .map { hasAnyRecordingLock(forAudioPath: $0) }
                ?? false
            if hasLock {
                skippedLockedCount += 1
            }
            candidates.append(MeetingAudioRetentionPolicy.Candidate(
                id: transcription.id,
                hasAudioOnDisk: !(transcription.filePath?.isEmpty ?? true),
                isCompleted: transcription.status == .completed,
                ageReferenceDate: transcription.createdAt,
                hasRecoveryLock: hasLock
            ))
        }

        let eligibleIDs = Set(MeetingAudioRetentionPolicy.sweep(candidates, config: retention, now: now))
        var detachedCount = 0
        var skippedUnmanagedCount = 0
        var failedCount = 0

        for transcription in transcriptions where eligibleIDs.contains(transcription.id) {
            do {
                let result = try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
                    for: transcription,
                    repository: repository,
                    fileManager: fileManager
                )
                if result.detached {
                    detachedCount += 1
                } else {
                    skippedUnmanagedCount += 1
                }
            } catch {
                failedCount += 1
                logger.warning(
                    "meeting_audio_retention_detach_failed id=\(transcription.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
            }
        }

        return MeetingAudioRetentionSweepResult(
            evaluatedCount: transcriptions.count,
            eligibleCount: eligibleIDs.count,
            detachedCount: detachedCount,
            skippedLockedCount: skippedLockedCount,
            skippedUnmanagedCount: skippedUnmanagedCount,
            failedCount: failedCount
        )
    }

    private func cutoffDate(for retention: MeetingAudioRetention, now: Date) -> Date {
        switch retention {
        case .keepForever:
            return now
        case .deleteAfterDays(let days):
            return now.addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
        case .deleteImmediately:
            return now
        }
    }

    private func hasAnyRecordingLock(forAudioPath filePath: String) -> Bool {
        let folderURL = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        let lockURL = MeetingRecordingLockFileStore.lockFileURL(for: folderURL)
        return fileManager.fileExists(atPath: lockURL.path)
    }
}
