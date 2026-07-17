import Foundation

public enum MeetingAudioRetentionPolicy {
    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var hasAudioOnDisk: Bool
        public var isCompleted: Bool
        public var ageReferenceDate: Date
        public var hasRecoveryLock: Bool

        public init(
            id: UUID,
            hasAudioOnDisk: Bool,
            isCompleted: Bool,
            ageReferenceDate: Date,
            hasRecoveryLock: Bool
        ) {
            self.id = id
            self.hasAudioOnDisk = hasAudioOnDisk
            self.isCompleted = isCompleted
            self.ageReferenceDate = ageReferenceDate
            self.hasRecoveryLock = hasRecoveryLock
        }
    }

    public static func sweep(
        _ candidates: [Candidate],
        config: MeetingAudioRetention,
        now: Date
    ) -> [UUID] {
        // Age-based cleanup only. `.deleteImmediately` is enforced at capture
        // time (fresh audio is never persisted); treating it as "cutoff = now"
        // here retroactively destroyed a whole library's saved audio when the
        // mode was merely selected in Settings (2026-07-16 incident).
        guard config.mode == .deleteAfterDays else { return [] }

        let retentionInterval = TimeInterval(config.deleteAfterDays * 24 * 60 * 60)
        return candidates.compactMap { candidate in
            guard candidate.hasAudioOnDisk,
                  candidate.isCompleted,
                  !candidate.hasRecoveryLock,
                  now.timeIntervalSince(candidate.ageReferenceDate) > retentionInterval else {
                return nil
            }
            return candidate.id
        }
    }
}
