import XCTest
@testable import MacParakeetCore

final class PromptLabelApplicabilityResolverTests: XCTestCase {
    func testNoTargetingMakesPromptAvailableForEverySource() {
        let prompt = Prompt(
            name: "Summary",
            content: "Summarize",
            isAutoRun: true,
            appliesToSources: [.youtube]
        )

        let file = PromptLabelApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .file,
            transcriptionLabelIDs: [],
            policies: []
        )
        let podcast = PromptLabelApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .youtube,
            transcriptionLabelIDs: [],
            policies: []
        )

        XCTAssertTrue(file.isAvailable)
        XCTAssertFalse(file.isAutoRun)
        XCTAssertTrue(podcast.isAvailable)
        XCTAssertTrue(podcast.isAutoRun)
    }

    func testAnyMatchingLabelMakesRestrictedPromptAvailable() {
        let prompt = Prompt(name: "Follow-up", content: "Draft", isAutoRun: true)
        let customer = UUID()
        let hiring = UUID()
        let policies = [
            PromptLabelPolicy(promptId: prompt.id, scopeKind: .all, isAvailable: false),
            PromptLabelPolicy(
                promptId: prompt.id,
                scopeKind: .label,
                labelId: customer,
                isAvailable: true
            ),
            PromptLabelPolicy(
                promptId: prompt.id,
                scopeKind: .label,
                labelId: hiring,
                isAvailable: true
            ),
        ]

        let matching = PromptLabelApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .meeting,
            transcriptionLabelIDs: [UUID(), hiring],
            policies: policies
        )
        let missing = PromptLabelApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .meeting,
            transcriptionLabelIDs: [UUID()],
            policies: policies
        )

        XCTAssertTrue(matching.isAvailable)
        XCTAssertTrue(matching.isAutoRun)
        XCTAssertEqual(matching.reason, .matchingLabelPolicy)
        XCTAssertFalse(missing.isAvailable)
        XCTAssertFalse(missing.isAutoRun)
        XCTAssertEqual(missing.reason, .allLabelsPolicy)
    }

    func testMatchingRulesUseOrSemantics() {
        let prompt = Prompt(name: "Summary", content: "Summarize")
        let first = UUID()
        let second = UUID()
        let resolution = PromptLabelApplicabilityResolver.resolve(
            prompt: prompt,
            sourceType: .file,
            transcriptionLabelIDs: [first, second],
            policies: [
                PromptLabelPolicy(
                    promptId: prompt.id,
                    scopeKind: .label,
                    labelId: first,
                    isAvailable: false
                ),
                PromptLabelPolicy(
                    promptId: prompt.id,
                    scopeKind: .label,
                    labelId: second,
                    isAvailable: true
                ),
            ]
        )

        XCTAssertTrue(resolution.isAvailable)
    }
}
