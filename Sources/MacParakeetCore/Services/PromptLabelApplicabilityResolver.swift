import Foundation

public struct PromptLabelApplicabilityResolution: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case hidden
        case notResultPrompt
        case noLabelTargeting
        case matchingLabelPolicy
        case allLabelsPolicy
        case noMatchingLabelPolicy
    }

    public var isAvailable: Bool
    public var isAutoRun: Bool
    public var reason: Reason

    public init(isAvailable: Bool, isAutoRun: Bool, reason: Reason) {
        self.isAvailable = isAvailable
        self.isAutoRun = isAvailable && isAutoRun
        self.reason = reason
    }
}

public enum PromptLabelApplicabilityResolver {
    public static func resolve(
        prompt: Prompt,
        sourceType: Transcription.SourceType,
        transcriptionLabelIDs: Set<UUID>,
        policies: [PromptLabelPolicy]
    ) -> PromptLabelApplicabilityResolution {
        guard prompt.isVisible else {
            return unavailable(prompt: prompt, reason: .hidden)
        }
        guard prompt.category == .result else {
            return unavailable(prompt: prompt, reason: .notResultPrompt)
        }

        guard !policies.isEmpty else {
            return PromptLabelApplicabilityResolution(
                isAvailable: true,
                isAutoRun: prompt.autoRuns(for: sourceType),
                reason: .noLabelTargeting
            )
        }

        let matching = policies.filter {
            $0.scopeKind == .label
                && $0.labelId.map(transcriptionLabelIDs.contains) == true
        }
        if !matching.isEmpty {
            let available = matching.contains(where: \.isAvailable)
            return PromptLabelApplicabilityResolution(
                isAvailable: available,
                isAutoRun: available && prompt.autoRuns(for: sourceType),
                reason: .matchingLabelPolicy
            )
        }

        if let fallback = policies.first(where: { $0.scopeKind == .all && $0.labelId == nil }) {
            return PromptLabelApplicabilityResolution(
                isAvailable: fallback.isAvailable,
                isAutoRun: fallback.isAvailable && prompt.autoRuns(for: sourceType),
                reason: .allLabelsPolicy
            )
        }
        return unavailable(prompt: prompt, reason: .noMatchingLabelPolicy)
    }

    private static func unavailable(
        prompt: Prompt,
        reason: PromptLabelApplicabilityResolution.Reason
    ) -> PromptLabelApplicabilityResolution {
        PromptLabelApplicabilityResolution(
            isAvailable: false,
            isAutoRun: false,
            reason: reason
        )
    }
}
