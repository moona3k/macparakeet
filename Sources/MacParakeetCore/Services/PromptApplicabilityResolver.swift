import Foundation

public struct PromptApplicabilityResolution: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case hidden
        case notResultPrompt
        case nonMeetingSource
        case exactMeetingTypePolicy
        case allMeetingsPolicy
        case noMatchingMeetingPolicy
    }

    public var isAvailable: Bool
    public var isAutoRun: Bool
    public var effectiveSortOrder: Int
    public var matchedPolicyId: UUID?
    public var reason: Reason

    public init(
        isAvailable: Bool,
        isAutoRun: Bool,
        effectiveSortOrder: Int,
        matchedPolicyId: UUID?,
        reason: Reason
    ) {
        self.isAvailable = isAvailable
        self.isAutoRun = isAvailable && isAutoRun
        self.effectiveSortOrder = effectiveSortOrder
        self.matchedPolicyId = matchedPolicyId
        self.reason = reason
    }
}

public struct PromptApplicabilityResolver: Sendable {
    private let policyRepository: (any PromptMeetingPolicyRepositoryProtocol)?

    public init(policyRepository: (any PromptMeetingPolicyRepositoryProtocol)? = nil) {
        self.policyRepository = policyRepository
    }

    public func resolve(
        prompt: Prompt,
        sourceType: Transcription.SourceType,
        meetingTypeId: UUID?
    ) throws -> PromptApplicabilityResolution {
        let policies: [PromptMeetingPolicy]
        if sourceType == .meeting {
            guard let policyRepository else {
                policies = []
                return Self.resolve(
                    prompt: prompt,
                    sourceType: sourceType,
                    meetingTypeId: meetingTypeId,
                    policies: policies
                )
            }
            policies = try policyRepository.fetchPolicies(promptId: prompt.id)
        } else {
            policies = []
        }
        return Self.resolve(
            prompt: prompt,
            sourceType: sourceType,
            meetingTypeId: meetingTypeId,
            policies: policies
        )
    }

    public static func resolve(
        prompt: Prompt,
        sourceType: Transcription.SourceType,
        meetingTypeId: UUID?,
        policies: [PromptMeetingPolicy]
    ) -> PromptApplicabilityResolution {
        guard prompt.isVisible else {
            return unavailable(prompt: prompt, reason: .hidden)
        }
        guard prompt.category == .result else {
            return unavailable(prompt: prompt, reason: .notResultPrompt)
        }

        guard sourceType == .meeting else {
            return PromptApplicabilityResolution(
                isAvailable: true,
                isAutoRun: prompt.autoRuns(for: sourceType),
                effectiveSortOrder: prompt.sortOrder,
                matchedPolicyId: nil,
                reason: .nonMeetingSource
            )
        }

        let exact = meetingTypeId.flatMap { typeId in
            policies.first { $0.scopeKind == .type && $0.meetingTypeId == typeId }
        }
        let all = policies.first { $0.scopeKind == .all && $0.meetingTypeId == nil }
        guard let policy = exact ?? all else {
            return unavailable(prompt: prompt, reason: .noMatchingMeetingPolicy)
        }
        return PromptApplicabilityResolution(
            isAvailable: policy.isAvailable,
            isAutoRun: policy.isAutoRun,
            effectiveSortOrder: policy.sortOrder ?? prompt.sortOrder,
            matchedPolicyId: policy.id,
            reason: exact == nil ? .allMeetingsPolicy : .exactMeetingTypePolicy
        )
    }

    private static func unavailable(
        prompt: Prompt,
        reason: PromptApplicabilityResolution.Reason
    ) -> PromptApplicabilityResolution {
        PromptApplicabilityResolution(
            isAvailable: false,
            isAutoRun: false,
            effectiveSortOrder: prompt.sortOrder,
            matchedPolicyId: nil,
            reason: reason
        )
    }
}
