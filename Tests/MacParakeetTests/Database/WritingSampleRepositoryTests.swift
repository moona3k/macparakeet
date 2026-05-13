import XCTest
@testable import MacParakeetCore

final class WritingSampleRepositoryTests: XCTestCase {
    var repo: WritingSampleRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = WritingSampleRepository(dbQueue: manager.dbQueue)
    }

    func testWordCountIsDerivedFromText() {
        let sample = WritingSample(title: "Email", text: "One two\nthree   four")
        XCTAssertEqual(sample.wordCount, 4)
    }

    func testSaveFetchAndOrderWritingSamples() throws {
        let older = WritingSample(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            title: "Older",
            text: "old sample",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newestB = WritingSample(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            title: "Beta",
            text: "new beta",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let newestA = WritingSample(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            title: "Alpha",
            text: "new alpha",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        try repo.save(older)
        try repo.save(newestB)
        try repo.save(newestA)

        XCTAssertEqual(try repo.fetch(id: newestA.id)?.title, "Alpha")
        XCTAssertEqual(try repo.fetchAll().map(\.title), ["Alpha", "Beta", "Older"])
    }

    func testDeleteOneAndDeleteAll() throws {
        let first = WritingSample(title: "First", text: "one")
        let second = WritingSample(title: "Second", text: "two")
        try repo.save(first)
        try repo.save(second)

        XCTAssertTrue(try repo.delete(id: first.id))
        XCTAssertEqual(try repo.fetchAll().map(\.id), [second.id])

        try repo.deleteAll()
        XCTAssertTrue(try repo.fetchAll().isEmpty)
    }
}
