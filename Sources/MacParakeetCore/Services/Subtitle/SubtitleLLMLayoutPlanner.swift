import Foundation

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

    public init(
        llmService: LLMServiceProtocol,
        chunkTargetWords: Int = 80,
        maxConcurrency: Int = 4
    ) {
        self.llmService = llmService
        // No upper-bound floor: tests pass small values to exercise the
        // chunking math. A minimum of 1 keeps the chunking math from
        // dividing by zero or looping forever.
        self.chunkTargetWords = max(1, chunkTargetWords)
        self.maxConcurrency = max(1, maxConcurrency)
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
                group.addTask { [llmService, chunkTargetWords] in
                    _ = chunkTargetWords  // capture to silence warning
                    let result = await Self.runOne(
                        chunk: chunk,
                        llmService: llmService,
                        config: config,
                        speakerId: speakerId
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
                    group.addTask { [llmService] in
                        let result = await Self.runOne(
                            chunk: chunk,
                            llmService: llmService,
                            config: config,
                            speakerId: speakerId
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

    private static func runOne(
        chunk: Chunk,
        llmService: LLMServiceProtocol,
        config: SubtitleExportConfig,
        speakerId: String?
    ) async -> ChunkResult {
        let prompt = buildPrompt(chunk: chunk, config: config)
        let response: String
        do {
            response = try await llmService.transform(text: prompt, prompt: systemPrompt)
        } catch {
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
        switch LayoutPlanParser.parse(response, words: chunk.words, perCueBudget: perCueBudget) {
        case .success(let ranges):
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
        case .failure:
            return ChunkResult(
                chunkStartIndex: chunk.startIndex,
                chunkEndIndex: chunk.endIndex,
                cues: nil
            )
        }
    }

    // MARK: - Prompt

    private static let systemPrompt = """
        You are a subtitle captioning specialist. You decide where to break a spoken transcript into subtitle cues.
        You receive a numbered list of words from one section of a transcript and a set of layout rules.
        You return ONLY a JSON object with the shape {"cues":[{"start":<int>,"end":<int>}, ...]} — no commentary, no markdown fences, no explanation.
        Each "start" and "end" is the inclusive word index into the input list.
        You never modify the words and you never invent text. You only choose where the cue boundaries go.
        Every input word must appear in exactly one cue. Cues must be contiguous and non-overlapping.
        """

    private static func buildPrompt(chunk: Chunk, config: SubtitleExportConfig) -> String {
        // `maxCharsPerLine` is the TOTAL cue budget across all rendered
        // lines (not a per-line cap) — same semantics as the deterministic
        // builder and the wrap pass. Earlier this multiplied by
        // `maxLinesPerCue`, which let the LLM produce ~128-char cues at a
        // configured 65-char budget. SRT (17), block 15 was the smoking gun.
        let perCueBudget = config.maxCharsPerLine
        let perLineHint = max(10, config.maxCharsPerLine / max(1, config.maxLinesPerCue))

        var lines: [String] = []
        lines.append("RULES:")
        lines.append("- Max characters PER CUE (total across both lines): \(perCueBudget).")
        lines.append("- Max lines per cue: \(config.maxLinesPerCue).")
        lines.append("- Implied per-line cap: ~\(perLineHint) characters.")
        lines.append("- Each cue must end at a natural break: sentence terminator (.!?), comma/clause boundary (,;:), or end of a phrasal verb.")
        lines.append("- NEVER end a cue with a conjunction (and, but, or, so, yet, for, nor), article (the, a, an), determiner (this, that, these, those), preposition (in, on, at, to, of, with, from, by), auxiliary verb (is, are, was, were, be, been, being, have, has, had, do, does, did, will, would, can, could, should).")
        lines.append("- NEVER start a cue with a comma or a conjunction.")
        lines.append("- Respect sentence integrity: do NOT pack the end of one sentence (`.!?`) with the start of the next sentence inside the same cue. Always break between sentences.")
        lines.append("- Keep number ranges intact: do not split inside \"between X and Y\", \"X to Y\", \"from X to Y\".")
        lines.append("- Keep phrasal verbs intact: \"welcome in\", \"slow down\", \"bring up\", \"reach down\", \"take it up\", etc.")
        lines.append("- Every word index from 0 to \(chunk.words.count - 1) must appear in exactly one cue.")
        lines.append("- Cues must be contiguous: cues[i].start == cues[i-1].end + 1.")
        lines.append("- Cues must be in order: ascending start indices.")
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
