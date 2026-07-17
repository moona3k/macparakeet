import Foundation
import XCTest

@testable import MacParakeetCore

final class MeetingAudioRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testKeepForeverReturnsNoCandidates() {
        let old = candidate(ageDays: 90)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep([old], config: .keepForever, now: now),
            []
        )
    }

    func testDeleteAfterDaysUsesStrictBoundary() {
        let olderThanThirty = candidate(id: UUID(), ageDays: 30, extraSeconds: 1)
        let exactlyThirty = candidate(id: UUID(), ageDays: 30)
        let newer = candidate(id: UUID(), ageDays: 29, extraSeconds: 23 * 60 * 60)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [olderThanThirty, exactlyThirty, newer],
                config: .deleteAfterDays(30),
                now: now
            ),
            [olderThanThirty.id]
        )
    }

    func testDeleteImmediatelyNeverSweepsSavedAudio() {
        // "Remove audio after transcription" applies at capture time (fresh
        // audio is never persisted). The sweeper must never retroactively
        // delete audio that was saved under an earlier retention setting —
        // that destroyed a real user library on 2026-07-16.
        let old = candidate(id: UUID(), ageDays: 90)
        let recent = candidate(id: UUID(), ageDays: 0, extraSeconds: 1)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [old, recent],
                config: .deleteImmediately,
                now: now
            ),
            []
        )
    }

    func testSkipsIncompleteNoAudioAndLockedCandidates() {
        let incomplete = candidate(id: UUID(), isCompleted: false, ageDays: 90)
        let noAudio = candidate(id: UUID(), hasAudioOnDisk: false, ageDays: 90)
        let locked = candidate(id: UUID(), ageDays: 90, hasRecoveryLock: true)
        let eligible = candidate(id: UUID(), ageDays: 90)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [incomplete, noAudio, locked, eligible],
                config: .deleteAfterDays(30),
                now: now
            ),
            [eligible.id]
        )
    }

    func testHasRecoveryLockRepresentsAnyRecordingLockFilePresence() {
        let parseableOrNot = candidate(ageDays: 90, hasRecoveryLock: true)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [parseableOrNot],
                config: .deleteAfterDays(30),
                now: now
            ),
            []
        )
    }

    func testCompletedSilentMeetingIsEligible() {
        let silentCompleted = candidate(ageDays: 90)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [silentCompleted],
                config: .deleteAfterDays(30),
                now: now
            ),
            [silentCompleted.id]
        )
    }

    private func candidate(
        id: UUID = UUID(),
        hasAudioOnDisk: Bool = true,
        isCompleted: Bool = true,
        ageDays: Int,
        extraSeconds: TimeInterval = 0,
        hasRecoveryLock: Bool = false
    ) -> MeetingAudioRetentionPolicy.Candidate {
        MeetingAudioRetentionPolicy.Candidate(
            id: id,
            hasAudioOnDisk: hasAudioOnDisk,
            isCompleted: isCompleted,
            ageReferenceDate: now.addingTimeInterval(-TimeInterval(ageDays * 24 * 60 * 60) - extraSeconds),
            hasRecoveryLock: hasRecoveryLock
        )
    }
}
