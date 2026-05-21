# LLM-driven subtitle cue layout

## Context

After many iterations of rule-based tuning, SRT exports of long Parakeet
transcripts plateaued at "comparable to YouTube auto-captions" quality
— still ~370 cues for a 30-min transcript with occasional cross-sentence
packing and mid-clause splits.

Investigation of the 2026 ML landscape (see exploration above) found that
purpose-built caption-segmentation models don't really exist off the
shelf — commercial caption tools (Speechmatics, AssemblyAI, Rev) all use
LLMs internally for caption layout. The honest next step is to do the
same: let the LLM decide cue boundaries given the user's budget and the
word stream, instead of just polishing text inside pre-built cues.

The existing `SubtitleLLMRefiner` (per-cue text polish) is replaced.

## Approach

Add a `SubtitleLLMLayoutPlanner` actor that:

1. Receives `[WordTimestamp]`, `[SentenceUnit]` (already built by Track A),
   the `SubtitleExportConfig`, and an `LLMServiceProtocol`.
2. Chunks the word array into ~80-word groups aligned to sentence-unit
   boundaries (never cuts a chunk mid-sentence).
3. For each chunk in parallel (capped concurrency, like the old refiner):
   - Builds a prompt: numbered word list + cue-layout rules + JSON
     output schema.
   - Calls `llmService.transform(...)`.
   - Parses the JSON, validates that the returned ranges cover every
     input word exactly once with no overlaps.
   - On any failure (network error, malformed JSON, coverage mismatch),
     surfaces a sentinel so the caller can fall back to the deterministic
     builder for that chunk.
4. Stitches the per-chunk cues together and returns `[ExportService.SubtitleCue]`.

The LLM **only chooses split points** — it never controls cue text or
timing. Cue text is built from our `WordTimestamp` array by index; cue
start/end ms come from `words[start].startMs` / `words[end].endMs`.
Hallucination is impossible at the data level; the LLM can only pick
poor split points, which would still produce valid cues.

`ExportService.formatSRT/VTT (async)` is rewired so that when
`config.useLLMRefinement && llmService != nil`:

  - Build sentence units (unchanged).
  - Try `SubtitleLLMLayoutPlanner.plan(...)`.
  - On success → use those cues, skip Phase 3 splitting, run only the
    post-processing passes (absorb, end-buffer, frame-snap, monotonic).
  - On failure → fall through silently to the existing deterministic
    builder (current code path). Per-chunk fallback is fine; the planner
    returns `[Result<...>]` so partial success works.

The existing UI toggle stays as **"Use AI Refinement"** for now — same
control, new meaning (layout instead of text polish). We can rename the
copy in a follow-up commit once the behavior is shipped.

## Critical files

### New, all under `Sources/MacParakeetCore/Services/Subtitle/`:

- `SubtitleLLMLayoutPlanner.swift` — public actor, the planner.
- `LayoutChunk.swift` — internal value type: a contiguous run of words +
  a list of `SentenceUnit` boundaries inside it.
- `LayoutPlanParser.swift` — pure parser/validator for the LLM JSON
  response. Exposed for testing.

### Modified:

- `Sources/MacParakeetCore/Services/ExportService.swift`:
  - The two async `formatSRT/formatVTT(words:speakers:config:includeSpeakerLabels:llmService:onRefinementProgress:cleanedTranscript:engineSegments:)`
    methods consult the planner before falling back.
  - Existing `SubtitleLLMRefiner` calls removed from these paths.
- `Sources/MacParakeetCore/Services/SubtitleLLMRefiner.swift`:
  - Stays in the tree (don't delete in same change; mark as deprecated
    in a comment so a follow-up can remove it once the new planner is
    proven on real exports).

### Reused (no edits):

- `SubtitleSentenceSegmenter` / `SentenceUnit` / `SubtitleSentenceAligner`
  — provide the sentence units that drive chunk boundaries.
- `WordTimestamp` (`Sources/MacParakeetCore/Models/Transcription.swift:145`).
- `LLMServiceProtocol.transform(text:prompt:)` — same call shape as the
  refiner uses today.
