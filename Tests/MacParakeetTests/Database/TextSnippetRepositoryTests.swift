import XCTest
import GRDB
@testable import MacParakeetCore

final class TextSnippetRepositoryTests: XCTestCase {
    var repo: TextSnippetRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TextSnippetRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - CRUD

    func testSaveAndFetch() throws {
        let snippet = TextSnippet(trigger: "my signature", expansion: "Best regards, David")
        try repo.save(snippet)

        let fetched = try repo.fetch(id: snippet.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.trigger, "my signature")
        XCTAssertEqual(fetched?.expansion, "Best regards, David")
        XCTAssertTrue(fetched?.isEnabled ?? false)
        XCTAssertEqual(fetched?.useCount, 0)
    }

    func testFetchNonExistent() throws {
        let fetched = try repo.fetch(id: UUID())
        XCTAssertNil(fetched)
    }

    func testFetchAll() throws {
        try repo.save(TextSnippet(trigger: "my phone", expansion: "555-1234"))
        try repo.save(TextSnippet(trigger: "my address", expansion: "123 Main St"))
        try repo.save(TextSnippet(trigger: "my signature", expansion: "Best regards"))

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 3)
        // Sorted alphabetically by trigger
        XCTAssertEqual(all[0].trigger, "my address")
        XCTAssertEqual(all[1].trigger, "my phone")
        XCTAssertEqual(all[2].trigger, "my signature")
    }

    func testFetchEnabled() throws {
        try repo.save(TextSnippet(trigger: "enabled", expansion: "Yes", isEnabled: true))
        try repo.save(TextSnippet(trigger: "disabled", expansion: "No", isEnabled: false))
        try repo.save(TextSnippet(trigger: "also-enabled", expansion: "Also yes", isEnabled: true))

        let enabled = try repo.fetchEnabled()
        XCTAssertEqual(enabled.count, 2)
        XCTAssertTrue(enabled.allSatisfy { $0.isEnabled })
    }

    func testDelete() throws {
        let snippet = TextSnippet(trigger: "delete-me", expansion: "Gone")
        try repo.save(snippet)

        let deleted = try repo.delete(id: snippet.id)
        XCTAssertTrue(deleted)

        let fetched = try repo.fetch(id: snippet.id)
        XCTAssertNil(fetched)
    }

    func testDeleteNonExistent() throws {
        let deleted = try repo.delete(id: UUID())
        XCTAssertFalse(deleted)
    }

    func testDeleteAll() throws {
        try repo.save(TextSnippet(trigger: "one", expansion: "1"))
        try repo.save(TextSnippet(trigger: "two", expansion: "2"))

        try repo.deleteAll()

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - Update

    func testUpdateSnippet() throws {
        var snippet = TextSnippet(trigger: "my sig", expansion: "Original")
        try repo.save(snippet)

        snippet.expansion = "Updated signature"
        snippet.updatedAt = Date()
        try repo.save(snippet)

        let fetched = try repo.fetch(id: snippet.id)
        XCTAssertEqual(fetched?.expansion, "Updated signature")
    }

    func testToggleEnabled() throws {
        var snippet = TextSnippet(trigger: "toggle", expansion: "Toggle me")
        try repo.save(snippet)
        XCTAssertTrue(snippet.isEnabled)

        snippet.isEnabled = false
        snippet.updatedAt = Date()
        try repo.save(snippet)

        let fetched = try repo.fetch(id: snippet.id)
        XCTAssertEqual(fetched?.isEnabled, false)
    }

    // MARK: - Use Count

    func testIncrementUseCount() throws {
        let s1 = TextSnippet(trigger: "first", expansion: "First expansion")
        let s2 = TextSnippet(trigger: "second", expansion: "Second expansion")
        try repo.save(s1)
        try repo.save(s2)

        try repo.incrementUseCount(ids: [s1.id, s2.id])

        let f1 = try repo.fetch(id: s1.id)
        let f2 = try repo.fetch(id: s2.id)
        XCTAssertEqual(f1?.useCount, 1)
        XCTAssertEqual(f2?.useCount, 1)

        // Increment again (only s1)
        try repo.incrementUseCount(ids: [s1.id])
        let f1b = try repo.fetch(id: s1.id)
        XCTAssertEqual(f1b?.useCount, 2)
    }

    func testIncrementUseCountEmptySet() throws {
        // Should not throw
        try repo.incrementUseCount(ids: [])
    }

    func testIncrementUseCountNonExistentID() throws {
        // Should not throw for non-existent IDs
        try repo.incrementUseCount(ids: [UUID()])
    }
}
