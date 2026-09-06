import XCTest
import GRDB
@testable import MacParakeetCore

final class PromptLabelPolicyRepositoryTests: XCTestCase {
    func testReplaceTargetLabelsWritesRestrictedFallbackAndSelectedLabels() throws {
        let manager = try DatabaseManager()
        let prompt = try XCTUnwrap(
            try PromptRepository(dbQueue: manager.dbQueue).fetchAll().first { $0.category == .result }
        )
        let labelRepository = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let first = MeetingLabel(name: "Customer")
        let second = MeetingLabel(name: "Hiring")
        try labelRepository.save(first)
        try labelRepository.save(second)
        let repository = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)

        try repository.replaceTargetLabels(promptId: prompt.id, labelIds: [first.id, second.id])

        let policies = try repository.fetchPolicies(promptId: prompt.id)
        XCTAssertEqual(policies.count, 3)
        XCTAssertEqual(
            policies.first(where: { $0.scopeKind == .all })?.isAvailable,
            false
        )
        XCTAssertEqual(
            Set(policies.compactMap { $0.scopeKind == .label ? $0.labelId : nil }),
            [first.id, second.id]
        )
        XCTAssertTrue(policies.filter { $0.scopeKind == .label }.allSatisfy(\.isAvailable))
    }

    func testEmptyTargetSelectionRestoresDefaultAvailability() throws {
        let manager = try DatabaseManager()
        let prompt = try XCTUnwrap(
            try PromptRepository(dbQueue: manager.dbQueue).fetchAll().first { $0.category == .result }
        )
        let labelRepository = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let label = MeetingLabel(name: "Customer")
        try labelRepository.save(label)
        let repository = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)
        try repository.replaceTargetLabels(promptId: prompt.id, labelIds: [label.id])

        try repository.replaceTargetLabels(promptId: prompt.id, labelIds: [])

        XCTAssertTrue(try repository.fetchPolicies(promptId: prompt.id).isEmpty)
    }

    func testMigrationCopiesLegacyMeetingTypePolicyToMatchingLabel() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v0.37-general-transcription-labels")
        let prompt = try XCTUnwrap(
            try PromptRepository(dbQueue: queue).fetchAll().first { $0.category == .result }
        )
        let meetingType = MeetingType(name: "Customer")
        let label = MeetingLabel(name: "Customer")
        try MeetingTypeRepository(dbQueue: queue).save(meetingType)
        try MeetingLabelRepository(dbQueue: queue).save(label)
        _ = try PromptMeetingPolicyRepository(dbQueue: queue).setPolicy(
            promptId: prompt.id,
            meetingTypeId: meetingType.id,
            isAvailable: true,
            isAutoRun: false,
            sortOrder: nil
        )

        try migrator.migrate(queue)

        let policies = try PromptLabelPolicyRepository(dbQueue: queue).fetchPolicies(promptId: prompt.id)
        XCTAssertEqual(
            policies.first(where: { $0.scopeKind == .label })?.labelId,
            label.id
        )
        XCTAssertEqual(
            policies.first(where: { $0.scopeKind == .label })?.isAvailable,
            true
        )
    }
}
