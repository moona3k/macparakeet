import Foundation
import GRDB
import XCTest

@testable import MacParakeetCore

final class SpeakerVoiceprintRetentionTests: XCTestCase {
    func testLaunchAndHourlyTickPruneBothStoresWithoutVoiceActivity() async throws {
        let clock = RetentionTestClock()
        let fixture = try RetentionFixture(now: clock.now)
        let retention = SpeakerVoiceprintRetention(
            candidates: fixture.candidates,
            journal: fixture.journal,
            now: { clock.now },
            sleep: { try await clock.sleep($0) }
        )
        defer { withExtendedLifetime(retention) {} }

        await fulfillment(of: [clock.firstSweep], timeout: 2)
        // Inspect raw rows: repository reads themselves prune, which would
        // hide a missing lifecycle sweep.
        XCTAssertEqual(try fixture.candidateCount(), 1)
        XCTAssertEqual(try fixture.journalCount(), 1)
        XCTAssertEqual(clock.sleepDurations, [.seconds(3600)])

        clock.advance(by: 3600)
        await fulfillment(of: [clock.secondSweep], timeout: 2)
        XCTAssertEqual(try fixture.candidateCount(), 0)
        XCTAssertEqual(try fixture.journalCount(), 0)
        XCTAssertEqual(clock.sleepDurations, [.seconds(3600), .seconds(3600)])
    }

    func testCandidateFailureDoesNotSuppressJournalPruningAndRetriesNextTick() async throws {
        let clock = RetentionTestClock()
        let fixture = try RetentionFixture(now: clock.now)
        let candidates = FailingOnceCandidateRepository(wrapped: fixture.candidates)
        let retention = SpeakerVoiceprintRetention(
            candidates: candidates,
            journal: fixture.journal,
            now: { clock.now },
            sleep: { try await clock.sleep($0) }
        )
        defer { withExtendedLifetime(retention) {} }

        await fulfillment(of: [clock.firstSweep], timeout: 2)
        XCTAssertEqual(try fixture.candidateCount(), 2)
        XCTAssertEqual(try fixture.journalCount(), 1)

        clock.advance(by: 3600)
        await fulfillment(of: [clock.secondSweep], timeout: 2)
        XCTAssertEqual(try fixture.candidateCount(), 0)
        XCTAssertEqual(try fixture.journalCount(), 0)
        XCTAssertEqual(candidates.pruneCalls, 2)
        XCTAssertFalse(candidates.prunedOnMainThread)
    }

    func testReleasingOwnerCancelsSleepAndDoesNotRetainItself() async throws {
        let clock = RetentionTestClock()
        let fixture = try RetentionFixture(now: clock.now)
        var retention: SpeakerVoiceprintRetention? = SpeakerVoiceprintRetention(
            candidates: fixture.candidates,
            journal: fixture.journal,
            now: { clock.now },
            sleep: { try await clock.sleep($0) }
        )
        weak var weakRetention = retention

        await fulfillment(of: [clock.firstSweep], timeout: 2)
        XCTAssertNotNil(weakRetention)
        retention = nil
        await fulfillment(of: [clock.cancelledSleep], timeout: 2)

        XCTAssertNil(weakRetention)
        XCTAssertEqual(clock.sleepDurations, [.seconds(3600)])
    }
}

private struct RetentionFixture {
    let dbQueue: DatabaseQueue
    let candidates: SpeakerEmbeddingCandidateRepository
    let journal: SpeakerMatchJournalRepository

