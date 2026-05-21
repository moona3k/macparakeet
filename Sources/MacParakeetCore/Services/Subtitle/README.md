# Subtitle subsystem

This folder owns the *structural* side of subtitle export — deciding which
words belong in which cue — separately from the rendering/text-formatting
work that lives in `ExportService` proper.

## Files

- `SentenceUnit.swift` — value type. A contiguous slice of `[WordTimestamp]`
  that the segmenter has decided belongs to one natural-language unit
  (typically a sentence). `wordCount`, inclusive `startIndex`/`endIndex`,
  `endsWithStrongPunctuation`.
- `SubtitleSentenceAligner.swift` — pure helper that joins a word array into
  a single string with known per-word character spans, and translates
  `NSRange` back to inclusive word indices. Used only by the segmenter; kept
  separate so it can be fuzz-tested in isolation.
- `SubtitleSentenceSegmenter.swift` — runs `NLTokenizer(unit: .sentence)` on
  the joined word stream, merges honorific-trailing units into their
  successor, and splits any remaining over-long units at any internal silence
  ≥ `longPauseMs` (default 1500 ms) so unpunctuated speech still segments.

## Why this exists

Parakeet (the default STT engine) returns only per-word timing data. Before
this subsystem, `ExportService.buildSubtitleCues` derived cue boundaries
from inter-word silence alone — every gap > 800 ms triggered a flush. Long
30-minute transcripts had ~1500 such pauses, and many of them produced
1-word orphan cues that `mergeOrphanedCues` then refused to absorb because
the same 800 ms threshold blocked the merge. Self-protecting fragmentation.

Switching to NLTokenizer for the primary segmentation signal:
- Sentence boundaries are the natural unit for caption layout.
- Mid-sentence pauses no longer create cue boundaries.
- The `mergeOrphanedCues` pass works as intended again — orphans that do
  appear are mergeable because they're not stranded behind a long silence.

## Invariants

- **Word-count preservation**: `Σ (unit.endIndex − unit.startIndex + 1)` over
  all units MUST equal the source `words.count`. Every test asserts this.
- **Contiguity**: `units[i].startIndex == units[i-1].endIndex + 1`.
- **No empty units**: `wordCount >= 1` always.

If any of these break, downstream cue building will lose or duplicate words.

## Not in scope here

- Text wrapping, line breaks, character budgets — owned by `ExportService`'s
  per-unit phase logic (Phases 2/2.5/3/4/5).
- LLM-driven text polish — `Sources/MacParakeetCore/Services/SubtitleLLMRefiner.swift`
  consumes already-built cues and only rewrites cue *text*.
- Reading-speed enforcement, frame snapping, end-time buffer — all post
  passes in `ExportService.buildSubtitleCues`.

## Whisper path (Track B, in progress)

When the user opts into WhisperKit, the engine returns its own segment-level
timestamps. The plan is to feed those directly into the per-unit loop in
`ExportService.buildSubtitleCues` instead of running NLTokenizer (Whisper's
segments are already sentence-ish). See `ExportService.swift`'s comment near
`useSentenceUnits` and the plan at
`/Users/Justin/.claude/plans/users-justin-downloads-20260430-1615-ma-curried-pnueli.md`.
