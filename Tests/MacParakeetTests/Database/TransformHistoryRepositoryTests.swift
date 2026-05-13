import XCTest
@testable import MacParakeetCore

final class TransformHistoryRepositoryTests: XCTestCase {
    var repo: TransformHistoryRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TransformHistoryRepository(dbQueue: manager.dbQueue)
    }

    func testSaveAndFetchRecentOrdersNewestFirst() throws {
        let older = TransformHistoryEntry(
            transformId: UUID(uuidString: "0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11"),
            transformName: "Polish",
            inputText: "rough",
            outputText: "polished",
            sourceAppBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 10,
            totalElapsedMs: 20,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = TransformHistoryEntry(
            transformId: UUID(uuidString: "1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55"),
            transformName: "Distill",
            inputText: "long",
            outputText: "short",
            sourceAppBundleID: "com.tinyspeck.slackmacgap",
            sourceAppName: "Slack",
            capturePath: "clipboard",
            replacementPath: "clipboardPaste",
            llmElapsedMs: 30,
            totalElapsedMs: 45,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try repo.save(older)
        try repo.save(newer)

        let fetched = try repo.fetchRecent(limit: 10)
        XCTAssertEqual(fetched.map(\.transformName), ["Distill", "Polish"])
        XCTAssertEqual(fetched.first?.inputText, "long")
        XCTAssertEqual(fetched.first?.outputText, "short")
        XCTAssertEqual(try repo.count(), 2)
    }

    func testFetchRecentHonorsLimitWithoutDeletingRows() throws {
        for index in 0..<5 {
            try repo.save(
                TransformHistoryEntry(
                    transformName: "Transform \(index)",
                    inputText: "input \(index)",
                    outputText: "output \(index)",
                    capturePath: "ax",
                    replacementPath: "ax",
                    llmElapsedMs: index,
                    totalElapsedMs: index + 1,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        let fetched = try repo.fetchRecent(limit: 2)

        XCTAssertEqual(fetched.map(\.transformName), ["Transform 4", "Transform 3"])
        XCTAssertEqual(try repo.count(), 5)
    }

    func testFetchRecentAndCountForTransformUsesTransformSpecificWindow() throws {
        let polishID = UUID(uuidString: "0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11")!
        let distillID = UUID(uuidString: "1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55")!
        for index in 0..<5 {
            try repo.save(
                TransformHistoryEntry(
                    transformId: polishID,
                    transformName: "Polish",
                    inputText: "rough \(index)",
                    outputText: "polished \(index)",
                    capturePath: "ax",
                    replacementPath: "ax",
                    llmElapsedMs: 1,
                    totalElapsedMs: 2,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        try repo.save(
            TransformHistoryEntry(
                transformId: distillID,
                transformName: "Distill",
                inputText: "long",
                outputText: "short",
                capturePath: "clipboard",
                replacementPath: "clipboardPaste",
                llmElapsedMs: 3,
                totalElapsedMs: 4,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        let fetched = try repo.fetchRecent(transformId: polishID, limit: 2)

        XCTAssertEqual(fetched.map(\.inputText), ["rough 4", "rough 3"])
        XCTAssertEqual(try repo.count(transformId: polishID), 5)
    }

    func testFetchByIDAndIDPrefix() throws {
        let first = TransformHistoryEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            transformName: "Polish",
            inputText: "one",
            outputText: "One.",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let second = TransformHistoryEntry(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            transformName: "Distill",
            inputText: "two",
            outputText: "Two.",
            capturePath: "clipboard",
            replacementPath: "clipboardPaste",
            llmElapsedMs: 3,
            totalElapsedMs: 4,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try repo.save(first)
        try repo.save(second)

        XCTAssertEqual(try repo.fetch(id: first.id)?.id, first.id)
        XCTAssertEqual(try repo.fetch(idPrefix: "2222").map(\.id), [second.id])
        XCTAssertEqual(try repo.fetch(idPrefix: "1111").map(\.id), [first.id])
        XCTAssertTrue(try repo.fetch(idPrefix: "%").isEmpty)
    }

    func testDeleteSingleAndDeleteAll() throws {
        let first = TransformHistoryEntry(
            transformName: "Polish",
            inputText: "one",
            outputText: "One.",
            capturePath: "ax",
            replacementPath: "ax",
            llmElapsedMs: 1,
            totalElapsedMs: 2
        )
        let second = TransformHistoryEntry(
            transformName: "Decide",
            inputText: "two",
            outputText: "Choose two.",
            capturePath: "clipboard",
            replacementPath: "clipboardPaste",
            llmElapsedMs: 3,
            totalElapsedMs: 4
        )
        try repo.save(first)
        try repo.save(second)

        XCTAssertTrue(try repo.delete(id: first.id))
        XCTAssertEqual(try repo.fetchRecent(limit: 10).map(\.id), [second.id])

        try repo.deleteAll()
        XCTAssertEqual(try repo.count(), 0)
    }

    func testDeleteAllForTransformOnlyRemovesMatchingRows() throws {
        let polishID = UUID(uuidString: "0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11")!
        let distillID = UUID(uuidString: "1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55")!
        try repo.save(
            TransformHistoryEntry(
                transformId: polishID,
                transformName: "Polish",
                inputText: "one",
                outputText: "One.",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 1,
                totalElapsedMs: 2
            )
        )
        try repo.save(
            TransformHistoryEntry(
                transformId: polishID,
                transformName: "Polish",
                inputText: "two",
                outputText: "Two.",
                capturePath: "clipboard",
                replacementPath: "clipboardPaste",
                llmElapsedMs: 3,
                totalElapsedMs: 4
            )
        )
        try repo.save(
            TransformHistoryEntry(
                transformId: distillID,
                transformName: "Distill",
                inputText: "three",
                outputText: "Three.",
                capturePath: "ax",
                replacementPath: "ax",
                llmElapsedMs: 5,
                totalElapsedMs: 6
            )
        )

        try repo.deleteAll(transformId: polishID)

        XCTAssertEqual(try repo.fetchRecent(limit: 10).map(\.transformName), ["Distill"])
        XCTAssertEqual(try repo.count(), 1)
    }
}
