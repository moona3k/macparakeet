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
            let refined = Self.stripPreamble(response.text)

            guard !refined.isEmpty else {
                return fallback(deterministic: deterministic, reason: "LLM output was empty")
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

    /// Strip common LLM preamble patterns (e.g. "Certainly! Here's a formal version:\n\n")
    /// and surrounding quotes that Qwen3 sometimes adds.
    static func stripPreamble(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip preamble lines like "Certainly! Here's..." or "Here is..." followed by a colon
        let preamblePatterns: [String] = [
            "(?i)^(certainly|sure|of course|absolutely)[!.]?\\s*",
            "(?i)^here(?:'s| is| are)\\s+[^\\n]*:\\s*",
            "(?i)^a more \\w+ version[^\\n]*:\\s*",
        ]
        for pattern in preamblePatterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result = String(result[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip wrapping quotes (single pass)
        if result.count >= 2 {
            let first = result.first!, last = result.last!
            if (first == "\"" && last == "\"") || (first == "\u{201C}" && last == "\u{201D}") {
                result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }

    public static func defaultOptions(for mode: Dictation.ProcessingMode) -> LLMGenerationOptions {
        defaultOptionsProvider(mode)
    }
}
