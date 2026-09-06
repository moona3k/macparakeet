import XCTest
@testable import MacParakeetCore

final class PromptMeetingPolicyRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var promptRepository: PromptRepository!
    private var policyRepository: PromptMeetingPolicyRepository!
    private var typeRepository: MeetingTypeRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        promptRepository = PromptRepository(dbQueue: manager.dbQueue)
        policyRepository = PromptMeetingPolicyRepository(dbQueue: manager.dbQueue)
        typeRepository = MeetingTypeRepository(dbQueue: manager.dbQueue)
    }

    func testSetPolicyUpsertsStableScopeAndExactTypeWins() throws {
        let prompt = try XCTUnwrap(try promptRepository.fetchAll().first { $0.category == .result })
        let customer = MeetingType(name: "Customer")
        try typeRepository.save(customer)
        let all = try policyRepository.setAllMeetingsPolicy(
            promptId: prompt.id,
            isAvailable: true,
            isAutoRun: true,
            sortOrder: 4
        )
        let exact = try policyRepository.setPolicy(
            promptId: prompt.id,
            meetingTypeId: customer.id,
            isAvailable: false,
            isAutoRun: true,
            sortOrder: 8
        )

        let updated = try policyRepository.setPolicy(
            promptId: prompt.id,
            meetingTypeId: customer.id,
            isAvailable: true,
            isAutoRun: false,
            sortOrder: 9
        )

        XCTAssertEqual(updated.id, exact.id)
        XCTAssertEqual(try policyRepository.fetchPolicies(promptId: prompt.id).count, 2)
        XCTAssertEqual(
            try policyRepository.fetchEffectivePolicy(
                promptId: prompt.id,
                meetingTypeId: customer.id
            )?.id, exact.id)
        XCTAssertEqual(
            try policyRepository.fetchEffectivePolicy(
                promptId: prompt.id,
                meetingTypeId: nil
            )?.id, all.id)
    }

    func testMigrationBackfillsAllPolicyForEveryExistingResultPrompt() throws {
        let resultPrompts = try promptRepository.fetchAll().filter { $0.category == .result }

        XCTAssertFalse(resultPrompts.isEmpty)
        for prompt in resultPrompts {
            let policies = try policyRepository.fetchPolicies(promptId: prompt.id)
            XCTAssertEqual(policies.count, 1, "Expected one migrated all-meetings rule for \(prompt.name)")
            XCTAssertEqual(policies.first?.scopeKind, .all)
            XCTAssertNil(policies.first?.meetingTypeId)
            XCTAssertTrue(policies.first?.isAvailable == true)
            XCTAssertEqual(policies.first?.isAutoRun, prompt.autoRuns(for: .meeting))
        }
    }

    func testCreatingResultPromptAlsoCreatesDefaultMeetingPolicy() throws {
        let prompt = Prompt(
            name: "Customer follow-up",
            content: "Extract follow-up items.",
            isAutoRun: true,
            sortOrder: 42,
            appliesToSources: [.meeting]
        )

        _ = try PromptEditingService(dbQueue: manager.dbQueue).create(prompt)

        let policies = try policyRepository.fetchPolicies(promptId: prompt.id)
        XCTAssertEqual(policies.count, 1)
        XCTAssertEqual(policies.first?.scopeKind, .all)
        XCTAssertTrue(policies.first?.isAvailable == true)
        XCTAssertTrue(policies.first?.isAutoRun == true)
        XCTAssertEqual(policies.first?.sortOrder, 42)
    }

    func testBulkFetchReturnsPoliciesForRequestedPromptsOnly() throws {
        let prompts = Array(try promptRepository.fetchAll().filter { $0.category == .result }.prefix(3))
        XCTAssertEqual(prompts.count, 3)
        let requestedIDs = Set(prompts.prefix(2).map(\.id))

        let policies = try policyRepository.fetchPolicies(promptIds: requestedIDs)

        XCTAssertEqual(Set(policies.map(\.promptId)), requestedIDs)
        XCTAssertFalse(policies.contains { $0.promptId == prompts[2].id })
        XCTAssertTrue(try policyRepository.fetchPolicies(promptIds: []).isEmpty)
    }

    func testUnavailablePolicyCannotAutoRun() throws {
        let prompt = try XCTUnwrap(try promptRepository.fetchAll().first { $0.category == .result })
        let policy = try policyRepository.setAllMeetingsPolicy(
            promptId: prompt.id,
            isAvailable: false,
            isAutoRun: true,
            sortOrder: nil
        )

        XCTAssertFalse(policy.isAvailable)
        XCTAssertFalse(policy.isAutoRun)
    }

    func testRepositoryRejectsInvalidScopeBeforeDatabaseWrite() throws {
        let prompt = try XCTUnwrap(try promptRepository.fetchAll().first { $0.category == .result })
        let invalid = PromptMeetingPolicy(
            promptId: prompt.id,
            scopeKind: .all,
            meetingTypeId: UUID(),
            isAvailable: true,
            isAutoRun: false
        )

        XCTAssertThrowsError(try policyRepository.save(invalid)) { error in
            XCTAssertEqual(error as? MeetingClassificationRepositoryError, .invalidPolicyScope)
        }
    }
}
