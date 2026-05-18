import Foundation

/// Uses an LLM to refine subtitle cue boundaries via a sliding-window approach.
/// Each cue is re-evaluated in the context of its neighbours (previous + current + next)
/// for natural phrasing, orphan avoidance, and line-break balance.
public actor SubtitleLLMRefiner {

    private let llmService: LLMServiceProtocol

    public init(llmService: LLMServiceProtocol) {
        self.llmService = llmService
    }

    /// Refine a list of subtitle cues using a 5-cue sliding window.
    ///
    /// For each cue the LLM sees up to 2 preceding cues, the current cue, and up to 2
    /// following cues. It returns ONLY the refined text for the current cue, preserving timing.
    /// A second pass deduplicates and enforces the character budget.
    public func refine(
        cues: [ExportService.SubtitleCue],
        config: SubtitleExportConfig
    ) async throws -> [ExportService.SubtitleCue] {
        guard cues.count > 2 else { return cues }

        var refined: [ExportService.SubtitleCue] = []

        for i in 0..<cues.count {
            let window = window(for: i, in: cues)
            let prompt = buildPrompt(window: window, config: config)

            let refinedText = try await llmService.transform(
                text: prompt,
                prompt: Self.refinerSystemPrompt
            )

            let cleaned = refinedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")

            // Enforce budget: if the LLM returned something too long, truncate
            let finalText = enforceBudget(cleaned, maxChars: config.maxCharsPerLine)

            let cue = cues[i]
            refined.append(ExportService.SubtitleCue(
                startMs: cue.startMs,
                endMs: cue.endMs,
                text: finalText,
                speakerId: cue.speakerId
            ))
        }

        return refined
    }

    // MARK: - Sliding Window

    private func window(for index: Int, in cues: [ExportService.SubtitleCue]) -> Window {
        let prev2 = index > 1 ? cues[index - 2] : nil
        let prev1 = index > 0 ? cues[index - 1] : nil
        let curr = cues[index]
        let next1 = index < cues.count - 1 ? cues[index + 1] : nil
        let next2 = index < cues.count - 2 ? cues[index + 2] : nil
        return Window(prev2: prev2, prev1: prev1, current: curr, next1: next1, next2: next2)
    }

    private struct Window {
        let prev2: ExportService.SubtitleCue?
        let prev1: ExportService.SubtitleCue?
        let current: ExportService.SubtitleCue
        let next1: ExportService.SubtitleCue?
        let next2: ExportService.SubtitleCue?
    }

    // MARK: - Prompt Builder

    private func buildPrompt(window: Window, config: SubtitleExportConfig) -> String {
        var lines: [String] = []
        lines.append("REFINE THE MIDDLE CUE.")
        lines.append("")
        lines.append("Rules:")
        lines.append("- Keep phrasal verbs together (e.g. 'welcome in', 'bring down', 'slow up').")
        lines.append("- Do NOT end a cue with conjunctions, articles, determiners, or prepositions.")
        lines.append("- Respect existing punctuation and sentence boundaries.")
        lines.append("- Balance 2-line cues so both lines are roughly equal length.")
        lines.append("- Maximum total characters across all lines: \(config.maxCharsPerLine).")
        lines.append("- Maximum lines per cue: \(config.maxLinesPerCue).")
        lines.append("- Return ONLY the refined text for the MIDDLE cue. No explanation, no quotes.")
        lines.append("")

        if let prev2 = window.prev2 {
            lines.append("CONTEXT (2 cues before):")
            lines.append("  \(prev2.text)")
            lines.append("")
        }

        if let prev1 = window.prev1 {
            lines.append("CONTEXT (previous cue):")
            lines.append("  \(prev1.text)")
            lines.append("")
        }

        lines.append("MIDDLE CUE (REFINE THIS):")
        lines.append("  \(window.current.text)")
        lines.append("")

        if let next1 = window.next1 {
            lines.append("CONTEXT (next cue):")
            lines.append("  \(next1.text)")
            lines.append("")
        }

        if let next2 = window.next2 {
            lines.append("CONTEXT (2 cues ahead):")
            lines.append("  \(next2.text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Budget Enforcement

    private func enforceBudget(_ text: String, maxChars: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= maxChars {
            return text
        }
        // Truncate to maxChars-1 and add ellipsis on the last line
        var lines = text.components(separatedBy: "\n")
        if lines.isEmpty { return String(flat.prefix(maxChars)) }
        let lastIdx = lines.count - 1
        let lastLine = lines[lastIdx]
        let remainingBudget = maxChars - (flat.count - lastLine.count)
        if remainingBudget > 3 {
            lines[lastIdx] = String(lastLine.prefix(remainingBudget - 3)) + "..."
        } else {
            lines[lastIdx] = String(lastLine.prefix(max(1, remainingBudget)))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - System Prompt

    private static let refinerSystemPrompt = """
        You are a subtitle captioning specialist. You improve subtitle cue text for readability.
        You receive up to 2 CONTEXT cues before, a MIDDLE cue to refine, and up to 2 CONTEXT cues after.
        You output ONLY the refined text for the MIDDLE cue.
        Do not add numbering, timestamps, quotes, or explanations.
        Keep the meaning identical; only fix awkward boundaries, merge orphaned fragments,
        and balance line breaks.
        """
}
