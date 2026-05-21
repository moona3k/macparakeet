import Foundation

/// Uses an LLM to refine subtitle cue boundaries.
///
/// Cues are processed in batches (default 8 per LLM call) and batches run
/// concurrently (default 4 in flight). Each batch carries one cue of context
/// on either side so the LLM can see neighbouring phrasing without paying for
/// the full transcript every call. A `onProgress` callback fires after every
/// batch completes so the UI can render `N/M` style progress. Cooperative
/// cancellation is honoured between batches and inside the TaskGroup.
public actor SubtitleLLMRefiner {

    public typealias ProgressHandler = @Sendable (Int, Int) -> Void

    private let llmService: LLMServiceProtocol
    private let batchSize: Int
    private let maxConcurrency: Int

    public init(
        llmService: LLMServiceProtocol,
        batchSize: Int = 8,
        maxConcurrency: Int = 4
    ) {
        self.llmService = llmService
        self.batchSize = max(1, batchSize)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Refine a list of subtitle cues.
    ///
    /// - Parameters:
    ///   - cues: ordered cue list to refine.
    ///   - config: export config (used for budget hints in the prompt).
    ///   - onProgress: optional callback invoked with `(completed, total)`
    ///     after each batch resolves. Always called on the actor's executor.
    /// - Returns: refined cues in the same order as input.
    public func refine(
        cues: [ExportService.SubtitleCue],
        config: SubtitleExportConfig,
        onProgress: ProgressHandler? = nil
    ) async throws -> [ExportService.SubtitleCue] {
        guard cues.count > 2 else { return cues }

        let batches = makeBatches(cues: cues)
        let total = batches.count
        var completed = 0
        var refinedTextsByBatch: [Int: [String]] = [:]

        try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var nextBatchIndex = 0

            // Seed the group with up to maxConcurrency batches.
            while nextBatchIndex < min(maxConcurrency, total) {
                let i = nextBatchIndex
                let batch = batches[i]
                group.addTask { [llmService] in
                    let prompt = Self.buildPrompt(batch: batch, config: config)
                    let response = try await llmService.transform(
                        text: prompt,
                        prompt: Self.refinerSystemPrompt
                    )
                    let parsed = Self.parseResponse(response, expectedCount: batch.cues.count, fallback: batch.cues.map(\.text))
                    return (i, parsed)
                }
                nextBatchIndex += 1
            }

            while let (i, parsed) = try await group.next() {
                refinedTextsByBatch[i] = parsed
                completed += 1
                onProgress?(completed, total)

                if nextBatchIndex < total {
                    let j = nextBatchIndex
                    let batch = batches[j]
                    group.addTask { [llmService] in
                        let prompt = Self.buildPrompt(batch: batch, config: config)
                        let response = try await llmService.transform(
                            text: prompt,
                            prompt: Self.refinerSystemPrompt
                        )
                        let parsed = Self.parseResponse(response, expectedCount: batch.cues.count, fallback: batch.cues.map(\.text))
                        return (j, parsed)
                    }
                    nextBatchIndex += 1
                }
            }
        }

        let totalBudget = max(config.maxCharsPerLine, config.maxCharsPerLine * config.maxLinesPerCue)

        var refined: [ExportService.SubtitleCue] = []
        refined.reserveCapacity(cues.count)
        for (i, batch) in batches.enumerated() {
            let texts = refinedTextsByBatch[i] ?? batch.cues.map(\.text)
            for (j, cue) in batch.cues.enumerated() {
                let raw = j < texts.count ? texts[j] : cue.text
                let cleaned = Self.cleanText(raw)
                let bounded = Self.enforceBudget(cleaned, maxChars: totalBudget)
                // Always re-wrap so per-line budget is respected, even if the
                // LLM ignored line breaks. Flatten any \n / <br> the model
                // injected — the wrapper decides where the line break goes.
                let flat = bounded.replacingOccurrences(of: "\n", with: " ")
                let wrapped = ExportService.wrapSubtitleTextStatic(flat, config: config)
                refined.append(ExportService.SubtitleCue(
                    startMs: cue.startMs,
                    endMs: cue.endMs,
                    text: wrapped,
                    speakerId: cue.speakerId
                ))
            }
        }
        return refined
    }

    // MARK: - Batching

    struct Batch {
        let cues: [ExportService.SubtitleCue]
        let contextBefore: ExportService.SubtitleCue?
        let contextAfter: ExportService.SubtitleCue?
    }

    private func makeBatches(cues: [ExportService.SubtitleCue]) -> [Batch] {
        var batches: [Batch] = []
        var i = 0
        while i < cues.count {
            let end = min(i + batchSize, cues.count)
            let slice = Array(cues[i..<end])
            let before = i > 0 ? cues[i - 1] : nil
            let after = end < cues.count ? cues[end] : nil
            batches.append(Batch(cues: slice, contextBefore: before, contextAfter: after))
            i = end
        }
        return batches
    }

    // MARK: - Prompt

    private static func buildPrompt(batch: Batch, config: SubtitleExportConfig) -> String {
        var lines: [String] = []
        lines.append("Refine the subtitle cues marked [CUE N] below.")
        lines.append("")
        lines.append("Rules:")
        lines.append("- Return EXACTLY \(batch.cues.count) lines — one per [CUE N] input.")
        lines.append("- Do NOT merge cues, split cues, add cues, or remove cues.")
        lines.append("- Refine ONLY the text inside each cue; never copy words from neighbouring cues.")
        lines.append("- Do NOT emit HTML, markdown, <br>, **bold**, or any markup. Plain text only.")
        lines.append("- Use a single \\n inside a cue ONLY to break onto a second line; never use <br>.")
        lines.append("- Keep phrasal verbs together (e.g. 'welcome in', 'bring down').")
        lines.append("- Do NOT end a cue with conjunctions, articles, determiners, or prepositions.")
        lines.append("- Respect existing punctuation and sentence boundaries.")
        lines.append("- Balance 2-line cues so both lines are roughly equal length.")
        lines.append("- Max characters per line: \(config.maxCharsPerLine).")
        lines.append("- Max lines per cue: \(config.maxLinesPerCue).")
        lines.append("- Preserve meaning; only fix awkward boundaries and balance line breaks.")
        lines.append("")

        if let before = batch.contextBefore {
            lines.append("CONTEXT BEFORE (do not refine, do not output):")
            lines.append("  \(before.text.replacingOccurrences(of: "\n", with: " "))")
            lines.append("")
        }

        lines.append("CUES TO REFINE:")
        for (i, cue) in batch.cues.enumerated() {
            let n = i + 1
            let flat = cue.text.replacingOccurrences(of: "\n", with: " ")
            lines.append("[CUE \(n)] \(flat)")
        }
        lines.append("")

        if let after = batch.contextAfter {
            lines.append("CONTEXT AFTER (do not refine, do not output):")
            lines.append("  \(after.text.replacingOccurrences(of: "\n", with: " "))")
            lines.append("")
        }

        lines.append("OUTPUT FORMAT — return exactly \(batch.cues.count) lines, each starting with the matching [CUE N] tag:")
        for i in 0..<batch.cues.count {
            lines.append("[CUE \(i + 1)] <refined text for cue \(i + 1)>")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Parse `[CUE N] text` lines from the LLM response. Tolerates extra prose,
    /// blank lines, or missing tags by falling back to `fallback[i]` for any
    /// unmatched index.
    static func parseResponse(_ response: String, expectedCount: Int, fallback: [String]) -> [String] {
        var byIndex: [Int: String] = [:]
        let pattern = #"^\s*\[\s*CUE\s+(\d+)\s*\]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return fallback
        }

        let raw = response.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            let range = NSRange(lineStr.startIndex..<lineStr.endIndex, in: lineStr)
            guard let match = regex.firstMatch(in: lineStr, options: [], range: range),
                  match.numberOfRanges == 3,
                  let numRange = Range(match.range(at: 1), in: lineStr),
                  let textRange = Range(match.range(at: 2), in: lineStr),
                  let n = Int(lineStr[numRange]) else { continue }
            let idx = n - 1
            guard idx >= 0 && idx < expectedCount else { continue }
            let text = String(lineStr[textRange]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            byIndex[idx] = text
        }

        var result: [String] = []
        result.reserveCapacity(expectedCount)
        for i in 0..<expectedCount {
            if let parsed = byIndex[i] {
                result.append(parsed)
            } else {
                result.append(i < fallback.count ? fallback[i] : "")
            }
        }
        return result
    }

    // MARK: - Cleanup

    /// Cleans LLM output: strips any HTML-style tags (`<br>`, `<i>`, `</b>`,
    /// etc.) the model may have emitted, normalises newlines, and trims
    /// outer whitespace. SRT/VTT carry no real HTML, so tags are noise.
    static func cleanText(_ text: String) -> String {
        var t = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Strip HTML tags (greedy but bounded — won't match across newlines)
        if let regex = try? NSRegularExpression(pattern: "<[^>\n]+>", options: []) {
            let range = NSRange(t.startIndex..<t.endIndex, in: t)
            t = regex.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: " ")
        }

        // Collapse multiple consecutive spaces created by tag removal.
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func enforceBudget(_ text: String, maxChars: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= maxChars {
            return text
        }
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
        You receive a batch of cues marked [CUE 1], [CUE 2], etc., optionally with CONTEXT BEFORE and CONTEXT AFTER blocks.
        Return ONE line per cue in the input, prefixed with the matching [CUE N] tag.
        Output plain text only — no HTML, no markdown, no <br> tags, no bold or italic markers.
        Use \\n inside a cue ONLY when a real line break is needed; never use <br>.
        Do NOT merge, split, add, or remove cues; preserve cue count exactly.
        Keep each cue's meaning identical; only fix awkward boundaries and balance line breaks.
        Do not add numbering, timestamps, quotes, explanations, or commentary outside the tagged lines.
        """
}
