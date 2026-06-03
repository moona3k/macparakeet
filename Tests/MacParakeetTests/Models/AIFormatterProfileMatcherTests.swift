import XCTest
@testable import MacParakeetCore

final class AIFormatterProfileMatcherTests: XCTestCase {
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
            context: AppPromptContext(bundleIdentifier: "com.apple.mail"),
            globalPromptTemplate: "Global prompt"
        )

        XCTAssertEqual(resolution.promptTemplate, "Global prompt")
        XCTAssertEqual(resolution.matchKind, .global)
        XCTAssertNil(resolution.profileID)
    }
}
