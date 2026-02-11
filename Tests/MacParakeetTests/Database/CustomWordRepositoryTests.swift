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
