import XCTest
@testable import MacParakeetCore

final class TransformProfileRepositoryTests: XCTestCase {
    var repo: TransformProfileRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TransformProfileRepository(dbQueue: manager.dbQueue)
    }

    func testSaveFetchAndUpdateProfile() throws {
        let polish = Prompt.builtInPrompts().first(where: { $0.name == "Polish" })!
        let now = Date(timeIntervalSince1970: 100)
        var profile = TransformProfile.defaultProfile(for: polish, now: now)

        try repo.save(profile)

        var fetched = try XCTUnwrap(repo.fetch(promptId: polish.id))
        XCTAssertTrue(fetched.enabledRuleIDs.contains("polish.concise"))
        XCTAssertTrue(fetched.enabledRuleIDs.contains("polish.tone"))
        XCTAssertFalse(fetched.useWritingSamples)
        XCTAssertEqual(fetched.createdAt, now)

        profile.setEnabledRuleIDs(["polish.tone"])
        profile.customInstructions = "Keep contractions."
        profile.useWritingSamples = true
        try repo.save(profile)

        fetched = try XCTUnwrap(repo.fetch(promptId: polish.id))
        XCTAssertEqual(fetched.enabledRuleIDs, ["polish.tone"])
        XCTAssertEqual(fetched.customInstructions, "Keep contractions.")
        XCTAssertTrue(fetched.useWritingSamples)
        XCTAssertEqual(try repo.fetchAll().count, 1)
    }

    func testDeleteProfile() throws {
        let promptID = UUID()
        let profile = TransformProfile(
            promptId: promptID,
            enabledRuleIDsJSON: "[\"custom.facts\"]"
        )
        try repo.save(profile)

        XCTAssertTrue(try repo.delete(promptId: promptID))
        XCTAssertNil(try repo.fetch(promptId: promptID))
        XCTAssertFalse(try repo.delete(promptId: promptID))
    }
}
