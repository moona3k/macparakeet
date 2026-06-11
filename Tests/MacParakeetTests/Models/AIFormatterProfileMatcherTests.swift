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

    // MARK: - Smart defaults policy

    func testDisabledSmartDefaultsMasterSwitchRestoresGlobalPrompt() {
        let context = AppPromptContext(bundleIdentifier: "com.apple.mail")

        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [],
            context: context,
            globalPromptTemplate: "Global prompt",
            smartDefaultsPolicy: AIFormatterSmartDefaultsPolicy(isEnabled: false)
        )

        XCTAssertEqual(resolution.promptTemplate, "Global prompt")
        XCTAssertEqual(resolution.matchKind, .global)
    }

    func testDisabledCategorySkipsItsSmartDefaultOnly() {
        let policy = AIFormatterSmartDefaultsPolicy(disabledCategories: [.email])

        let email = AIFormatterProfileMatcher.resolve(
            profiles: [],
            context: AppPromptContext(bundleIdentifier: "com.apple.mail"),
            globalPromptTemplate: "Global prompt",
            smartDefaultsPolicy: policy
        )
        XCTAssertEqual(email.matchKind, .global)
        XCTAssertEqual(email.promptTemplate, "Global prompt")

        let messaging = AIFormatterProfileMatcher.resolve(
            profiles: [],
            context: AppPromptContext(bundleIdentifier: "com.tinyspeck.slackmacgap"),
            globalPromptTemplate: "Global prompt",
            smartDefaultsPolicy: policy
        )
        XCTAssertEqual(messaging.matchKind, .category)
        XCTAssertEqual(messaging.profileOrigin, .template)
        XCTAssertEqual(messaging.profileName, "Messaging")
    }

    func testCustomProfilesStillWinWhenSmartDefaultsAreDisabled() {
        let slack = AIFormatterProfile.exactApp(
            name: "Slack Casual",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            promptTemplate: "Slack prompt"
        )

        let resolution = AIFormatterProfileMatcher.resolve(
            profiles: [slack],
            context: AppPromptContext(bundleIdentifier: "com.tinyspeck.slackmacgap"),
            globalPromptTemplate: "Global prompt",
            smartDefaultsPolicy: AIFormatterSmartDefaultsPolicy(isEnabled: false)
        )

        XCTAssertEqual(resolution.matchKind, .exactApp)
        XCTAssertEqual(resolution.promptTemplate, "Slack prompt")
    }

    func testDisabledCustomCategoryProfileFallsBackToSmartDefaultThenPolicy() {
        let disabledCustom = AIFormatterProfile.category(
            name: "My Email",
            appCategory: .email,
            promptTemplate: "My custom email prompt",
            isEnabled: false
        )
        let context = AppPromptContext(bundleIdentifier: "com.apple.mail")

        let withDefaults = AIFormatterProfileMatcher.resolve(
            profiles: [disabledCustom],
            context: context,
            globalPromptTemplate: "Global prompt",
            smartDefaultsPolicy: .allEnabled
        )
        XCTAssertEqual(withDefaults.matchKind, .category)
        XCTAssertEqual(withDefaults.profileOrigin, .template)

        let withoutDefaults = AIFormatterProfileMatcher.resolve(
            profiles: [disabledCustom],
            context: context,
            globalPromptTemplate: "Global prompt",
            smartDefaultsPolicy: AIFormatterSmartDefaultsPolicy(disabledCategories: [.email])
        )
        XCTAssertEqual(withoutDefaults.matchKind, .global)
        XCTAssertEqual(withoutDefaults.promptTemplate, "Global prompt")
    }

    func testSmartDefaultsPolicyRoundTripsThroughUserDefaults() throws {
        let suiteName = "matcher-policy-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AIFormatterSmartDefaultsPolicy.current(defaults: defaults), .allEnabled)

        let policy = AIFormatterSmartDefaultsPolicy(
            isEnabled: false,
            disabledCategories: [.browser, .terminal]
        )
        policy.save(to: defaults)

        XCTAssertEqual(AIFormatterSmartDefaultsPolicy.current(defaults: defaults), policy)
    }

    func testSortedByPrecedenceOrdersBySortOrderThenNameThenID() {
        let first = AIFormatterProfile.exactApp(
            name: "zebra",
            bundleIdentifier: "com.example.zebra",
            promptTemplate: "p",
            sortOrder: 0
        )
        let second = AIFormatterProfile.exactApp(
            name: "Apple",
            bundleIdentifier: "com.example.apple",
            promptTemplate: "p",
            sortOrder: 1
        )
        let third = AIFormatterProfile.exactApp(
            name: "zoom",
            bundleIdentifier: "com.example.zoom",
            promptTemplate: "p",
            sortOrder: 1
        )

        let sorted = AIFormatterProfileMatcher.sortedByPrecedence([third, second, first])
        XCTAssertEqual(sorted.map(\.name), ["zebra", "Apple", "zoom"])
    }

    // MARK: - Profile prompt resolver

    func testResolverFallsBackToGlobalAndReportsFetchErrors() async {
        struct FetchError: Error {}
        final class ThrowingRepo: AIFormatterProfileRepositoryProtocol, @unchecked Sendable {
            func save(_ profile: AIFormatterProfile) throws {}
            func fetch(id: UUID) throws -> AIFormatterProfile? { nil }
            func fetchAll() throws -> [AIFormatterProfile] { throw FetchError() }
            func fetchEnabled() throws -> [AIFormatterProfile] { throw FetchError() }
            func delete(id: UUID) throws -> Bool { false }
        }

        let reportedErrors = LockedErrorCollector()
        let resolver = AIFormatterProfilePromptResolver(
            profileRepository: ThrowingRepo(),
            globalPromptTemplate: { "Global prompt" },
            onFetchError: { reportedErrors.append($0) }
        )

        let resolution = await resolver.resolvePrompt(
            for: AppPromptContext(bundleIdentifier: "com.apple.mail")
        )

        XCTAssertEqual(resolution.matchKind, .global)
        XCTAssertEqual(resolution.promptTemplate, "Global prompt")
        XCTAssertEqual(reportedErrors.count, 1)
    }

    func testResolverUsesGlobalPromptForNilContextWithoutTouchingRepository() async {
        final class CountingRepo: AIFormatterProfileRepositoryProtocol, @unchecked Sendable {
            let fetches = LockedErrorCollector()
            func save(_ profile: AIFormatterProfile) throws {}
            func fetch(id: UUID) throws -> AIFormatterProfile? { nil }
            func fetchAll() throws -> [AIFormatterProfile] { [] }
            func fetchEnabled() throws -> [AIFormatterProfile] {
                fetches.append(NSError(domain: "fetch", code: 0))
                return []
            }
            func delete(id: UUID) throws -> Bool { false }
        }

        let repo = CountingRepo()
        let resolver = AIFormatterProfilePromptResolver(
            profileRepository: repo,
            globalPromptTemplate: { "Global prompt" }
        )

        let resolution = await resolver.resolvePrompt(for: nil)

        XCTAssertEqual(resolution.matchKind, .global)
        XCTAssertEqual(repo.fetches.count, 0)
    }

    func testResolverRespectsSmartDefaultsPolicyClosure() async {
        final class EmptyRepo: AIFormatterProfileRepositoryProtocol, @unchecked Sendable {
            func save(_ profile: AIFormatterProfile) throws {}
            func fetch(id: UUID) throws -> AIFormatterProfile? { nil }
            func fetchAll() throws -> [AIFormatterProfile] { [] }
            func fetchEnabled() throws -> [AIFormatterProfile] { [] }
            func delete(id: UUID) throws -> Bool { false }
        }

        let resolver = AIFormatterProfilePromptResolver(
            profileRepository: EmptyRepo(),
            globalPromptTemplate: { "Global prompt" },
            smartDefaultsPolicy: { AIFormatterSmartDefaultsPolicy(isEnabled: false) }
        )

        let resolution = await resolver.resolvePrompt(
            for: AppPromptContext(bundleIdentifier: "com.apple.mail")
        )

        XCTAssertEqual(resolution.matchKind, .global)
        XCTAssertEqual(resolution.promptTemplate, "Global prompt")
    }
}

/// Minimal thread-safe error collector for resolver callback assertions.
private final class LockedErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return errors.count
    }
}
