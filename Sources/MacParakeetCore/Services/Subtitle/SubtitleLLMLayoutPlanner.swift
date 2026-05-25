import Foundation
import OSLog

/// LLM-driven cue layout planner.
///
/// This is the heart of the "LLM lays out the cues" path (replaces the
/// older `SubtitleLLMRefiner`'s per-cue text polish). The planner:
///
/// 1. Chunks the input `[WordTimestamp]` into groups bounded by
///    `SentenceUnit` boundaries (never cuts a chunk mid-sentence) so the
///    LLM sees one coherent paragraph at a time.
/// 2. For each chunk, in parallel up to `maxConcurrency`, asks the LLM
///    to return cue ranges as JSON.
/// 3. Validates the response (`LayoutPlanParser`). On any failure for a
///    given chunk, returns `nil` for that chunk so the caller can fall
///    back to the deterministic builder for just that section.
/// 4. Maps validated ranges into `[ExportService.SubtitleCue]`, using
///    *our* `WordTimestamp` array for both text and timing — the LLM
///    never controls those, only the split points.
public actor SubtitleLLMLayoutPlanner {

    public typealias ProgressHandler = @Sendable (Int, Int) -> Void

    private let llmService: LLMServiceProtocol
    private let chunkTargetWords: Int
    private let maxConcurrency: Int
    private let modelProfile: ModelProfile?

    public init(
        llmService: LLMServiceProtocol,
        chunkTargetWords: Int = 80,
        maxConcurrency: Int = 4,
        modelProfile: ModelProfile? = nil
    ) {
        self.llmService = llmService
        // No upper-bound floor: tests pass small values to exercise the
        // chunking math. A minimum of 1 keeps the chunking math from
        // dividing by zero or looping forever.
        self.chunkTargetWords = max(1, chunkTargetWords)
        self.maxConcurrency = max(1, maxConcurrency)
        self.modelProfile = modelProfile
    }

    /// One chunk's result: either a list of cues (LLM laid out OK) or
    /// `nil` (caller should fall back to deterministic layout for this
    /// chunk's word range).
    public struct ChunkResult: Sendable {
        public let chunkStartIndex: Int  // first word index this chunk covers
        public let chunkEndIndex: Int    // last word index this chunk covers
        public let cues: [ExportService.SubtitleCue]?

        public var didFallBack: Bool { cues == nil }
    }

    /// Run the planner over all input words. The caller decides how to
    /// fill in `nil` chunks (typically by running the deterministic
    /// builder over that word range).
    public func plan(
        words: [WordTimestamp],
        units: [SentenceUnit],
        config: SubtitleExportConfig,
        speakerId: String? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> [ChunkResult] {
        guard !words.isEmpty else { return [] }
        let chunks = makeChunks(words: words, units: units)
        let total = chunks.count
        var resultsByIndex: [Int: ChunkResult] = [:]
        var completed = 0

        await withTaskGroup(of: (Int, ChunkResult).self) { group in
            var nextChunk = 0

            // Seed up to maxConcurrency tasks.
            while nextChunk < min(maxConcurrency, total) {
                let idx = nextChunk
                let chunk = chunks[idx]
                group.addTask { [llmService, modelProfile] in
                    let result = await Self.runOne(
                        chunk: chunk,
                        llmService: llmService,
                        config: config,
                        speakerId: speakerId,
                        modelProfile: modelProfile
                    )
                    return (idx, result)
                }
                nextChunk += 1
            }

            while let (idx, result) = await group.next() {
                resultsByIndex[idx] = result
                completed += 1
                onProgress?(completed, total)

                if nextChunk < total {
                    let next = nextChunk
                    let chunk = chunks[next]
                    group.addTask { [llmService, modelProfile] in
                        let result = await Self.runOne(
                            chunk: chunk,
                            llmService: llmService,
                            config: config,
                            speakerId: speakerId,
                            modelProfile: modelProfile
                        )
                        return (next, result)
                    }
                    nextChunk += 1
                }
            }
        }

        return (0..<chunks.count).map { resultsByIndex[$0]! }
    }

    // MARK: - Chunking

    struct Chunk: Sendable {
        let startIndex: Int          // first word index of the chunk (into source array)
        let endIndex: Int            // last word index of the chunk (inclusive)
        let words: [WordTimestamp]   // slice of the source array for this chunk
    }

    /// Build chunks whose boundaries always align with `SentenceUnit`
    /// endings. Each chunk targets `chunkTargetWords` but is allowed to
    /// run longer than that if the current sentence hasn't finished
    /// (better one slightly-large chunk than a sentence cut in half).
    nonisolated func makeChunks(words: [WordTimestamp], units: [SentenceUnit]) -> [Chunk] {
        guard !words.isEmpty else { return [] }
        // If we have no sentence units, treat the whole input as one
        // chunk-eligible block.
        let workingUnits: [SentenceUnit] = units.isEmpty
            ? [SentenceUnit(startIndex: 0, endIndex: words.count - 1,
                            text: "", endsWithStrongPunctuation: false)]
            : units

        var chunks: [Chunk] = []
        var current: [SentenceUnit] = []
        var currentWordCount = 0
        for unit in workingUnits {
            current.append(unit)
            currentWordCount += unit.wordCount
            if currentWordCount >= chunkTargetWords {
                let s = current.first!.startIndex
                let e = current.last!.endIndex
                chunks.append(Chunk(startIndex: s, endIndex: e, words: Array(words[s...e])))
                current.removeAll()
                currentWordCount = 0
            }
        }
        if !current.isEmpty {
            let s = current.first!.startIndex
            let e = current.last!.endIndex
            chunks.append(Chunk(startIndex: s, endIndex: e, words: Array(words[s...e])))
        }
        return chunks
    }

    // MARK: - Per-chunk

    private static let log = Logger(subsystem: "com.macparakeet.core", category: "SubtitleLLMLayoutPlanner")

    private static func runOne(
        chunk: Chunk,
        llmService: LLMServiceProtocol,
        config: SubtitleExportConfig,
        speakerId: String?,
        modelProfile: ModelProfile?
    ) async -> ChunkResult {
        let prompt = buildPrompt(chunk: chunk, config: config)
        let resolvedSystemPrompt = systemPrompt(for: modelProfile?.promptHint ?? .standard)
        let response: String
        do {
            response = try await llmService.transform(text: prompt, prompt: resolvedSystemPrompt)
        } catch {
            log.warning("layout_planner_chunk_fallback reason=llm_threw range=\(chunk.startIndex)-\(chunk.endIndex) error=\(String(describing: error), privacy: .public)")
            return ChunkResult(
                chunkStartIndex: chunk.startIndex,
                chunkEndIndex: chunk.endIndex,
                cues: nil
            )
        }

        // `maxCharsPerLine` is the TOTAL cue budget across all rendered
        // lines (not a per-line cap) — same semantics as the deterministic
        // builder and the wrap pass. Earlier this multiplied by
        // `maxLinesPerCue`, which let the LLM produce ~128-char cues at a
        // configured 65-char budget. SRT (17), block 15 was the smoking gun.
        let perCueBudget = config.maxCharsPerLine
        let maxGap = maxGapToRepair(for: modelProfile?.parserLeniency ?? .normal)
        switch LayoutPlanParser.parse(response, words: chunk.words, perCueBudget: perCueBudget, maxGapToRepair: maxGap) {
        case .success(let rawRanges):
            // Auto-split any LLM-produced cue whose text exceeds the
            // configured budget (with a small tolerance). The LLM tends
            // to overshoot — real telemetry showed 75–115-char cues at
            // a 65-char budget. Rejecting the chunk wastes the LLM's
            // other (good) boundary choices, so instead we keep them
            // and only break the oversized ones at the best linguistic
            // point.
            let ranges = autoSplitOversizedRanges(rawRanges, words: chunk.words, perCueBudget: perCueBudget)
            let didSplit = ranges.count > rawRanges.count
            if didSplit {
                log.debug("layout_planner_autosplit chunk=\(chunk.startIndex)-\(chunk.endIndex) before=\(rawRanges.count) after=\(ranges.count) budget=\(perCueBudget)")
            } else {
                log.debug("layout_planner_chunk_ok range=\(chunk.startIndex)-\(chunk.endIndex) cues=\(ranges.count) budget=\(perCueBudget)")
            }
            // Map chunk-local indices back to source indices when we build
            // the cue. Use OUR word array for text + timing.
            var cues: [ExportService.SubtitleCue] = []
            cues.reserveCapacity(ranges.count)
            for r in ranges {
                let slice = chunk.words[r.start...r.end]
                let text = slice.map(\.word).joined(separator: " ")
                let startMs = slice.first!.startMs
                let endMs = slice.last!.endMs
                cues.append(ExportService.SubtitleCue(
                    startMs: startMs,
                    endMs: endMs,
                    text: text,
                    speakerId: speakerId
                ))
            }
            return ChunkResult(
                chunkStartIndex: chunk.startIndex,
                chunkEndIndex: chunk.endIndex,
                cues: cues
            )
        case .failure(let reason):
            // Truncated preview of the LLM body so a failure tells us
            // whether the issue is parsing, schema, range math, or
            // budget — and we can fix the right thing rather than
            // guessing. Privacy `.public` because this is the user's
            // own transcript, not third-party data.
            let preview = response.prefix(500).replacingOccurrences(of: "\n", with: " ")
            log.warning("layout_planner_chunk_fallback reason=\(String(describing: reason), privacy: .public) range=\(chunk.startIndex)-\(chunk.endIndex) budget=\(perCueBudget) response=\(preview, privacy: .public)")
            return ChunkResult(
                chunkStartIndex: chunk.startIndex,
                chunkEndIndex: chunk.endIndex,
                cues: nil
            )
        }
    }

    // MARK: - Prompt

    // MARK: - Auto-split

    /// Words we don't want a cue to end with — conjunctions, articles,
    /// determiners, prepositions, auxiliary verbs, short pronouns. If the
    /// auto-splitter is forced to choose between candidates, anything
    /// ending in one of these is heavily penalised.
    static let autoSplitBadEnders: Set<String> = [
        // Coordinating conjunctions
        "and", "but", "or", "so", "yet", "for", "nor", "then",
        // Subordinating conjunctions — never end a cue here.
        // Real failure case: SRT (19) cue 10 was "Legs are moving because"
        // because this list was missing the subordinators.
        "because", "although", "while", "since", "whereas", "unless",
        "until", "though", "if", "when", "where", "as",
        // Articles + determiners
        "the", "a", "an",
        "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their",
        // Prepositions
        "in", "on", "at", "to", "of", "with", "from", "by", "into", "onto",
        // Auxiliary verbs
        "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did",
        "will", "would", "can", "could", "should",
        // Short pronouns
        "i", "we", "you", "they", "he", "she", "it",
    ]

    /// Split every LLM-emitted range whose joined text exceeds
    /// `perCueBudget * 1.15` into smaller ranges at the best linguistic
    /// break point. Recurses on each half so a single very-long range
    /// (e.g. the 190-char outlier seen in logs) still ends up as several
    /// budget-compliant pieces.
    ///
    /// The split point picker prefers, in order: sentence terminators,
    /// commas / semicolons / colons, then a midpoint by character count.
    /// Endings in `autoSplitBadEnders` get a strong penalty so the
    /// auto-split doesn't undo the very rules we asked the LLM to
    /// follow.
    static func autoSplitOversizedRanges(
        _ ranges: [LayoutPlanParser.CueRange],
        words: [WordTimestamp],
        perCueBudget: Int
    ) -> [LayoutPlanParser.CueRange] {
        let cap = max(perCueBudget, perCueBudget * 115 / 100)
        var out: [LayoutPlanParser.CueRange] = []
        for r in ranges {
            out.append(contentsOf: splitRecursive(r, words: words, cap: cap, depth: 0))
        }
        return out
    }

    private static func splitRecursive(
        _ range: LayoutPlanParser.CueRange,
        words: [WordTimestamp],
        cap: Int,
        depth: Int
    ) -> [LayoutPlanParser.CueRange] {
        // Hard recursion guard — pathological inputs (e.g. a single
        // 200-char word) shouldn't loop. After 6 levels we accept the
        // range as-is and let the wrap pass downstream deal with display.
        guard depth < 6 else { return [range] }
        let text = words[range.start...range.end].map(\.word).joined(separator: " ")
        if text.count <= cap { return [range] }
        if range.end - range.start < 2 { return [range] }
        guard let splitIdx = bestSplitIndex(in: words, range: range, cap: cap) else {
            return [range]
        }
        let left = LayoutPlanParser.CueRange(start: range.start, end: splitIdx)
        let right = LayoutPlanParser.CueRange(start: splitIdx + 1, end: range.end)
        return splitRecursive(left, words: words, cap: cap, depth: depth + 1)
             + splitRecursive(right, words: words, cap: cap, depth: depth + 1)
    }

    /// Score each candidate split index inside the range; return the
    /// best one (or nil if no candidate produces a left half ≤ cap).
    private static func bestSplitIndex(
        in words: [WordTimestamp],
        range: LayoutPlanParser.CueRange,
        cap: Int
    ) -> Int? {
        var best: (index: Int, score: Int)? = nil

        for splitIdx in range.start..<range.end {
            let leftText = words[range.start...splitIdx].map(\.word).joined(separator: " ")
            // Left half must fit; otherwise this candidate is useless.
            guard leftText.count <= cap else { continue }
            let rightText = words[(splitIdx + 1)...range.end].map(\.word).joined(separator: " ")
            guard !rightText.isEmpty else { continue }

            let raw = words[splitIdx].word
            let last = raw.last
            let stripped = raw.trimmingCharacters(in: .punctuationCharacters).lowercased()

            var score = 0
            // Strong reward for landing on punctuation.
            if let c = last, ".!?".contains(c) { score += 500 }
            else if let c = last, ",;:".contains(c) { score += 250 }

            // Strong penalty for ending on a bad word.
            if autoSplitBadEnders.contains(stripped) { score -= 300 }

            // Number-range guard: penalise splits that would tear apart
            // "X and Y" / "X to Y" / "between X and Y" patterns where X
            // or Y is a number. Real failure case: the LLM produced
            // "...between 80" + "and 90." which made it through because
            // the size was fine; the auto-splitter shouldn't make this
            // worse by picking the same kind of break itself.
            let endsInDigit = stripped.unicodeScalars.last.map { CharacterSet.decimalDigits.contains($0) } ?? false
            let nextRaw = (splitIdx + 1) <= range.end ? words[splitIdx + 1].word : ""
            let nextStripped = nextRaw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let prevStripped: String = {
                guard splitIdx - 1 >= range.start else { return "" }
                return words[splitIdx - 1].word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            }()
            // Split puts a number on the left and "and X" / "to X" on the right.
            if endsInDigit && (nextStripped == "and" || nextStripped == "to") {
                score -= 400
            }
            // Split puts "and Y" / "to Y" on the right where prev was a number.
            // (Same pattern, different way the LLM can give us the chunk.)
            if (stripped == "and" || stripped == "to"),
               prevStripped.unicodeScalars.last.map({ CharacterSet.decimalDigits.contains($0) }) ?? false {
                score -= 400
            }

            // Prefer a balanced split (roughly equal halves by char count).
            let total = leftText.count + rightText.count
            let mid = total / 2
            score -= abs(leftText.count - mid)

            if best == nil || score > best!.score {
                best = (splitIdx, score)
            }
        }
        return best?.index
    }

    // MARK: - Prompt

    /// Map a `ModelProfile.ParserLeniency` to the LayoutPlanParser
    /// `maxGapToRepair` cap. Strict (1) for capable models that rarely
    /// skip indices; lenient (5) for models like Gemma 4 that occasionally
    /// drop a small run of word indices.
    static func maxGapToRepair(for leniency: ModelProfile.ParserLeniency) -> Int {
        switch leniency {
        case .strict: return 1
        case .normal: return 3
        case .lenient: return 5
        }
    }

    /// Profile-aware system prompt. `.explicitJSON` adds a stronger
    /// anti-comment preamble for models like Gemma 4 that habitually
    /// emit `// annotation` after JSON values. `.minimal` strips the
    /// "never invent text" boilerplate for small models with tight
    /// effective contexts. `.standard` is the original prompt.
    static func systemPrompt(for hint: ModelProfile.PromptHint) -> String {
        let basePrompt = """
            You are a subtitle captioning specialist. You decide where to break a spoken transcript into subtitle cues.
            You receive a numbered list of words from one section of a transcript and a set of layout rules.
            You return ONLY a JSON object with the shape {"cues":[{"start":<int>,"end":<int>}, ...]} — no commentary, no markdown fences, no explanation.
            Each "start" and "end" is the inclusive word index into the input list.
            You never modify the words and you never invent text. You only choose where the cue boundaries go.
            Every input word must appear in exactly one cue. Cues must be contiguous and non-overlapping.
            """
        switch hint {
        case .standard:
            return basePrompt
        case .explicitJSON:
            // Strong anti-comment preamble for Gemma 4-class models.
            return """
                CRITICAL OUTPUT FORMAT: Your entire response MUST be a single valid JSON object. NO `// ...` comments, NO `/* */` blocks, NO trailing annotations, NO markdown code fences. Comments break the parser and cause your entire response to be discarded. If you write a comment, your work is wasted.

                """ + basePrompt
        case .minimal:
            return """
                You break a numbered word list into subtitle cues.
                Return ONLY {"cues":[{"start":<int>,"end":<int>}, ...]} — no markdown, no comments, no explanation.
                Every word index appears in exactly one cue. Cues are contiguous and non-overlapping.
                """
        }
    }

    /// Public for tests so prompt-fragment assertions can pin the rules
    /// we care about without driving an LLM round-trip. Keep `internal`
    /// rather than `public` — only the test target needs it.
    static func buildPrompt(chunk: Chunk, config: SubtitleExportConfig) -> String {
        // `maxCharsPerLine` is the TOTAL cue budget across all rendered
        // lines (not a per-line cap) — same semantics as the deterministic
        // builder and the wrap pass. Earlier this multiplied by
        // `maxLinesPerCue`, which let the LLM produce ~128-char cues at a
        // configured 65-char budget. SRT (17), block 15 was the smoking gun.
        let perCueBudget = config.maxCharsPerLine
        let perLineHint = max(10, config.maxCharsPerLine / max(1, config.maxLinesPerCue))
        // Don't force a hard floor when the user's per-cue budget is
        // already tight — half the budget is a safer "should be longer
        // than this" target.
        let minCueChars = min(20, max(12, perCueBudget / 2))

        var lines: [String] = []
        lines.append("RULES:")
        lines.append("- Max characters PER CUE (total across both lines): \(perCueBudget).")
        lines.append("- Max lines per cue: \(config.maxLinesPerCue).")
        lines.append("- Implied per-line cap: ~\(perLineHint) characters.")
        // NEW: minimum length rule. The single biggest readability win in
        // real exports — orphan cues like "pushes." / "Stand up." / "Woo!"
        // were the most-flagged issue in SRT 23 user feedback.
        lines.append("- Target cue length: AT LEAST \(minCueChars) characters AND at least 3 words, UNLESS the cue is a complete short sentence ending in `.`, `!`, or `?` (e.g. \"Oh, yes.\", \"Beautiful.\", \"Let's go.\" — these may stand alone).")
        lines.append("- A cue with fewer than \(minCueChars) characters that is NOT a complete short sentence is a layout failure — merge it with an adjacent cue instead.")
        lines.append("- Each cue must end at a natural break: sentence terminator (.!?), comma/clause boundary (,;:), or end of a phrasal verb.")
        lines.append("- NEVER end a cue with a conjunction (and, but, or, so, yet, for, nor), article (the, a, an), determiner (this, that, these, those), preposition (in, on, at, to, of, with, from, by), auxiliary verb (is, are, was, were, be, been, being, have, has, had, do, does, did, will, would, can, could, should).")
        lines.append("- NEVER start a cue with a comma or a conjunction.")
        lines.append("- Respect sentence integrity: do NOT pack the end of one sentence (`.!?`) with the start of the next sentence inside the same cue. Always break between sentences.")
        lines.append("- Keep number ranges intact: do not split inside \"between X and Y\", \"X to Y\", \"from X to Y\".")
        // NEW: number-unit rule. Targets SRT 23 / SRT 22 cases like
        // "30 second" / "speed pushes" and "next 30" / "minutes".
        lines.append("- Keep a number with its measurement unit on the SAME LINE AND IN THE SAME CUE: \"30 minutes\", \"4-minute warm-up\", \"45 reps\", \"90 degrees\", \"15 seconds\", \"8 minutes\". Never put the digit at the end of one cue and the unit at the start of the next. Includes the compound form: \"4 minute warm-up\" (3 words) stays together — do NOT split as \"4 minute\" + \"warm-up\".")
        lines.append("- Keep phrasal verbs intact: \"welcome in\", \"slow down\", \"bring up\", \"reach down\", \"take it up\", etc.")
        // NEW: mid-clause guard. Targets "see all" / "of that today".
        // If no punctuation, the only legal split is between phrases.
        lines.append("- Do NOT split mid-clause: between two adjacent words with no punctuation, only break if the next cue would start with the head of a new phrase (a noun, a new verb, or a fresh prepositional phrase). \"You're going to see all\" / \"of that today\" is a layout failure — \"of that\" continues the same phrase.")
        lines.append("- Every word index from 0 to \(chunk.words.count - 1) must appear in exactly one cue.")
        lines.append("- Cues must be contiguous: cues[i].start == cues[i-1].end + 1.")
        lines.append("- Cues must be in order: ascending start indices.")
        lines.append("")
        // Two contrasting examples. NOTE: explanations go on SEPARATE
        // lines (not inline with JSON) — when the prompt had `←`
        // arrow annotations on the same line as the JSON, the LLM
        // started mimicking that shape and emitting `{"start":0,
        // "end":8}, // explanation` style comments, which broke
        // parsing for the whole transcript (SRT 30 regression).
        lines.append("EXAMPLES:")
        lines.append("")
        lines.append("Example 1 — keep numbers with their units:")
        lines.append("Input words: [0]We [1]will [2]spend [3]the [4]next [5]30 [6]minutes [7]right [8]here.")
        lines.append("Correct output:")
        lines.append("{\"cues\":[{\"start\":0,\"end\":8}]}")
        lines.append("Wrong output (would tear \"30\" from \"minutes\"):")
        lines.append("{\"cues\":[{\"start\":0,\"end\":5},{\"start\":6,\"end\":8}]}")
        lines.append("")
        lines.append("Example 2 — merge tiny adjacent sentences:")
        lines.append("Input words: [0]Stand [1]up. [2]Let's [3]go. [4]Low [5]70s.")
        lines.append("Correct output:")
        lines.append("{\"cues\":[{\"start\":0,\"end\":3},{\"start\":4,\"end\":5}]}")
        lines.append("Wrong output (three orphan cues, each too short to display):")
        lines.append("{\"cues\":[{\"start\":0,\"end\":1},{\"start\":2,\"end\":3},{\"start\":4,\"end\":5}]}")
        lines.append("")
        lines.append("REMINDER: output ONLY the JSON object — no comments, no `//` annotations, no markdown, no explanation text. Just the raw JSON.")
        lines.append("")
        lines.append("WORDS:")
        for (i, w) in chunk.words.enumerated() {
            lines.append("[\(i)] \(w.word)")
        }
        lines.append("")
        lines.append("OUTPUT (JSON only):")
        lines.append("{\"cues\":[{\"start\":0,\"end\":<int>}, ...]}")
        return lines.joined(separator: "\n")
    }
}
