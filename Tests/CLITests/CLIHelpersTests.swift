import XCTest
@testable import CLI
@testable import MacParakeetCore

final class CLIHelpersTests: XCTestCase {

    // MARK: - findTranscription

    func testFindTranscriptionByExactUUID() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        try repo.save(t)

        let found = try findTranscription(id: t.id.uuidString, repo: repo)
        XCTAssertEqual(found.id, t.id)
    }

    func testFindTranscriptionByPrefix() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "test.mp3", rawTranscript: "Hello", status: .completed)
        try repo.save(t)

        let prefix = String(t.id.uuidString.prefix(8))
        let found = try findTranscription(id: prefix, repo: repo)
        XCTAssertEqual(found.id, t.id)
    }

    func testFindTranscriptionRejectsShortUUIDPrefixUnlessItIsName() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let uuid = UUID(uuidString: "AABBCCDD-1111-1111-1111-111111111111")!
        let t = Transcription(id: uuid, fileName: "ab", rawTranscript: "Hello", status: .completed)
        try repo.save(t)

        XCTAssertThrowsError(try findTranscription(id: "aab", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .shortUUIDPrefix(let minimumLength) = lookupError {
                XCTAssertEqual(minimumLength, 4)
            } else {
                XCTFail("Expected .shortUUIDPrefix, got \(lookupError)")
            }
        }

        let foundByName = try findTranscription(id: "ab", repo: repo)
        XCTAssertEqual(foundByName.id, t.id)
    }

    func testFindTranscriptionByExactName() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let t = Transcription(fileName: "Design Review", rawTranscript: "Hello", status: .completed)
        try repo.save(t)

        let found = try findTranscription(id: "design review", repo: repo)
        XCTAssertEqual(found.id, t.id)
    }

    func testFindTranscriptionThrowsNotFoundForBogusID() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findTranscription(id: "FFFFFFFF-0000-0000-0000-000000000000", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {} else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindTranscriptionThrowsEmptyIDError() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findTranscription(id: "", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .emptyID = lookupError {} else {
                XCTFail("Expected .emptyID, got \(lookupError)")
            }
        }
    }

    func testFindTranscriptionThrowsEmptyIDForWhitespace() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findTranscription(id: "   ", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .emptyID = lookupError {} else {
                XCTFail("Expected .emptyID, got \(lookupError)")
            }
        }
    }

    // MARK: - findDictation

    func testFindDictationByExactUUID() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)
        let d = Dictation(durationMs: 1000, rawTranscript: "Test dictation")
        try repo.save(d)

        let found = try findDictation(id: d.id.uuidString, repo: repo)
        XCTAssertEqual(found.id, d.id)
    }

    func testFindDictationByPrefix() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)
        let d = Dictation(durationMs: 1000, rawTranscript: "Test dictation")
        try repo.save(d)

        let prefix = String(d.id.uuidString.prefix(8))
        let found = try findDictation(id: prefix, repo: repo)
        XCTAssertEqual(found.id, d.id)
    }

    func testFindDictationRejectsShortUUIDPrefix() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)
        let uuid = UUID(uuidString: "BBCCDDEE-1111-1111-1111-111111111111")!
        try repo.save(Dictation(id: uuid, durationMs: 1000, rawTranscript: "Test dictation"))

        XCTAssertThrowsError(try findDictation(id: "bbc", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .shortUUIDPrefix(let minimumLength) = lookupError {
                XCTAssertEqual(minimumLength, 4)
            } else {
                XCTFail("Expected .shortUUIDPrefix, got \(lookupError)")
            }
        }
    }

    func testFindDictationThrowsNotFoundForBogusID() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findDictation(id: "FFFFFFFF-0000-0000-0000-000000000000", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .notFound = lookupError {} else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindDictationThrowsEmptyIDError() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findDictation(id: "", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .emptyID = lookupError {} else {
                XCTFail("Expected .emptyID, got \(lookupError)")
            }
        }
    }

    func testFindDictationThrowsEmptyIDForWhitespace() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findDictation(id: "   ", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .emptyID = lookupError {} else {
                XCTFail("Expected .emptyID, got \(lookupError)")
            }
        }
    }

    // MARK: - Ambiguous Prefix

    func testFindTranscriptionThrowsAmbiguousForSharedPrefix() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        // Two UUIDs that share the prefix "AABBCCDD"
        let uuid1 = UUID(uuidString: "AABBCCDD-1111-1111-1111-111111111111")!
        let uuid2 = UUID(uuidString: "AABBCCDD-2222-2222-2222-222222222222")!

        let t1 = Transcription(id: uuid1, fileName: "a.mp3", status: .completed)
        let t2 = Transcription(id: uuid2, fileName: "b.mp3", status: .completed)
        try repo.save(t1)
        try repo.save(t2)

        XCTAssertThrowsError(try findTranscription(id: "AABBCCDD", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .ambiguous = lookupError {} else {
                XCTFail("Expected .ambiguous, got \(lookupError)")
            }
        }
    }

    // MARK: - findMeeting

    func testFindMeetingFiltersToMeetingSourceType() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let meeting = Transcription(fileName: "Planning", status: .completed, sourceType: .meeting)
        let file = Transcription(fileName: "Planning", status: .completed, sourceType: .file)
        try repo.save(file)
        try repo.save(meeting)

        let found = try findMeeting(idOrName: "planning", repo: repo)
        XCTAssertEqual(found.id, meeting.id)
    }

    func testFindMeetingRejectsNonMeetingExactUUID() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let file = Transcription(fileName: "clip.mp3", status: .completed, sourceType: .file)
        try repo.save(file)

        XCTAssertThrowsError(try findMeeting(idOrName: file.id.uuidString, repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .notFound = lookupError {} else {
                XCTFail("Expected .notFound, got \(lookupError)")
            }
        }
    }

    func testFindMeetingRejectsShortUUIDPrefixUnlessItIsName() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        let uuid = UUID(uuidString: "CCDDEEFF-1111-1111-1111-111111111111")!
        let meeting = Transcription(id: uuid, fileName: "cc", status: .completed, sourceType: .meeting)
        try repo.save(meeting)

        XCTAssertThrowsError(try findMeeting(idOrName: "ccd", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError")
            }
            if case .shortUUIDPrefix(let minimumLength) = lookupError {
                XCTAssertEqual(minimumLength, 4)
            } else {
                XCTFail("Expected .shortUUIDPrefix, got \(lookupError)")
            }
        }

        let foundByName = try findMeeting(idOrName: "cc", repo: repo)
        XCTAssertEqual(foundByName.id, meeting.id)
    }

    func testFindDictationThrowsAmbiguousForSharedPrefix() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        let uuid1 = UUID(uuidString: "BBCCDDEE-1111-1111-1111-111111111111")!
        let uuid2 = UUID(uuidString: "BBCCDDEE-2222-2222-2222-222222222222")!

        let d1 = Dictation(id: uuid1, durationMs: 1000, rawTranscript: "First")
        let d2 = Dictation(id: uuid2, durationMs: 2000, rawTranscript: "Second")
        try repo.save(d1)
        try repo.save(d2)

        XCTAssertThrowsError(try findDictation(id: "BBCCDDEE", repo: repo)) { error in
            guard let lookupError = error as? CLILookupError else {
                return XCTFail("Expected CLILookupError, got \(error)")
            }
            if case .ambiguous = lookupError {} else {
                XCTFail("Expected .ambiguous, got \(lookupError)")
            }
        }
    }

    // MARK: - resolvedDatabasePath

    func testResolvedDatabasePathReturnsAppPathWhenNil() {
        let path = resolvedDatabasePath(nil)
        XCTAssertEqual(path, AppPaths.databasePath)
    }

    func testResolvedDatabasePathReturnsAppPathWhenEmpty() {
        let path = resolvedDatabasePath("")
        XCTAssertEqual(path, AppPaths.databasePath)
    }

    func testResolvedDatabasePathReturnsAppPathWhenWhitespace() {
        let path = resolvedDatabasePath("   ")
        XCTAssertEqual(path, AppPaths.databasePath)
    }

    func testResolvedDatabasePathReturnsCustomPath() {
        let custom = "/tmp/macparakeet-test-\(UUID().uuidString).db"
        let path = resolvedDatabasePath(custom)
        XCTAssertEqual(path, custom)
    }

    func testResolvedDatabasePathExpandsTilde() {
        let path = resolvedDatabasePath("~/macparakeet-test.db")
        XCTAssertFalse(path.hasPrefix("~"))
        XCTAssertTrue(path.hasSuffix("/macparakeet-test.db"))
    }
}
