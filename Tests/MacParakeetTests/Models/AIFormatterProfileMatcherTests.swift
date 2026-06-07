import XCTest
@testable import MacParakeetCore

final class AIFormatterProfileMatcherTests: XCTestCase {
    func testSmartDefaultTemplatesIncludeTranscriptPlaceholder() {
        XCTAssertFalse(AIFormatterSmartDefaults.categoryDefaults.isEmpty)

        for categoryDefault in AIFormatterSmartDefaults.categoryDefaults {
            XCTAssertTrue(
                categoryDefault.promptTemplate.contains(AIFormatter.transcriptPlaceholder),
                "\(categoryDefault.name) smart default is missing the transcript placeholder"
            )
        }
    }

    func testSmartDefaultsDoNotIncludeOtherCategory() {
        XCTAssertNil(AIFormatterSmartDefaults.categoryDefault(for: .other))
    }

    func testSmartDefaultsCoverEveryConcreteCategory() {
        let expected = Set(TelemetryAppCategory.allCases.filter { $0 != .other })
        let actual = Set(AIFormatterSmartDefaults.categoryDefaults.map(\.category))

        XCTAssertEqual(actual, expected)
    }

    func testExactAppBeatsCategory() {
        let category = AIFormatterProfile.category(
            name: "Messaging",
            appCategory: .messaging,
            promptTemplate: "Messaging prompt"
        )
        let slack = AIFormatterProfile.exactApp(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            promptTemplate: "Slack prompt"
        )

        let context = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )

        XCTAssertEqual(
            AIFormatterProfileMatcher.match(profiles: [category, slack], context: context),
            slack
        )
    }

    func testCategoryProfileMatchesWhenNoExactProfileExists() {
        let terminal = AIFormatterProfile.category(
            name: "Terminal",
            appCategory: .terminal,
            promptTemplate: "Preserve command names"
        )
        let context = AppPromptContext(
            bundleIdentifier: "com.googlecode.iterm2",
            displayName: "iTerm2"
        )

        XCTAssertEqual(
            AIFormatterProfileMatcher.match(profiles: [terminal], context: context),
            terminal
        )
    }

    func testResolveUsesBuiltInCategoryDefaultWhenNoCustomProfileExists() {
        let context = AppPromptContext(
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )

        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [],
            context: context,
            globalPromptTemplate: "Global prompt"
        )

        XCTAssertEqual(resolution.matchKind, .category)
        XCTAssertEqual(resolution.profileName, "Email")
        XCTAssertEqual(resolution.profileOrigin, .template)
        XCTAssertNil(resolution.profileID)
        XCTAssertTrue(resolution.promptTemplate.contains("email-ready text"))
    }

    func testCustomCategoryBeatsBuiltInCategoryDefault() {
        let custom = AIFormatterProfile.category(
            name: "My Email",
            appCategory: .email,
            promptTemplate: "My custom email prompt"
        )
        let context = AppPromptContext(bundleIdentifier: "com.apple.mail")

        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [custom],
            context: context,
            globalPromptTemplate: "Global prompt"
        )

        XCTAssertEqual(resolution.promptTemplate, "My custom email prompt")
        XCTAssertEqual(resolution.profileID, custom.id)
        XCTAssertEqual(resolution.profileName, "My Email")
        XCTAssertEqual(resolution.profileOrigin, .custom)
    }

    func testResolveCustomExactAppBeatsCategoryAndBuiltInDefault() {
        let category = AIFormatterProfile.category(
            name: "Team Messaging",
            appCategory: .messaging,
            promptTemplate: "Team messaging prompt"
        )
        let slack = AIFormatterProfile.exactApp(
            name: "Slack Casual",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            promptTemplate: "Slack prompt"
        )
        let context = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )

        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [category, slack],
            context: context,
            globalPromptTemplate: "Global prompt"
        )

        XCTAssertEqual(resolution.matchKind, .exactApp)
        XCTAssertEqual(resolution.promptTemplate, "Slack prompt")
        XCTAssertEqual(resolution.profileID, slack.id)
        XCTAssertEqual(resolution.profileName, "Slack Casual")
        XCTAssertEqual(resolution.profileOrigin, .custom)
    }

    func testOtherCategoryFallsBackToGlobalPrompt() {
        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [],
            context: AppPromptContext(bundleIdentifier: "com.example.privateapp"),
            globalPromptTemplate: "Global prompt"
        )

        XCTAssertEqual(resolution.promptTemplate, "Global prompt")
        XCTAssertEqual(resolution.matchKind, .global)
        XCTAssertNil(resolution.profileID)
        XCTAssertNil(resolution.profileName)
        XCTAssertNil(resolution.profileOrigin)
    }

    func testDisabledProfilesAreIgnored() {
        let disabled = AIFormatterProfile.exactApp(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            promptTemplate: "Slack prompt",
            isEnabled: false
        )
        let context = AppPromptContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack"
        )

        XCTAssertNil(AIFormatterProfileMatcher.match(profiles: [disabled], context: context))
    }

    func testBundleMatchingIsNormalized() {
        let profile = AIFormatterProfile.exactApp(
            name: "Mail",
            bundleIdentifier: " COM.APPLE.MAIL ",
            promptTemplate: "Email prompt"
        )
        let context = AppPromptContext(bundleIdentifier: "com.apple.mail")

        XCTAssertEqual(profile.bundleIdentifier, "com.apple.mail")
        XCTAssertEqual(
            AIFormatterProfileMatcher.match(profiles: [profile], context: context),
            profile
        )
    }

    func testNilBundleContextCanStillMatchOtherCategory() {
        let other = AIFormatterProfile.category(
            name: "Other",
            appCategory: .other,
            promptTemplate: "Fallback category prompt"
        )

        XCTAssertEqual(
            AIFormatterProfileMatcher.match(
                profiles: [other],
                context: AppPromptContext(bundleIdentifier: nil)
            ),
            other
        )
    }

    func testResolveFallsBackToGlobalPrompt() {
        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [],
            context: nil,
            globalPromptTemplate: "Global prompt"
        )

        XCTAssertEqual(resolution.promptTemplate, "Global prompt")
        XCTAssertEqual(resolution.matchKind, .global)
        XCTAssertNil(resolution.profileID)
        XCTAssertNil(resolution.profileName)
        XCTAssertNil(resolution.profileOrigin)
    }
}