    init(now: Date) throws {
        dbQueue = try DatabaseManager().dbQueue
        candidates = SpeakerEmbeddingCandidateRepository(dbQueue: dbQueue)
        journal = SpeakerMatchJournalRepository(dbQueue: dbQueue)
        let transcription = Transcription(fileName: "meeting.wav", sourceType: .meeting)
        try TranscriptionRepository(dbQueue: dbQueue).save(transcription)

        var vector = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        vector[0] = 1
        let embedding = try XCTUnwrap(
            SpeakerEmbedding(
                rawVector: vector,
                identity: SpeakerModelIdentity(
                    embeddingModelId: "test-model",
                    aggregationProfileId: "test-aggregation"
                )
            ))

        // Seed persisted rows directly so already-expired data survives until
        // the app lifecycle starts. One row per store expires at the next tick.
        try dbQueue.write { db in
            for (index, offset) in [TimeInterval(-1), 1800].enumerated() {
                let expiresAt = now.addingTimeInterval(offset)
                try SpeakerEmbeddingCandidate(
                    transcriptionId: transcription.id,
                    speakerId: "S\(index)",
                    transcriptFingerprint: "fp",
                    embedding: embedding,
                    speechSeconds: 30,
                    captureDomain: .system,
                    createdAt: expiresAt.addingTimeInterval(-SpeakerEmbeddingCandidateRepository.defaultRetention),
                    expiresAt: expiresAt
                ).insert(db)
                try SpeakerMatchJournalEntry(
                    transcriptionId: transcription.id,
                    speakerId: "S\(index)",
                    transcriptFingerprint: "fp",
                    outcome: .noComparableProfile,
                    speechSeconds: 30,
                    createdAt: expiresAt.addingTimeInterval(-SpeakerMatchJournalRepository.defaultRetention)
                ).insert(db)
            }
        }
    }

    func candidateCount() throws -> Int {
        try dbQueue.read { try SpeakerEmbeddingCandidate.fetchCount($0) }
    }

    func journalCount() throws -> Int {
        try dbQueue.read { try SpeakerMatchJournalEntry.fetchCount($0) }
    }
}

/// The stream suspends each tick without elapsed wall-clock time. Its iterator
/// exits on task cancellation, matching the production Task.sleep contract.
private final class RetentionTestClock: @unchecked Sendable {
    let firstSweep = XCTestExpectation(description: "initial retention sweep finished")
    let secondSweep = XCTestExpectation(description: "next retention sweep finished")
    let cancelledSleep = XCTestExpectation(description: "retention sleep cancelled")
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_757_000_000)
    private var durations: [Duration] = []
    private let ticks = AsyncStream<Void>.makeStream()

    var now: Date { lock.withLock { date } }
    var sleepDurations: [Duration] { lock.withLock { durations } }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
        ticks.continuation.yield(())
    }

    func sleep(_ duration: Duration) async throws {
        let count = lock.withLock {
            durations.append(duration)
            return durations.count
        }
        if count == 1 { firstSweep.fulfill() }
        if count == 2 { secondSweep.fulfill() }
        var iterator = ticks.stream.makeAsyncIterator()
        _ = await iterator.next()
        if Task.isCancelled {
            cancelledSleep.fulfill()
            throw CancellationError()
        }
    }
}

private final class FailingOnceCandidateRepository: SpeakerEmbeddingCandidateRepositoryProtocol, @unchecked Sendable {
    private enum Failure: Error { case unavailable }
    private let wrapped: SpeakerEmbeddingCandidateRepository
    private let lock = NSLock()
    private var calls = 0
    private var usedMainThread = false

    init(wrapped: SpeakerEmbeddingCandidateRepository) {
        self.wrapped = wrapped
    }

    var pruneCalls: Int { lock.withLock { calls } }
    var prunedOnMainThread: Bool { lock.withLock { usedMainThread } }

    func pruneExpired(now: Date) throws {
        let shouldFail = lock.withLock {
            calls += 1
            usedMainThread = usedMainThread || Thread.isMainThread
            return calls == 1
        }
        if shouldFail { throw Failure.unavailable }
        try wrapped.pruneExpired(now: now)
    }

    func upsert(_ candidates: [SpeakerEmbeddingCandidate], now: Date) throws {
        try wrapped.upsert(candidates, now: now)
    }

    func candidate(
        transcriptionId: UUID, speakerId: String, fingerprint: String, now: Date
    ) throws -> SpeakerEmbeddingCandidate? {
        try wrapped.candidate(
            transcriptionId: transcriptionId, speakerId: speakerId, fingerprint: fingerprint, now: now
        )
    }

    func delete(transcriptionId: UUID, speakerId: String, fingerprint: String) throws {
        try wrapped.delete(transcriptionId: transcriptionId, speakerId: speakerId, fingerprint: fingerprint)
    }

    func deleteAll() throws { try wrapped.deleteAll() }
}
