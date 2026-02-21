import Foundation
import os

public enum TextRefinementPath: String, Sendable {
    case raw
    case deterministic
    case llm
    case llmFallback
}

public struct TextRefinementResult: Sendable {
    public let text: String?
    public let expandedSnippetIDs: Set<UUID>
    public let path: TextRefinementPath
    public let fallbackReason: String?

    public init(
        text: String?,
        expandedSnippetIDs: Set<UUID>,
        path: TextRefinementPath,
        fallbackReason: String? = nil
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.path = path
        self.fallbackReason = fallbackReason
    }
}

public struct TextRefinementService: Sendable {
    public typealias OptionsProvider = @Sendable (Dictation.ProcessingMode) -> LLMGenerationOptions
    public static let defaultOptionsProvider: OptionsProvider = { mode in
        switch mode {
        case .formal, .email, .code:
            return LLMGenerationOptions(
                temperature: 0.7,
                topP: 0.8,
                maxTokens: 512,
                timeoutSeconds: 45
            )
        case .raw, .clean:
            return LLMGenerationOptions()
        }
    }

    private let llmService: (any LLMServiceProtocol)?
    private let optionsProvider: OptionsProvider
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "TextRefinement")

    public init(
        llmService: (any LLMServiceProtocol)? = nil,
        optionsProvider: @escaping OptionsProvider = TextRefinementService.defaultOptionsProvider
    ) {
        self.llmService = llmService
        self.optionsProvider = optionsProvider
    }

    public func refine(
        rawText: String,
        mode: Dictation.ProcessingMode,
        customWords: [CustomWord],
        snippets: [TextSnippet]
    ) async -> TextRefinementResult {
        guard mode.usesDeterministicPipeline else {
            return TextRefinementResult(
                text: nil,
                expandedSnippetIDs: [],
                path: .raw
            )
        }

        let deterministic = TextProcessingPipeline().process(
            text: rawText,
            customWords: customWords,
            snippets: snippets
        )
        let deterministicTrimmed = deterministic.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !deterministicTrimmed.isEmpty else {
            return TextRefinementResult(
                text: deterministic.text,
                expandedSnippetIDs: deterministic.expandedSnippetIDs,
                path: .deterministic
            )
        }

        guard mode.usesLLMRefinement, let refinementMode = mode.llmRefinementMode else {
            return TextRefinementResult(
                text: deterministic.text,
                expandedSnippetIDs: deterministic.expandedSnippetIDs,
                path: .deterministic
            )
        }

        guard let llmService else {
            return fallback(
                deterministic: deterministic,
                reason: "LLM service not configured"
            )
        }

        let task = LLMTask.refine(mode: refinementMode, input: deterministic.text)
        let request = LLMRequest(
            prompt: LLMPromptBuilder.userPrompt(for: task),
            systemPrompt: LLMPromptBuilder.systemPrompt(for: task),
            options: optionsProvider(mode)
        )

        do {
            let response = try await llmService.generate(request: request)
            let refined = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !refined.isEmpty else {
                return fallback(deterministic: deterministic, reason: "LLM output was empty")
            }

            guard !Self.hasAssistantPreamble(refined) else {
                return fallback(deterministic: deterministic, reason: "LLM output contained assistant preamble")
            }

            return TextRefinementResult(
                text: refined,
                expandedSnippetIDs: deterministic.expandedSnippetIDs,
                path: .llm
            )
        } catch {
            return fallback(deterministic: deterministic, reason: error.localizedDescription)
        }
    }

    private func fallback(deterministic: TextProcessingResult, reason: String) -> TextRefinementResult {
        logger.notice("LLM refinement fallback applied: \(reason, privacy: .public)")
        return TextRefinementResult(
            text: deterministic.text,
            expandedSnippetIDs: deterministic.expandedSnippetIDs,
            path: .llmFallback,
            fallbackReason: reason
        )
    }

    /// Detect preamble chatter (e.g. "Certainly! Here's a formal version:") so callers can fall back
    /// instead of mutating generated text heuristically.
    static func hasAssistantPreamble(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed
        guard let colonIndex = firstLine.firstIndex(of: ":") else { return false }

        let prefix = firstLine[..<colonIndex]
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hasIntroCue = prefix.contains("here's")
            || prefix.contains("here is")
            || prefix.contains("here are")
            || prefix.hasPrefix("certainly")
            || prefix.hasPrefix("sure")
            || prefix.hasPrefix("of course")
            || prefix.hasPrefix("absolutely")

        guard hasIntroCue else { return false }

        let rewriteMarkers = [
            "rewritten",
            "rewrite",
            "revised",
            "refined",
            "improved",
            "edited",
            "corrected",
            "formal version",
            "polished",
            "professional tone",
            "your text",
            "your message",
            "your email",
        ]
        return rewriteMarkers.contains { prefix.contains($0) }
    }

    public static func defaultOptions(for mode: Dictation.ProcessingMode) -> LLMGenerationOptions {
        defaultOptionsProvider(mode)
    }
}
