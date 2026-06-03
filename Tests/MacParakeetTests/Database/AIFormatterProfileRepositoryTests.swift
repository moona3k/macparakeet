import XCTest
@testable import MacParakeetCore

final class AIFormatterProfileRepositoryTests: XCTestCase {
    private var repo: AIFormatterProfileRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = AIFormatterProfileRepository(dbQueue: manager.dbQueue)
    }

    func testSaveAndFetchExactAppProfileNormalizesBundleID() throws {
        let profile = AIFormatterProfile.exactApp(
            name: " Slack Casual ",
            bundleIdentifier: " COM.TINYSPECK.SLACKMACGAP ",
            appDisplayName: " Slack ",
            promptTemplate: "Keep it casual:\n{{TRANSCRIPT}}"
        )

        try repo.save(profile)

        let fetched = try XCTUnwrap(repo.fetch(id: profile.id))
        XCTAssertEqual(fetched.name, "Slack Casual")
        XCTAssertEqual(fetched.targetKind, .bundle)
        XCTAssertEqual(fetched.bundleIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(fetched.appDisplayName, "Slack")
        XCTAssertNil(fetched.appCategory)
        XCTAssertEqual(fetched.promptTemplate, "Keep it casual:\n{{TRANSCRIPT}}")
    }

    func testSaveAndFetchCategoryProfileClearsBundleFields() throws {
        let profile = AIFormatterProfile(
            name: "Terminal",
            targetKind: .category,
            bundleIdentifier: "com.apple.Terminal",
            appDisplayName: "Terminal",
            appCategory: .terminal,
            promptTemplate: "Preserve command names"
        )

        try repo.save(profile)

        let fetched = try XCTUnwrap(repo.fetch(id: profile.id))
        XCTAssertEqual(fetched.targetKind, .category)
        XCTAssertNil(fetched.bundleIdentifier)
        XCTAssertNil(fetched.appDisplayName)
        XCTAssertEqual(fetched.appCategory, .terminal)
    }

    func testFetchEnabledFiltersDisabledProfiles() throws {
        let enabled = AIFormatterProfile.category(
            name: "Email",
            appCategory: .email,
            promptTemplate: "Professional email"
        )
        let disabled = AIFormatterProfile.category(
            name: "Messaging",
            appCategory: .messaging,
            promptTemplate: "Casual chat",
            isEnabled: false
        )

        try repo.save(enabled)
        try repo.save(disabled)

        let profiles = try repo.fetchEnabled()
        XCTAssertEqual(profiles.map(\.id), [enabled.id])
    }

    func testDuplicateExactAppProfilesThrow() throws {
        try repo.save(AIFormatterProfile.exactApp(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            promptTemplate: "A"
        ))

        XCTAssertThrowsError(try repo.save(AIFormatterProfile.exactApp(
            name: "Slack 2",
            bundleIdentifier: "COM.TINYSPECK.SLACKMACGAP",
            promptTemplate: "B"
        ))) { error in
            XCTAssertEqual(
                error as? AIFormatterProfileRepositoryError,
                .duplicateExactApp("com.tinyspeck.slackmacgap")
            )
        }
    }

    func testDuplicateCategoryProfilesThrow() throws {
        try repo.save(AIFormatterProfile.category(
            name: "Email",
            appCategory: .email,
            promptTemplate: "A"
        ))

        XCTAssertThrowsError(try repo.save(AIFormatterProfile.category(
            name: "Email 2",
            appCategory: .email,
            promptTemplate: "B"
        ))) { error in
            XCTAssertEqual(error as? AIFormatterProfileRepositoryError, .duplicateCategory(.email))
        }
    }

    func testDeleteRemovesProfile() throws {
        let profile = AIFormatterProfile.category(
            name: "Email",
            appCategory: .email,
            promptTemplate: "Professional"
        )
        try repo.save(profile)

        XCTAssertTrue(try repo.delete(id: profile.id))
        XCTAssertNil(try repo.fetch(id: profile.id))
    }
}
