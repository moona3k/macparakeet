import Foundation

/// Resolves which visible `.result` prompts are available and which of
/// those auto-run, using the same label-policy / meeting-type-policy /
/// legacy-source precedence the GUI prompt picker and auto-generation path
/// already apply. Extracted so a Core completion service (and the GUI
/// view model) share one selection behavior instead of two.
public enum PromptAutoRunSelector {
    public struct Resolved: Sendable {
        public let prompt: Prompt
        public let isAutoRun: Bool
        public let effectiveSortOrder: Int
    }

    /// `promptLabelPolicyRepository` wins when configured (current policy
    /// model). Otherwise a meeting-type policy resolver applies to meeting
    /// sources, and any remaining case falls back to each prompt's own
    /// `appliesToSources`/`isAutoRun` fields.
    public static func resolve(
        prompts: [Prompt],
        sourceType: Transcription.SourceType?,
        meetingTypeId: UUID?,
        transcriptionLabelIDs: Set<UUID>,
        promptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol?,
        promptApplicabilityResolver: PromptApplicabilityResolver?
    ) throws -> [Resolved] {
        guard let sourceType else {
            return prompts.map {
                Resolved(prompt: $0, isAutoRun: $0.isAutoRun, effectiveSortOrder: $0.sortOrder)
            }
        }

        if let promptLabelPolicyRepository {
            let policies = try promptLabelPolicyRepository.fetchPolicies(promptIds: Set(prompts.map(\.id)))
            let policiesByPromptID = Dictionary(grouping: policies, by: \.promptId)
            return prompts.compactMap { prompt in
                let resolution = PromptLabelApplicabilityResolver.resolve(
                    prompt: prompt,
                    sourceType: sourceType,
                    transcriptionLabelIDs: transcriptionLabelIDs,
                    policies: policiesByPromptID[prompt.id] ?? []
                )
                guard resolution.isAvailable else { return nil }
                return Resolved(
                    prompt: prompt,
                    isAutoRun: resolution.isAutoRun,
                    effectiveSortOrder: prompt.sortOrder
                )
            }.sorted(by: ordering)
        }

        guard sourceType == .meeting, let promptApplicabilityResolver else {
            return prompts.map {
                Resolved(
                    prompt: $0,
                    isAutoRun: $0.autoRuns(for: sourceType),
                    effectiveSortOrder: $0.sortOrder
                )
            }
        }
        return try prompts.compactMap { prompt in
            let resolution = try promptApplicabilityResolver.resolve(
                prompt: prompt,
                sourceType: .meeting,
                meetingTypeId: meetingTypeId
            )
            return resolution.isAvailable
                ? Resolved(
                    prompt: prompt,
                    isAutoRun: resolution.isAutoRun,
                    effectiveSortOrder: resolution.effectiveSortOrder
                )
                : nil
        }.sorted(by: ordering)
    }

    /// Convenience for callers that only need the auto-run subset, already
    /// filtered and stripped down to `Prompt` values.
    public static func autoRunPrompts(
        prompts: [Prompt],
        sourceType: Transcription.SourceType?,
        meetingTypeId: UUID?,
        transcriptionLabelIDs: Set<UUID>,
        promptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol?,
        promptApplicabilityResolver: PromptApplicabilityResolver?
    ) throws -> [Prompt] {
        try resolve(
            prompts: prompts,
            sourceType: sourceType,
            meetingTypeId: meetingTypeId,
            transcriptionLabelIDs: transcriptionLabelIDs,
            promptLabelPolicyRepository: promptLabelPolicyRepository,
            promptApplicabilityResolver: promptApplicabilityResolver
        ).filter(\.isAutoRun).map(\.prompt)
    }

    private static func ordering(_ lhs: Resolved, _ rhs: Resolved) -> Bool {
        if lhs.effectiveSortOrder != rhs.effectiveSortOrder { return lhs.effectiveSortOrder < rhs.effectiveSortOrder }
        let nameOrder = lhs.prompt.name.localizedCaseInsensitiveCompare(rhs.prompt.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.prompt.id.uuidString < rhs.prompt.id.uuidString
    }
}
