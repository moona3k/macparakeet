import Foundation
import OSLog

/// LLM-driven cue review pass.
///
/// Runs AFTER the deterministic rebalance passes (bad-ender,
/// bad-starter, cardinal+unit, trailing-fragment, merge/absorb). Where
/// the layout planner picks initial cue boundaries from raw words, the
/// reviewer's job is narrower: walk the polished cues and let the LLM
/// vote on whether each adjacent pair reads cleanly or needs a small
/// boundary nudge.
///
/// Why a separate pass: the deterministic rules are getting dense
/// (5+ rebalances, each with their own bad-ender/budget/punctuation
/// guards) and still miss judgment calls that don't fit any fixed
/// rule — compound modifiers like "4 minute warm-up", stylistic
/// packing of mini-sentences. The reviewer can see the actual cue
/// text in context and make the kind of "this just reads wrong" call
/// no rule list will ever cover.
///
/// **Invariant**: the LLM never controls cue text or word ordering.
/// It only chooses between a fixed action vocabulary (`ReviewAction`).
/// Every suggested action is validated against deterministic budget /
/// gap / sentence-integrity checks before being applied; failures are
/// silently skipped (the cue pair stays as it was).
public actor SubtitleLLMReviewer {

    /// Called once per completed pair with `(completed, total)`. Same
    /// shape as `SubtitleLLMLayoutPlanner.ProgressHandler` so the
    /// caller can wire both phases through a single progress model.
    public typealias ProgressHandler = @Sendable (Int, Int) -> Void

    /// A snapshot of a cue's plain text and timing, sufficient for the
    /// reviewer to reason about it. Decoupled from `ExportService`'s
    /// private `MutableCue` so the caller can convert/apply suggestions
    /// however it stores cues internally.
    public struct ReviewableCue: Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        public let text: String

        public init(startMs: Int, endMs: Int, text: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
        }
    }

    /// One per cue pair the reviewer examined. `pairIndex` is the index
    /// of cue A in the original input array (so cue A = cues[pairIndex],
    /// cue B = cues[pairIndex + 1]). Apply suggestions in ascending
    /// `pairIndex` order with re-validation, since each applied action
    /// can change the indices of subsequent cues.
    public struct ReviewSuggestion: Equatable, Sendable {
        public let pairIndex: Int
        public let action: ReviewAction
    }

    private let llmService: LLMServiceProtocol
    private let maxConcurrency: Int
    private let pairsPerBatch: Int
    private let modelProfile: ModelProfile?

    /// Default `pairsPerBatch = 5` cuts ~400 single-pair calls per 30-min
    /// export down to ~80 batched calls. Smaller batches give the model
    /// less surrounding context per call (cheaper but slightly worse
    /// judgment); larger batches risk JSON drift as the response gets
    /// longer. 5 is the sweet spot in informal testing.
    ///
    /// `modelProfile` is optional. When supplied, its `promptHint` selects
    /// a prompt variant tuned to the model's known quirks (e.g. Gemma 4
    /// gets a stronger anti-comment preamble).
    public init(
        llmService: LLMServiceProtocol,
        maxConcurrency: Int = 4,
        pairsPerBatch: Int = 5,
        modelProfile: ModelProfile? = nil
    ) {
        self.llmService = llmService
        self.maxConcurrency = max(1, maxConcurrency)
        self.pairsPerBatch = max(1, pairsPerBatch)
        self.modelProfile = modelProfile
    }

    private static let log = Logger(subsystem: "com.macparakeet.core", category: "SubtitleLLMReviewer")

    /// Walk every adjacent pair in `cues`, ask the LLM what to do,
    /// return one suggestion per pair (or `.keep` on any failure).
    /// Pairs are grouped into batches of `pairsPerBatch`; each batch is
    /// one LLM call returning an array of decisions. Batches run in
    /// parallel up to `maxConcurrency`. `onProgress` (if provided)
    /// fires once per completed PAIR (not per batch) with
    /// `(completed, total)` so the UI stays smooth.
    public func review(
        cues: [ReviewableCue],
        config: SubtitleExportConfig,
        onProgress: ProgressHandler? = nil
    ) async -> [ReviewSuggestion] {
        guard cues.count >= 2 else { return [] }
        let totalPairs = cues.count - 1
        // Build batches as half-open ranges of pair indices [start, end).
        var batches: [(start: Int, end: Int)] = []
        var b = 0
        while b < totalPairs {
            batches.append((start: b, end: min(b + pairsPerBatch, totalPairs)))
            b += pairsPerBatch
        }
        var resultsByIndex: [Int: ReviewSuggestion] = [:]

        await withTaskGroup(of: [ReviewSuggestion].self) { group in
            var nextBatch = 0
            while nextBatch < batches.count && nextBatch < maxConcurrency {
                let batch = batches[nextBatch]
                group.addTask { [llmService, modelProfile] in
                    await Self.reviewBatch(
                        startPairIndex: batch.start,
                        endPairIndex: batch.end,
                        cues: cues,
                        config: config,
                        llmService: llmService,
                        modelProfile: modelProfile
                    )
                }
                nextBatch += 1
            }
            var completed = 0
            while let suggestions = await group.next() {
                for s in suggestions { resultsByIndex[s.pairIndex] = s }
                completed += suggestions.count
                onProgress?(min(completed, totalPairs), totalPairs)
                if nextBatch < batches.count {
                    let batch = batches[nextBatch]
                    group.addTask { [llmService, modelProfile] in
                        await Self.reviewBatch(
                            startPairIndex: batch.start,
                            endPairIndex: batch.end,
                            cues: cues,
                            config: config,
                            llmService: llmService,
                            modelProfile: modelProfile
                        )
                    }
                    nextBatch += 1
                }
            }
        }

        return (0..<totalPairs).map {
            resultsByIndex[$0] ?? ReviewSuggestion(pairIndex: $0, action: .keep)
        }
    }

    /// Issue ONE LLM call covering pairs `[startPairIndex, endPairIndex)`,
    /// parse the batched response, and map batch-local pair indices back
    /// to absolute cue-list indices. Any pair the LLM omits silently
    /// defaults to `.keep` (handled by the caller via the
    /// `resultsByIndex` fallback in `review`).
    private static func reviewBatch(
        startPairIndex: Int,
        endPairIndex: Int,
        cues: [ReviewableCue],
        config: SubtitleExportConfig,
        llmService: LLMServiceProtocol,
        modelProfile: ModelProfile?
    ) async -> [ReviewSuggestion] {
        // Pairs covered: startPairIndex..<endPairIndex. Each pair touches
        // cues at index `i` and `i+1`, so the batch involves cues
        // [startPairIndex ... endPairIndex] (inclusive on both ends).
        let cueRangeStart = startPairIndex
        let cueRangeEnd = endPairIndex          // inclusive
        let batchCues = Array(cues[cueRangeStart...cueRangeEnd])
        let prev = startPairIndex > 0 ? cues[startPairIndex - 1] : nil
        let next = (endPairIndex + 1) < cues.count ? cues[endPairIndex + 1] : nil
        let prompt = buildBatchedPrompt(
            cues: batchCues,
            prev: prev,
            next: next,
            config: config
        )
        let resolvedSystemPrompt = systemPrompt(for: modelProfile?.promptHint ?? .standard)

        let response: String
        do {
            response = try await llmService.transform(text: prompt, prompt: resolvedSystemPrompt)
        } catch {
            log.warning("reviewer_batch_fallback reason=llm_threw range=\(startPairIndex)-\(endPairIndex) error=\(String(describing: error), privacy: .public)")
            // Whole-batch failure → return empty; caller defaults all to .keep.
            return []
        }

        switch ReviewActionParser.parseBatch(response) {
        case .success(let decisions):
            log.debug("reviewer_batch_ok range=\(startPairIndex)-\(endPairIndex) decisions=\(decisions.count)")
            // Map batch-local pair indices into absolute indices.
            let pairCount = endPairIndex - startPairIndex
            return decisions.compactMap { d in
                guard d.pairIndex >= 0 && d.pairIndex < pairCount else { return nil }
                return ReviewSuggestion(
                    pairIndex: startPairIndex + d.pairIndex,
                    action: d.action
                )
            }
        case .failure(let reason):
            let preview = response.prefix(400).replacingOccurrences(of: "\n", with: " ")
            log.warning("reviewer_batch_fallback reason=\(String(describing: reason), privacy: .public) range=\(startPairIndex)-\(endPairIndex) response=\(preview, privacy: .public)")
            return []
        }
    }

    // MARK: - Prompt

    /// System prompt: keep it terse + scoped. The reviewer's job is to
    /// vote on each boundary in a small window of adjacent cues — not
    /// to be a general subtitle critic.
    /// Profile-aware system prompt. `.explicitJSON` prepends a stronger
    /// anti-comment warning for models like Gemma 4 that habitually annotate
    /// JSON output with `// ...`. `.minimal` strips the boilerplate for
    /// small models with tight effective contexts.
    static func systemPrompt(for hint: ModelProfile.PromptHint) -> String {
        let basePrompt = """
            You are a subtitle quality reviewer. You see a small window of adjacent subtitle cues with the boundaries numbered. For each numbered boundary, you decide whether the pair on either side reads cleanly or whether the boundary should shift slightly.
            You return ONLY a JSON object with the shape {"decisions":[{"pair":<int>,"action":"<verb>","n":<int?>}, ...]} — no commentary, no markdown fences, no explanation.
            You never modify cue text. You only vote on boundaries.
            """
        switch hint {
        case .standard:
            return basePrompt
        case .explicitJSON:
            return """
                CRITICAL OUTPUT FORMAT: Your entire response MUST be a single valid JSON object. NO `// ...` comments, NO `/* */` blocks, NO trailing annotations, NO markdown code fences. Comments break the parser and cause your entire response to be discarded.

                """ + basePrompt
        case .minimal:
            return """
                You vote on subtitle boundaries. Return ONLY {"decisions":[{"pair":<int>,"action":"<verb>","n":<int?>}, ...]}.
                No comments, no markdown, no explanation.
                """
        }
    }

    /// Builds the batched prompt: one window of up to ~6 cues + a prev
    /// and next context cue, with the boundaries between consecutive
    /// `cues` numbered 0..(cues.count - 2). The model returns one
    /// decision per numbered boundary.
    ///
    /// Public for tests so prompt-fragment assertions can pin the rules
    /// we care about without driving an LLM round-trip.
    static func buildBatchedPrompt(
        cues: [ReviewableCue],
        prev: ReviewableCue?,
        next: ReviewableCue?,
        config: SubtitleExportConfig
    ) -> String {
        precondition(cues.count >= 2, "batched prompt needs at least 2 cues (1 pair)")
        let pairCount = cues.count - 1

        func flat(_ c: ReviewableCue) -> String {
            c.text.replacingOccurrences(of: "\n", with: " ")
        }

        var lines: [String] = []
        lines.append("Review the boundaries in this cue window. There are \(pairCount) boundaries to vote on (numbered 0 through \(pairCount - 1)).")
        lines.append("")
        if let prev {
            lines.append("Previous cue (context only, do not modify, no boundary here):")
            lines.append("  \(flat(prev))")
            lines.append("")
        }
        lines.append("CUES:")
        for (idx, c) in cues.enumerated() {
            lines.append("  [\(idx)] \(flat(c))")
        }
        lines.append("")
        lines.append("BOUNDARIES:")
        for p in 0..<pairCount {
            lines.append("  pair \(p): between cue [\(p)] and cue [\(p + 1)]")
        }
        if let next {
            lines.append("")
            lines.append("Next cue (context only, do not modify, no boundary here):")
            lines.append("  \(flat(next))")
        }
        lines.append("")
        lines.append("ACTIONS per boundary:")
        lines.append("- \"keep\" — both cues read fine; no change. THIS IS THE DEFAULT.")
        lines.append("- \"merge\" — the two cues should be one (combined length must stay under ~\(config.maxCharsPerLine * 2) chars).")
        lines.append("- \"shift_to_a\" + n (1-3) — move the first n words of the right cue to the end of the left cue. Use when the start of the right cue is the tail of the left cue's sentence (compound modifier split, stranded preposition).")
        lines.append("- \"shift_to_b\" + n (1-3) — move the last n words of the left cue to the start of the right cue. Use when the end of the left cue is the head of the right cue's sentence (\"...have you. Go\" / \"ahead and...\").")
        lines.append("")
        lines.append("RULES:")
        lines.append("- DEFAULT to \"keep\". Only vote a change when there is a clear readability win.")
        lines.append("- A cue that already ends cleanly at `.!?` and the next cue starts a new sentence is almost always \"keep\".")
        lines.append("- Respect sentence integrity: `.!?` should align with a cue boundary, not sit mid-cue.")
        lines.append("- Never propose a change that would cross a long pause or pack two unrelated thoughts.")
        lines.append("- Each pair is independent. Do not chain reasoning across boundaries.")
        lines.append("")
        lines.append("DO NOT — common bad patterns to avoid:")
        lines.append("- DO NOT pull the start of a new sentence backward into the previous cue. \"30. We\" / \"will spend...\" is a layout failure — \"We\" starts the next sentence and stays with the right cue.")
        lines.append("- DO NOT leave the left cue ending on a conjunction (\"and\", \"but\", \"or\", \"so\"), article (\"the\", \"a\", \"an\"), preposition (\"of\", \"to\", \"with\", \"into\"), auxiliary verb (\"is\", \"are\", \"was\", \"have\", \"has\"), or subordinator (\"because\", \"while\", \"since\", \"if\", \"when\"). Those are bad enders.")
        lines.append("- DO NOT split a hyphenated word across cues. \"warm-up\", \"4-minute\", \"30-second\" must stay whole — never put \"-up\" or \"-minute\" at the start of the right cue.")
        lines.append("- DO NOT split a number range. \"85 to 90\", \"between 10 and 15\", \"100 to 105\" must stay together.")
        lines.append("- DO NOT merge two complete sentences when both already end with `.!?`. \"Beautiful.\" + \"Round 1 is done.\" stays as two cues.")
        lines.append("- DO NOT vote a change just because one cue is short. A standalone short sentence (\"Oh, yeah.\", \"Beautiful.\", \"Let's go.\") may legitimately stand alone.")
        lines.append("")
        lines.append("EXAMPLES (single-boundary illustrations; same rules apply to each numbered pair):")
        lines.append("")
        lines.append("Example — compound modifier split (vote shift_to_a):")
        lines.append("Left: \"because your 4 minute\"   Right: \"warm-up starts right now.\"")
        lines.append("→ {\"action\":\"shift_to_a\",\"n\":1}")
        lines.append("")
        lines.append("Example — fragment at end of left cue is start of next sentence (vote shift_to_b):")
        lines.append("Left: \"It is great to have you. Go\"   Right: \"ahead and find a cadence somewhere between 80 and 90.\"")
        lines.append("→ {\"action\":\"shift_to_b\",\"n\":1}")
        lines.append("")
        lines.append("Example — clean pair (vote keep):")
        lines.append("Left: \"Thank you for being here today.\"   Right: \"Thanks for spending this 30 minutes with me.\"")
        lines.append("→ {\"action\":\"keep\"}")
        lines.append("")
        lines.append("Example — WRONG: do NOT pull start of new sentence backward.")
        lines.append("Left: \"in to your intervals in arms 30.\"   Right: \"We will spend the next 30 minutes\"")
        lines.append("Correct: {\"action\":\"keep\"}    Wrong: {\"action\":\"shift_to_a\",\"n\":1}")
        lines.append("")
        lines.append("Example — WRONG: do NOT merge two complete sentences.")
        lines.append("Left: \"Beautiful.\"   Right: \"Round 1 is done.\"")
        lines.append("Correct: {\"action\":\"keep\"}    Wrong: {\"action\":\"merge\"}")
        lines.append("")
        lines.append("RESPONSE SHAPE — return ONE JSON object with a \"decisions\" array, ONE entry per numbered pair. \"n\" is required only for shift actions. Example response shape (for a 3-boundary window):")
        lines.append("{\"decisions\":[{\"pair\":0,\"action\":\"keep\"},{\"pair\":1,\"action\":\"shift_to_a\",\"n\":1},{\"pair\":2,\"action\":\"keep\"}]}")
        lines.append("")
        lines.append("REMINDER: output ONLY the JSON object — no comments, no `//` annotations, no markdown, no explanation text. One entry per pair index 0..\(pairCount - 1). Default to \"keep\" when in doubt.")
        lines.append("")
        lines.append("OUTPUT (JSON only):")
        return lines.joined(separator: "\n")
    }
}
