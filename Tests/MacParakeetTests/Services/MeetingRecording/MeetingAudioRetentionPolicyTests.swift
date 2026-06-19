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

    func testDeleteImmediatelySweepsExistingCompletedAudio() {
        let alreadySaved = candidate(id: UUID(), ageDays: 0, extraSeconds: 1)
        let justCreated = candidate(id: UUID(), ageDays: 0)

        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [alreadySaved, justCreated],
                config: .deleteImmediately,
                now: now
            ),
            [alreadySaved.id]
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
