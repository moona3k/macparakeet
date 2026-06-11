import XCTest
import GRDB
@testable import MacParakeetCore

final class DictationRepositoryTests: XCTestCase {
    var repo: DictationRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = DictationRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - CRUD

    func testSaveAndFetch() throws {
        let dictation = Dictation(
            durationMs: 5000,
            rawTranscript: "Hello world"
        )
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.rawTranscript, "Hello world")
        XCTAssertEqual(fetched?.durationMs, 5000)
        XCTAssertEqual(fetched?.status, .completed)
        XCTAssertEqual(fetched?.processingMode, .raw)
    }

    func testFetchNonExistent() throws {
        let fetched = try repo.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testEngineAttributionRoundTrips() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "engine test",
            engine: SpeechEnginePreference.whisper.rawValue,
            engineVariant: SpeechEnginePreference.defaultWhisperModelVariant,
            language: "ko"
        )
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.engine, "whisper")
        XCTAssertEqual(fetched?.engineVariant, SpeechEnginePreference.defaultWhisperModelVariant)
        XCTAssertEqual(fetched?.language, "ko")
    }

    func testAIFormatterProfileMetadataRoundTrips() throws {
        let profileID = UUID()
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "profile test",
            aiFormatterProfileID: profileID,
            aiFormatterProfileName: "Slack Casual",
            aiFormatterProfileMatchKind: .exactApp
        )
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.aiFormatterProfileID, profileID)
        XCTAssertEqual(fetched?.aiFormatterProfileName, "Slack Casual")
        XCTAssertEqual(fetched?.aiFormatterProfileMatchKind, .exactApp)
    }

    func testFetchTreatsUnknownAIFormatterProfileMatchKindAsNil() throws {
        let manager = try DatabaseManager()
        let localRepo = DictationRepository(dbQueue: manager.dbQueue)
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "profile test",
            aiFormatterProfileMatchKind: .exactApp
        )
        try localRepo.save(dictation)

        try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE dictations SET aiFormatterProfileMatchKind = 'future_match_kind'")
        }

        let fetched = try XCTUnwrap(localRepo.fetch(id: dictation.id))
        XCTAssertNil(fetched.aiFormatterProfileMatchKind)
    }

    func testSavingHiddenDictationAgainKeepsTranscriptScrubbed() throws {
        let id = UUID()
        let scrubbedHidden = Dictation(
            id: id,
            durationMs: 1000,
            rawTranscript: "",
            cleanTranscript: nil,
            hidden: true,
            wordCount: 2
        )
        try repo.save(scrubbedHidden)

        var laterMetadataSave = scrubbedHidden
        laterMetadataSave.rawTranscript = "private raw transcript"
        laterMetadataSave.cleanTranscript = "private clean transcript"
        laterMetadataSave.audioPath = "/tmp/private.wav"
        laterMetadataSave.pastedToApp = "com.apple.TextEdit"
        laterMetadataSave.aiFormatterProfileID = UUID()
        laterMetadataSave.aiFormatterProfileName = "Private Profile"
        laterMetadataSave.aiFormatterProfileMatchKind = .exactApp
        laterMetadataSave.updatedAt = Date()
        try repo.save(laterMetadataSave)

        let fetched = try XCTUnwrap(repo.fetch(id: id))
        XCTAssertTrue(fetched.hidden)
        XCTAssertEqual(fetched.rawTranscript, "")
        XCTAssertNil(fetched.cleanTranscript)
        XCTAssertNil(fetched.audioPath)
        XCTAssertNil(fetched.pastedToApp)
        XCTAssertNil(fetched.aiFormatterProfileID)
        XCTAssertNil(fetched.aiFormatterProfileName)
        XCTAssertNil(fetched.aiFormatterProfileMatchKind)
    }

    func testTopAppsExcludesHiddenDictations() throws {
        let visible = Dictation(
            durationMs: 1000,
            rawTranscript: "visible",
            pastedToApp: "com.apple.TextEdit",
            wordCount: 2
        )
        let hidden = Dictation(
            durationMs: 1000,
            rawTranscript: "",
            pastedToApp: "com.apple.Terminal",
            hidden: true,
            wordCount: 5
        )

        try repo.save(visible)
        try repo.save(hidden)

        let topApps = try repo.topApps(limit: 10)
        XCTAssertEqual(topApps.count, 1)
        XCTAssertEqual(topApps.first?.app, "com.apple.TextEdit")
        XCTAssertEqual(topApps.first?.words, 2)
    }

    func testLegacyDictationDecodesWithNilEngineFields() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "no engine"
        )
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertNil(fetched?.engine)
        XCTAssertNil(fetched?.engineVariant)
        XCTAssertNil(fetched?.language)
        XCTAssertNil(fetched?.aiFormatterProfileID)
        XCTAssertNil(fetched?.aiFormatterProfileName)
        XCTAssertNil(fetched?.aiFormatterProfileMatchKind)
    }

    func testFetchAll() throws {
        let d1 = Dictation(
            createdAt: Date(timeIntervalSinceNow: -100),
            durationMs: 1000,
            rawTranscript: "First",
            updatedAt: Date(timeIntervalSinceNow: -100)
        )
        let d2 = Dictation(
            createdAt: Date(timeIntervalSinceNow: -50),
            durationMs: 2000,
            rawTranscript: "Second",
            updatedAt: Date(timeIntervalSinceNow: -50)
        )
        let d3 = Dictation(
            durationMs: 3000,
            rawTranscript: "Third"
        )

        try repo.save(d1)
        try repo.save(d2)
        try repo.save(d3)

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 3)
        // Most recent first
        XCTAssertEqual(all[0].rawTranscript, "Third")
        XCTAssertEqual(all[1].rawTranscript, "Second")
        XCTAssertEqual(all[2].rawTranscript, "First")
    }

    func testFetchAllWithLimit() throws {
        for i in 0..<5 {
            try repo.save(Dictation(
                durationMs: i * 1000,
                rawTranscript: "Dictation \(i)"
            ))
        }

        let limited = try repo.fetchAll(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    func testDelete() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "To be deleted"
        )
        try repo.save(dictation)

        let deleted = try repo.delete(id: dictation.id)
        XCTAssertTrue(deleted)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertNil(fetched)
    }

    func testDeleteNonExistent() throws {
        let deleted = try repo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    func testDeleteAll() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "One"))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Two"))

        try repo.deleteAll()

        let all = try repo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - FTS5 Search

    func testSearchFindsMatchingDictations() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Meeting about budget"))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Call with Sarah"))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Budget review notes"))

        let results = try repo.search(query: "budget", limit: nil)
        XCTAssertEqual(results.count, 2)
    }

    func testSearchReturnsEmptyForNoMatch() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Hello world"))

        let results = try repo.search(query: "nonexistent", limit: nil)
        XCTAssertEqual(results.count, 0)
    }

    func testSearchWithLimit() throws {
        for i in 0..<5 {
            try repo.save(Dictation(durationMs: 1000, rawTranscript: "Meeting item \(i)"))
        }

        let results = try repo.search(query: "meeting", limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testSearchEmptyQuery() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Hello"))
        let results = try repo.search(query: "", limit: nil)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Stats

    func testStats() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "One"))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Two"))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Three"))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.totalDurationMs, 6000)
    }

    func testStatsEmpty() throws {
        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
    }

    // MARK: - Update (save existing)

    func testUpdateDictation() throws {
        var dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "Original"
        )
        try repo.save(dictation)

        dictation.rawTranscript = "Updated"
        dictation.updatedAt = Date()
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.rawTranscript, "Updated")
    }

    // MARK: - Undo AI edit (displayRawTranscript)

    func testDisplayRawTranscriptDefaultsFalse() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "Hello world",
            cleanTranscript: "Hello, world."
        )
        try repo.save(dictation)

        let fetched = try repo.fetch(id: dictation.id)
        XCTAssertEqual(fetched?.displayRawTranscript, false, "New rows default to showing the cleaned text")
        XCTAssertEqual(fetched?.displayText, "Hello, world.")
    }

    func testSetDisplayRawTranscriptPersists() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "um hello world",
            cleanTranscript: "Hello, world."
        )
        try repo.save(dictation)

        let updated = try repo.setDisplayRawTranscript(id: dictation.id, value: true)
        XCTAssertTrue(updated, "setDisplayRawTranscript returns true when the row exists")

        let afterUndo = try XCTUnwrap(repo.fetch(id: dictation.id))
        XCTAssertEqual(afterUndo.displayRawTranscript, true)
        XCTAssertEqual(afterUndo.displayText, "um hello world", "Once raw is forced, displayText returns rawTranscript")
        XCTAssertEqual(afterUndo.cleanTranscript, "Hello, world.", "Cleaned text is preserved so the undo is reversible")
        XCTAssertEqual(afterUndo.hasAIEdit, true, "hasAIEdit stays true so the affordance keeps reading 'Re-apply'")

        let noOpUpdated = try repo.setDisplayRawTranscript(id: dictation.id, value: true)
        XCTAssertTrue(noOpUpdated, "Same-value writes still report that the row exists")

        let afterNoOp = try XCTUnwrap(repo.fetch(id: dictation.id))
        XCTAssertEqual(afterNoOp.updatedAt, afterUndo.updatedAt, "No-op toggle should not bump updatedAt")
    }

    func testSetDisplayRawTranscriptIsReversible() throws {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "raw",
            cleanTranscript: "Cleaned."
        )
        try repo.save(dictation)

        _ = try repo.setDisplayRawTranscript(id: dictation.id, value: true)
        _ = try repo.setDisplayRawTranscript(id: dictation.id, value: false)

        let restored = try XCTUnwrap(repo.fetch(id: dictation.id))
        XCTAssertEqual(restored.displayRawTranscript, false)
        XCTAssertEqual(restored.displayText, "Cleaned.", "Re-apply restores the AI-edited text")

        let noOpUpdated = try repo.setDisplayRawTranscript(id: dictation.id, value: false)
        XCTAssertTrue(noOpUpdated, "Same-value writes still report that the row exists")

        let afterNoOp = try XCTUnwrap(repo.fetch(id: dictation.id))
        XCTAssertEqual(afterNoOp.updatedAt, restored.updatedAt, "No-op re-apply should not bump updatedAt")
    }

    func testSetDisplayRawTranscriptUnknownIdReturnsFalse() throws {
        let updated = try repo.setDisplayRawTranscript(id: UUID(), value: true)
        XCTAssertFalse(updated, "Unknown id should report no-op")
    }

    func testSetDisplayRawTranscriptDoesNotPerturbLifetimeStats() throws {
        let dictation = Dictation(
            durationMs: 4_000,
            rawTranscript: "raw",
            cleanTranscript: "Cleaned.",
            wordCount: 3
        )
        try repo.save(dictation)

        let before = try repo.stats()

        _ = try repo.setDisplayRawTranscript(id: dictation.id, value: true)
        _ = try repo.setDisplayRawTranscript(id: dictation.id, value: false)

        let after = try repo.stats()
        XCTAssertEqual(before.totalCount, after.totalCount)
        XCTAssertEqual(before.totalDurationMs, after.totalDurationMs)
        XCTAssertEqual(before.totalWords, after.totalWords)
        XCTAssertEqual(before.longestDurationMs, after.longestDurationMs)
    }

    // MARK: - Launch cleanup (clearMissingAudioPaths)

    func testClearMissingAudioPathsClearsOnlyDanglingPaths() throws {
        let existingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-missing-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: existingFile.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: existingFile) }

        let kept = Dictation(
            durationMs: 1000,
            rawTranscript: "audio still on disk",
            audioPath: existingFile.path
        )
        let dangling = Dictation(
            durationMs: 1000,
            rawTranscript: "audio deleted externally",
            audioPath: "/nonexistent/\(UUID().uuidString).wav"
        )
        let pathless = Dictation(
            durationMs: 1000,
            rawTranscript: "never had audio"
        )
        try repo.save(kept)
        try repo.save(dangling)
        try repo.save(pathless)

        try repo.clearMissingAudioPaths()

        XCTAssertEqual(try repo.fetch(id: kept.id)?.audioPath, existingFile.path)
        XCTAssertNil(try repo.fetch(id: dangling.id)?.audioPath)
        XCTAssertNil(try repo.fetch(id: pathless.id)?.audioPath)
        XCTAssertEqual(
            try repo.fetch(id: dangling.id)?.rawTranscript,
            "audio deleted externally",
            "Clearing the path must not disturb the rest of the row"
        )
    }

    func testClearMissingAudioPathsClearsMoreRowsThanOneUpdateBatch() throws {
        // The batched UPDATE chunks at 500 IDs; 501 dangling rows crosses
        // the boundary and exercises the multi-batch path.
        var ids: [UUID] = []
        for index in 0..<501 {
            let dictation = Dictation(
                durationMs: 100,
                rawTranscript: "row \(index)",
                audioPath: "/nonexistent/batch-\(index)-\(UUID().uuidString).wav"
            )
            ids.append(dictation.id)
            try repo.save(dictation)
        }

        try repo.clearMissingAudioPaths()

        XCTAssertNil(try repo.fetch(id: ids.first!)?.audioPath)
        XCTAssertNil(try repo.fetch(id: ids.last!)?.audioPath)
    }
}
