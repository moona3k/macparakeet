import XCTest
@testable import MacParakeetCore

final class PromptApplicabilityResolverTests: XCTestCase {
    func testExactTypePolicyOverridesAllPolicy() {
        let prompt = Prompt(name: "Notes", content: "Summarize", isAutoRun: true)
        let typeID = UUID()
        let all = PromptMeetingPolicy.allMeetings(
            promptId: prompt.id,
            isAvailable: true,
            isAutoRun: true
        )
        let exact = PromptMeetingPolicy.meetingType(
            promptId: prompt.id,
            meetingTypeId: typeID,
            isAvailable: false,
            isAutoRun: true
        )

        let resolution = PromptApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .meeting,
            meetingTypeId: typeID,
            policies: [all, exact]
        )

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertFalse(resolution.isAutoRun)
        XCTAssertEqual(resolution.matchedPolicyId, exact.id)
        XCTAssertEqual(resolution.reason, .exactMeetingTypePolicy)
    }

    func testUnclassifiedMeetingFallsBackToAllPolicy() {
        let prompt = Prompt(name: "Notes", content: "Summarize")
        let all = PromptMeetingPolicy.allMeetings(
            promptId: prompt.id,
            isAvailable: true,
            isAutoRun: false,
            sortOrder: 7
        )

        let resolution = PromptApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .meeting,
            meetingTypeId: nil,
            policies: [all]
        )

        XCTAssertTrue(resolution.isAvailable)
        XCTAssertFalse(resolution.isAutoRun)
        XCTAssertEqual(resolution.effectiveSortOrder, 7)
        XCTAssertEqual(resolution.reason, .allMeetingsPolicy)
    }

    func testNoMeetingPolicyMeansUnavailable() {
        let prompt = Prompt(name: "Notes", content: "Summarize", isAutoRun: true)

        let resolution = PromptApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .meeting,
            meetingTypeId: UUID(),
            policies: []
        )

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertFalse(resolution.isAutoRun)
        XCTAssertEqual(resolution.reason, .noMatchingMeetingPolicy)
    }

    func testNonMeetingSourceIgnoresMeetingPolicies() {
        let prompt = Prompt(
            name: "Notes",
            content: "Summarize",
            isAutoRun: true,
            appliesToSources: [.file]
        )
        let unavailable = PromptMeetingPolicy.allMeetings(
            promptId: prompt.id,
            isAvailable: false,
            isAutoRun: false
        )

        let fileResolution = PromptApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .file,
            meetingTypeId: nil,
            policies: [unavailable]
        )
        let youtubeResolution = PromptApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .youtube,
            meetingTypeId: nil,
            policies: [unavailable]
        )

        XCTAssertTrue(fileResolution.isAvailable)
        XCTAssertTrue(fileResolution.isAutoRun)
        XCTAssertTrue(youtubeResolution.isAvailable)
        XCTAssertFalse(youtubeResolution.isAutoRun)
    }

    func testHiddenPromptIsAlwaysUnavailable() {
        let prompt = Prompt(name: "Notes", content: "Summarize", isVisible: false, isAutoRun: true)
        let policy = PromptMeetingPolicy.allMeetings(
            promptId: prompt.id,
            isAvailable: true,
            isAutoRun: true
        )

        let resolution = PromptApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .meeting,
            meetingTypeId: nil,
            policies: [policy]
        )

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertFalse(resolution.isAutoRun)
        XCTAssertEqual(resolution.reason, .hidden)
    }
}
