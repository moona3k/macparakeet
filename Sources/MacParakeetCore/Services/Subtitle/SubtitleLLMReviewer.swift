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

    public init(llmService: LLMServiceProtocol, maxConcurrency: Int = 4) {
        self.llmService = llmService
        self.maxConcurrency = max(1, maxConcurrency)
    }

    private static let log = Logger(subsystem: "com.macparakeet.core", category: "SubtitleLLMReviewer")

    /// Walk every adjacent pair in `cues`, ask the LLM what to do,
    /// return one suggestion per pair (or `.keep` on any failure).
    /// Runs LLM calls in parallel up to `maxConcurrency` and stitches
    /// results back in input order.
    public func review(
        cues: [ReviewableCue],
        config: SubtitleExportConfig
    ) async -> [ReviewSuggestion] {
        guard cues.count >= 2 else { return [] }
        let pairs = (0..<(cues.count - 1))
        let total = pairs.count
        var resultsByIndex: [Int: ReviewSuggestion] = [:]

        await withTaskGroup(of: ReviewSuggestion.self) { group in
            var nextPair = pairs.lowerBound
            // Seed up to maxConcurrency tasks.
            while nextPair < pairs.upperBound
                && (nextPair - pairs.lowerBound) < maxConcurrency {
                let i = nextPair
                group.addTask { [llmService] in
                    await Self.reviewOne(
                        pairIndex: i,
                        cues: cues,
                        config: config,
                        llmService: llmService
                    )
                }
                nextPair += 1
            }
            // Drain + refill.
            var completed = 0
            while let suggestion = await group.next() {
                resultsByIndex[suggestion.pairIndex] = suggestion
                completed += 1
                if nextPair < pairs.upperBound {
                    let i = nextPair
                    group.addTask { [llmService] in
                        await Self.reviewOne(
                            pairIndex: i,
                            cues: cues,
                            config: config,
                            llmService: llmService
                        )
                    }
                    nextPair += 1
                }
            }
            _ = total
            _ = completed
        }

        return pairs.map { resultsByIndex[$0] ?? ReviewSuggestion(pairIndex: $0, action: .keep) }
    }

    private static func reviewOne(
        pairIndex i: Int,
        cues: [ReviewableCue],
        config: SubtitleExportConfig,
        llmService: LLMServiceProtocol
    ) async -> ReviewSuggestion {
        let a = cues[i]
        let b = cues[i + 1]
        let prev = i > 0 ? cues[i - 1] : nil
        let next = (i + 2) < cues.count ? cues[i + 2] : nil
        let prompt = buildPrompt(a: a, b: b, prev: prev, next: next, config: config)

        let response: String
        do {
            response = try await llmService.transform(text: prompt, prompt: systemPrompt)
        } catch {
            log.warning("reviewer_pair_fallback reason=llm_threw pair=\(i) error=\(String(describing: error), privacy: .public)")
            return ReviewSuggestion(pairIndex: i, action: .keep)
        }

        switch ReviewActionParser.parse(response) {
        case .success(let action):
            log.debug("reviewer_pair_ok pair=\(i) action=\(String(describing: action), privacy: .public)")
            return ReviewSuggestion(pairIndex: i, action: action)
        case .failure(let reason):
            let preview = response.prefix(300).replacingOccurrences(of: "\n", with: " ")
            log.warning("reviewer_pair_fallback reason=\(String(describing: reason), privacy: .public) pair=\(i) response=\(preview, privacy: .public)")
            return ReviewSuggestion(pairIndex: i, action: .keep)
        }
    }

    // MARK: - Prompt

    /// System prompt: keep it terse + scoped. The reviewer has ONE job
    /// (vote on a single cue pair), not a general subtitle critic.
    static let systemPrompt = """
        You are a subtitle quality reviewer. You see one pair of adjacent subtitle cues at a time, plus a little surrounding context. You decide whether the pair reads cleanly or whether the cue boundary should shift slightly.
        You return ONLY a JSON object with the shape {"action": "<verb>", "n": <int>} — no commentary, no markdown fences, no explanation.
        You never modify cue text. You only vote on the boundary.
        """

    /// Public for tests so prompt-fragment assertions can pin the rules
    /// we care about without driving an LLM round-trip.
    static func buildPrompt(
        a: ReviewableCue,
        b: ReviewableCue,
        prev: ReviewableCue?,
        next: ReviewableCue?,
        config: SubtitleExportConfig
    ) -> String {
        var lines: [String] = []
        lines.append("Review this cue pair.")
        lines.append("")
        if let prev {
            lines.append("Previous cue (context, do not modify):")
            lines.append("  \(prev.text.replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("Cue A:")
        lines.append("  \(a.text.replacingOccurrences(of: "\n", with: " "))")
        lines.append("Cue B:")
        lines.append("  \(b.text.replacingOccurrences(of: "\n", with: " "))")
        if let next {
            lines.append("Next cue (context, do not modify):")
            lines.append("  \(next.text.replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("")
        lines.append("ACTIONS:")
        lines.append("- \"keep\" — both cues read fine; no change. THIS IS THE DEFAULT.")
        lines.append("- \"merge\" — A and B should be one cue (combined length must stay under ~\(config.maxCharsPerLine * 2) chars).")
        lines.append("- \"shift_to_a\" + n (1-3) — move the first n words of B to the end of A. Use this when the start of B is the tail of A's sentence (e.g. compound modifier split, stranded preposition).")
        lines.append("- \"shift_to_b\" + n (1-3) — move the last n words of A to the start of B. Use this when the end of A is the head of B's sentence (e.g. \"...have you. Go\" / \"ahead and...\").")
        lines.append("")
        lines.append("RULES:")
        lines.append("- DEFAULT to \"keep\". Only vote a change when there is a clear readability win.")
        lines.append("- Never propose a change that would cross a long pause or pack two unrelated thoughts.")
        lines.append("- Respect sentence integrity: a sentence-terminator (`. ! ?`) should align with a cue boundary when possible.")
        lines.append("- A cue that already ends cleanly at `.!?` and the next cue starts a new sentence is almost always \"keep\".")
        lines.append("")
        lines.append("EXAMPLES:")
        lines.append("")
        lines.append("Example 1 — compound modifier split (vote shift_to_a):")
        lines.append("Cue A: \"because your 4 minute\"")
        lines.append("Cue B: \"warm-up starts right now.\"")
        lines.append("Correct output:")
        lines.append("{\"action\":\"shift_to_a\",\"n\":1}")
        lines.append("")
        lines.append("Example 2 — fragment at end of A is start of next sentence (vote shift_to_b):")
        lines.append("Cue A: \"It is great to have you. Go\"")
        lines.append("Cue B: \"ahead and find a cadence somewhere between 80 and 90.\"")
        lines.append("Correct output:")
        lines.append("{\"action\":\"shift_to_b\",\"n\":1}")
        lines.append("")
        lines.append("Example 3 — clean pair, no change needed (vote keep):")
        lines.append("Cue A: \"Thank you for being here today.\"")
        lines.append("Cue B: \"Thanks for spending this 30 minutes with me.\"")
        lines.append("Correct output:")
        lines.append("{\"action\":\"keep\"}")
        lines.append("")
        lines.append("REMINDER: output ONLY the JSON object — no comments, no `//` annotations, no markdown, no explanation text. Just the raw JSON.")
        lines.append("")
        lines.append("OUTPUT (JSON only):")
        return lines.joined(separator: "\n")
    }
}
