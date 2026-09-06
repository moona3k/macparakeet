import GRDB
import XCTest
@testable import MacParakeetCore

final class PromptCollectionRepositoryTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var repository: PromptCollectionRepository!

    override func setUpWithError() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: configuration)
        try dbQueue.write { db in
            try db.create(table: "prompt_collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorToken", .text)
                t.column("sortOrder", .integer).notNull()
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(
                sql: "CREATE UNIQUE INDEX idx_prompt_collections_name ON prompt_collections(name COLLATE NOCASE)"
            )
            try db.create(table: "prompts") { t in
                t.column("id", .text).primaryKey()
                t.column("collectionId", .text)
                    .references("prompt_collections", onDelete: .setNull)
                t.column("updatedAt", .text).notNull()
                t.column("deletedAt", .text)
            }
        }
        repository = PromptCollectionRepository(dbQueue: dbQueue)
    }

    func testSaveNormalizesValuesAndFetchAllUsesUserOrder() throws {
        let later = PromptCollection(name: "  Beta  ", colorToken: "  blue ", sortOrder: 2)
        let alpha = PromptCollection(name: "alpha", colorToken: "  ", sortOrder: 1)
        let zulu = PromptCollection(name: "Zulu", sortOrder: 1)

        try repository.save(later)
        try repository.save(zulu)
        try repository.save(alpha)

        let fetched = try repository.fetchAll()
        XCTAssertEqual(fetched.map(\.name), ["alpha", "Zulu", "Beta"])
        XCTAssertNil(fetched[0].colorToken)
        XCTAssertEqual(fetched[2].colorToken, "blue")
    }

    func testEmptyAndCaseInsensitiveDuplicateNamesAreRejected() throws {
        XCTAssertThrowsError(try repository.save(PromptCollection(name: "  \n "))) { error in
            XCTAssertEqual(error as? PromptCollectionRepositoryError, .emptyName)
        }

        try repository.save(PromptCollection(name: "Customer"))
        XCTAssertThrowsError(try repository.save(PromptCollection(name: " customer "))) { error in
            XCTAssertEqual(
                error as? PromptCollectionRepositoryError,
                .duplicateName("customer")
            )
        }
    }

    func testReorderRequiresAndPersistsTheCompleteSet() throws {
        let first = PromptCollection(name: "First", sortOrder: 0)
        let second = PromptCollection(name: "Second", sortOrder: 1)
        try repository.save(first)
        try repository.save(second)

        XCTAssertThrowsError(try repository.reorder(ids: [second.id])) { error in
            XCTAssertEqual(error as? PromptCollectionRepositoryError, .invalidOrder)
        }
        XCTAssertEqual(try repository.fetchAll().map(\.id), [first.id, second.id])

        try repository.reorder(ids: [second.id, first.id])
        XCTAssertEqual(try repository.fetchAll().map(\.id), [second.id, first.id])
        XCTAssertEqual(try repository.fetchAll().map(\.sortOrder), [0, 1])
    }

    func testAssignmentReplacesMembershipAndNilUnfilesPrompt() throws {
        let customer = PromptCollection(name: "Customer")
        let internalCollection = PromptCollection(name: "Internal")
        try repository.save(customer)
        try repository.save(internalCollection)
        let promptId = try insertPrompt()
        let assignments = PromptCollectionAssignmentService(dbQueue: dbQueue)

        XCTAssertTrue(try assignments.assign(promptId: promptId, to: customer.id))
        XCTAssertEqual(try promptCollectionId(promptId), customer.id)
        XCTAssertTrue(try assignments.assign(promptId: promptId, to: internalCollection.id))
        XCTAssertEqual(try promptCollectionId(promptId), internalCollection.id)
        XCTAssertTrue(try assignments.assign(promptId: promptId, to: nil))
        XCTAssertNil(try promptCollectionId(promptId))
    }

    func testAssignmentRejectsUnknownCollectionAndDeletedPrompt() throws {
        let promptId = try insertPrompt(deletedAt: Date())
        let unknownId = UUID()
        let assignments = PromptCollectionAssignmentService(dbQueue: dbQueue)

        XCTAssertThrowsError(try assignments.assign(promptId: promptId, to: unknownId)) { error in
            XCTAssertEqual(
                error as? PromptCollectionRepositoryError,
                .collectionNotFound(unknownId)
            )
        }
        XCTAssertFalse(try assignments.assign(promptId: promptId, to: nil))
    }

    func testDeletingCollectionUnfilesPromptWithoutDeletingIt() throws {
        let collection = PromptCollection(name: "Customer")
        try repository.save(collection)
        let promptId = try insertPrompt(collectionId: collection.id)

        XCTAssertTrue(try repository.delete(id: collection.id))
        XCTAssertNil(try promptCollectionId(promptId))
        let promptCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prompts")
        }
        XCTAssertEqual(promptCount, 1)
    }

    func testDatabaseManagerMigrationSupportsCollectionMembership() throws {
        let manager = try DatabaseManager()
        let collectionRepository = PromptCollectionRepository(dbQueue: manager.dbQueue)
        let promptRepository = PromptRepository(dbQueue: manager.dbQueue)
        let assignments = PromptCollectionAssignmentService(dbQueue: manager.dbQueue)
        let collection = PromptCollection(name: "Migration collection")
        let prompt = Prompt(name: "Collection migration prompt", content: "Summarize this")

        try collectionRepository.save(collection)
        try promptRepository.save(prompt)
        XCTAssertTrue(try assignments.assign(promptId: prompt.id, to: collection.id))
        XCTAssertEqual(try promptRepository.fetch(id: prompt.id)?.collectionId, collection.id)

        XCTAssertTrue(try collectionRepository.delete(id: collection.id))
        XCTAssertNil(try promptRepository.fetch(id: prompt.id)?.collectionId)
        XCTAssertNotNil(try promptRepository.fetch(id: prompt.id))
    }

    private func insertPrompt(collectionId: UUID? = nil, deletedAt: Date? = nil) throws -> UUID {
        let id = UUID()
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO prompts (id, collectionId, updatedAt, deletedAt) VALUES (?, ?, ?, ?)",
                arguments: [id, collectionId, Date(), deletedAt]
            )
        }
        return id
    }

    private func promptCollectionId(_ id: UUID) throws -> UUID? {
        try dbQueue.read { db in
            try UUID.fetchOne(
                db,
                sql: "SELECT collectionId FROM prompts WHERE id = ?",
                arguments: [id]
            )
        }
    }
}