- All `ExportService` post-processing passes (`absorbShortNeighbours`,
  `applyEndTimeBuffer`, `applyFrameSnap`, `enforceMonotonicCues`,
  `wrapSubtitleText`).

## Prompt + JSON schema (initial)

System prompt:
```
You are a subtitle captioning specialist. You decide where to break a
spoken transcript into subtitle cues. You receive a list of words from
one section of a transcript and a set of layout rules. You return the
list of cue ranges as JSON. You never modify the words or timing.
```

User-content shape:
```
RULES:
- Max characters PER CUE (total across lines): {N}
- Max lines per cue: {M}
- Each cue must end at a natural break (sentence terminator, comma,
  clause boundary, end of phrasal verb).
- Never end a cue with a conjunction, article, determiner, preposition,
  or auxiliary verb.
- Never start a cue with a comma or conjunction.
- Respect sentence integrity: do NOT span a `.!?` into the next sentence.
- Every word index 0..{lastIdx} must appear in exactly one cue.
- Cues must be contiguous and non-overlapping.

WORDS:
[0] What
[1] is
[2] going
...

OUTPUT — JSON only, no commentary, no markdown fences:
{
  "cues": [
    {"start": 0, "end": 4},
    {"start": 5, "end": 13},
    ...
  ]
}
```

## Validation rules

For each LLM response per chunk:

1. Parse as JSON; non-JSON → fallback.
2. Must contain `cues: [{start, end}]`. Schema mismatch → fallback.
3. Every cue must satisfy `0 <= start <= end < wordCount`.
4. Cue ranges must be in ascending order and contiguous: `cues[i].start == cues[i-1].end + 1`.
5. First cue must start at 0, last cue must end at `wordCount - 1`.
6. Each cue's joined text must be ≤ `maxCharsPerLine * maxLinesPerCue + tolerance` (cap = ~1.15×). Allows mild overflow but rejects egregious budget violations.

Any violation → return `LayoutFailure` for that chunk; caller falls back.

## Implementation order

1. `LayoutChunk.swift` + `LayoutPlanParser.swift` + their tests (pure logic,
   no LLM dependency).
2. `SubtitleLLMLayoutPlanner.swift` actor with mock-LLM tests covering
   happy path, malformed JSON, coverage gap, range overlap.
3. Wire into `ExportService.formatSRT/VTT (async)`. Initially fall through
   to deterministic builder for ALL chunks (planner disabled) — confirm
   no regression.
4. Enable planner; verify the regression suite is green.
5. Rebuild dev app; re-export the Marc Penna test SRT with AI Refinement
   toggled ON; verify quality.

## Verification

**Unit tests:**
- `LayoutPlanParserTests`:
  - Valid JSON with contiguous coverage → succeeds.
  - Missing `cues` key → fails.
  - Range out of bounds → fails.
  - Non-contiguous coverage → fails.
  - Negative start → fails.
  - Cue text overflow > 1.15× → fails.
- `SubtitleLLMLayoutPlannerTests`:
  - Mock LLM returns valid JSON → produces expected cues with correct timing.
  - Mock LLM returns malformed JSON → planner reports failure for that chunk.
  - Mock LLM throws → planner reports failure.
  - Chunking: 200 words split into ~3 chunks of ~80 words each.

**End-to-end:**
- Re-transcribe and export the Marc Penna 30-min test video with AI
  Refinement ON. Expect:
  - Cue boundaries land on punctuation / clause breaks, not mid-clause.
  - No cross-sentence cues.
  - Total cue count comparable to or better than current ~368.

## Risks and mitigations

- **LLM hallucination of indices** — coverage validation rejects.
- **LLM hallucinates words / timing** — impossible by construction; we
  build cue text + timing from our `WordTimestamp` array indexed by the
  LLM's ranges, never from the LLM's prose.
- **Cost / latency** — chunking limits per-call size; concurrency limit
  caps in-flight requests. Roughly comparable to existing per-cue
  refiner cost (~5–10 calls per 30 min transcript vs ~50).
- **Small-model malformed JSON** — fallback to deterministic builder is
  silent and per-chunk; user always gets a cue file.
- **`SubtitleLLMRefiner` becoming dead code** — keep it for one release
  cycle in case we need to revert. Follow-up commit removes it.
