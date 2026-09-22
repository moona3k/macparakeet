import XCTest
import GRDB
@testable import MacParakeetCore

final class CustomWordRepositoryTests: XCTestCase {
    var repo: CustomWordRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = CustomWordRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - CRUD

    func testSaveAndFetch() throws {
        let word = CustomWord(word: "kubernetes", replacement: "Kubernetes")
        try repo.save(word)

        let fetched = try repo.fetch(id: word.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.word, "kubernetes")
        XCTAssertEqual(fetched?.replacement, "Kubernetes")
        XCTAssertEqual(fetched?.source, .manual)
        XCTAssertTrue(fetched?.isEnabled ?? false)
    }

    func testSaveVocabularyAnchor() throws {
        let word = CustomWord(word: "MacParakeet")
        try repo.save(word)

        let fetched = try repo.fetch(id: word.id)
        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.replacement)
    }

    func testFetchNonExistent() throws {
        let fetched = try repo.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testFetchAll() throws {
        try repo.save(CustomWord(word: "beta", replacement: "Beta"))
        try repo.save(CustomWord(word: "alpha", replacement: "Alpha"))
        try repo.save(CustomWord(word: "gamma", replacement: "Gamma"))

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 3)
        // Sorted alphabetically by word
        XCTAssertEqual(all[0].word, "alpha")
        XCTAssertEqual(all[1].word, "beta")
        XCTAssertEqual(all[2].word, "gamma")
    }

    func testFetchEnabled() throws {
        try repo.save(CustomWord(word: "enabled", replacement: "Enabled", isEnabled: true))
        try repo.save(CustomWord(word: "disabled", replacement: "Disabled", isEnabled: false))
        try repo.save(CustomWord(word: "also-enabled", replacement: "Also", isEnabled: true))

        let enabled = try repo.fetchEnabled()
        XCTAssertEqual(enabled.count, 2)
        XCTAssertTrue(enabled.allSatisfy { $0.isEnabled })
    }

    func testDelete() throws {
        let word = CustomWord(word: "delete-me", replacement: "Gone")
        try repo.save(word)

        let deleted = try repo.delete(id: word.id)
        XCTAssertTrue(deleted)

        let fetched = try repo.fetch(id: word.id)
        XCTAssertNil(fetched)
    }

    func testDeleteNonExistent() throws {
        let deleted = try repo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    func testDeleteAll() throws {
        try repo.save(CustomWord(word: "one", replacement: "One"))
        try repo.save(CustomWord(word: "two", replacement: "Two"))

        try repo.deleteAll()

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 0)
    }

    func testDeleteSelectedIncludesDisabledEntriesAndCountsOnlyExistingIDs() async throws {
        let enabled = CustomWord(word: "enabled", replacement: "Enabled")
        let disabled = CustomWord(word: "disabled", isEnabled: false)
        let retained = CustomWord(word: "retained", replacement: "Retained")
        for word in [enabled, disabled, retained] {
            try repo.save(word)
        }

        let selectedIDs = Set([enabled.id, disabled.id, enabled.id, UUID()])
        let deletedCount = try await repo.delete(ids: selectedIDs)

        XCTAssertEqual(deletedCount, 2)
        XCTAssertEqual(try repo.fetchAll().map(\.id), [retained.id])
        let repeatedDeleteCount = try await repo.delete(ids: selectedIDs)
        XCTAssertEqual(repeatedDeleteCount, 0)
    }

    func testDeleteEmptySelectionPreservesEntries() async throws {
        let retained = CustomWord(word: "retained")
        try repo.save(retained)

        let deletedCount = try await repo.delete(ids: [])

        XCTAssertEqual(deletedCount, 0)
        XCTAssertEqual(try repo.fetchAll().map(\.id), [retained.id])
    }

    func testDeleteLargeSelectionPreservesUnselectedEntry() async throws {
        let manager = try DatabaseManager()
        let repository = CustomWordRepository(dbQueue: manager.dbQueue)
        let selected = (0..<1_024).map { CustomWord(word: "selected-\($0)") }
        let retained = CustomWord(word: "retained")
        try await manager.dbQueue.write { db in
            for word in selected + [retained] {
                try word.save(db)
            }
        }

        let deletedCount = try await repository.delete(ids: Set(selected.map(\.id)))

        XCTAssertEqual(deletedCount, 1_024)
        XCTAssertEqual(try repository.fetchAll().map(\.id), [retained.id])
    }

    func testDeleteSelectedRollsBackEarlierChunksWhenLaterDeletionFails() async throws {
        let manager = try DatabaseManager()
        let repository = CustomWordRepository(dbQueue: manager.dbQueue)
        let selected = (0..<1_024).map { CustomWord(word: "selected-\($0)") }
        let retained = CustomWord(word: "retained")
        try await manager.dbQueue.write { db in
            for word in selected + [retained] {
                try word.save(db)
            }
            try db.execute(
                sql: """
                    CREATE TABLE deletion_attempts (count INTEGER NOT NULL);
                    INSERT INTO deletion_attempts VALUES (0);
                    CREATE TRIGGER fail_later_vocab_deletion
                    AFTER DELETE ON custom_words
                    BEGIN
                        UPDATE deletion_attempts SET count = count + 1;
                        SELECT RAISE(ABORT, 'forced batch deletion failure')
                        WHERE (SELECT count FROM deletion_attempts) > 500;
                    END;
                    """)
        }

        do {
            _ = try await repository.delete(ids: Set(selected.map(\.id)))
            XCTFail("Expected the deletion trigger to reject a later chunk")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            XCTAssertEqual(error.message, "forced batch deletion failure")
        }

        let remainingIDs = Set(try repository.fetchAll().map(\.id))
        XCTAssertEqual(remainingIDs, Set((selected + [retained]).map(\.id)))
        let committedDeletionCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count FROM deletion_attempts")
        }
        XCTAssertEqual(committedDeletionCount, 0)
    }

    // MARK: - Update

    func testUpdateWord() throws {
        var word = CustomWord(word: "original", replacement: "Original")
        try repo.save(word)

        word.replacement = "Updated"
        word.updatedAt = Date()
        try repo.save(word)

        let fetched = try repo.fetch(id: word.id)
        XCTAssertEqual(fetched?.replacement, "Updated")
    }

    func testToggleEnabled() throws {
        var word = CustomWord(word: "toggleme", replacement: "Toggle")
        try repo.save(word)
        XCTAssertTrue(word.isEnabled)

        word.isEnabled = false
        word.updatedAt = Date()
        try repo.save(word)

        let fetched = try repo.fetch(id: word.id)
        XCTAssertEqual(fetched?.isEnabled, false)
    }
}
