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

    func testFindTranscriptionThrowsNotFoundForBogusID() throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findTranscription(id: "FFFFFFFF-0000-0000-0000-000000000000", repo: repo)) { error in
            XCTAssertTrue(error is CLILookupError)
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

    func testFindDictationThrowsNotFoundForBogusID() throws {
        let db = try DatabaseManager()
        let repo = DictationRepository(dbQueue: db.dbQueue)

        XCTAssertThrowsError(try findDictation(id: "FFFFFFFF-0000-0000-0000-000000000000", repo: repo)) { error in
            XCTAssertTrue(error is CLILookupError)
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
}
