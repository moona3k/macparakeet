# Text Processing

> Deterministic post-processing for raw STT output. No LLM in the
> default path; the AI formatter is opt-in and lives behind a separate
> entry point.

## Entry point

`TextProcessingPipeline` — pure value type, `process(text:customWords:snippets:)`
returns a `TextProcessingResult`. Same input always produces the same
output. This is the function called for every dictation in "clean"
mode.

## What's here

- `TextProcessingPipeline.swift` — the deterministic pipeline. Five
  steps in fixed order; details below.
- `CustomWordReplacer.swift` — pre-compiled, reusable custom-word
  replacement (the step-2 rule). `TextProcessingPipeline.applyCustomWords`
  delegates to it, and the meeting finalizer reuses it to correct a whole
  transcript plus every word token without recompiling regexes per token.
- `TextProcessingResult.swift` — value type returned by the pipeline.
  Carries the cleaned text, the set of expanded-snippet IDs, and an
  optional `postPasteAction` for trailing-action snippets.
- `TextRefinementService.swift` — small coordinator for Raw vs Clean
  text refinement. Raw mode skips full cleanup but still extracts
  trailing action snippets; Clean mode runs `TextProcessingPipeline`.
- `AIFormatter.swift` — supporting prompt/rendering types for the
  opt-in provider-based AI formatter used after deterministic cleanup
  in dictation and file/URL transcription flows.
- `TranscriptDerivers.swift` — derives display-side fields
  (search-friendly text, summaries' rendering helpers, etc.) from
  stored transcripts. Read-only; doesn't mutate the canonical text.

## Cross-references

- ADR-004 — deterministic pipeline over LLM-based refinement. Captures
  the *principle* that default cleanup must be deterministic and
  fast. (The ADR's step table predates the trailing-action step; the
  code below is authoritative on step count.)
- `spec/07-text-processing.md` — narrative spec.
- ADR-011 — the LLM provider model that the separate AI formatter
  rides on.

## What to know before editing

**The five pipeline steps run in this fixed order:**

1. **Filler removal.** Strip conservative hesitation spellings (`uh`,
   `umm`, `uhh`) only. Word-boundary regex, case-insensitive,
   pre-compiled at type level. The list is intentionally short —
   anything longer ("like", "you know", "kind of") changes meaning
   too often to delete by default.
2. **Custom word replacement.** User-defined `CustomWord` entries.
   Replaces matches whole-word, case-insensitive, in the order
   provided. Disabled entries skip silently.
3. **Trailing action extraction.** If the user's text ends with an
   action-snippet trigger (snippet whose `action != nil`), strip the
   trigger from the text and surface the action through
   `postPasteAction` on the result. Done **before** snippet
   expansion so the trigger phrase isn't mangled by step 4.
4. **Text snippet expansion.** Plain text snippets (where
   `action == nil`) replace their trigger phrases with their bodies.
5. **Whitespace cleanup and insertion styling.** Collapse repeated
   spaces, fix punctuation spacing, normalize, then apply the selected
   dictation insertion style. Sentence style preserves the historic
   first-letter capitalization behavior. Inline style removes terminal
   sentence punctuation and lowercases ordinary sentence-initial words
   while preserving acronyms, camelCase, custom vocabulary, and expanded
   snippet casing.

**The order is load-bearing.** Action extraction before snippet
expansion prevents a plain-text snippet from consuming the action
trigger. Don't reorder without writing a test that exercises every
adjacent-step interaction.

**The pipeline is a pure function.** No I/O, no side effects, no
state. This makes it trivial to test exhaustively (see
`Tests/MacParakeetTests/`) and means you should not introduce
file/network/logging into the steps. If you need observability, do
it at the call site, not inside the pipeline.

**Filler removal is intentionally narrow.** Any expansion of the
`alwaysSafeFillers` list needs a thoughtful test case demonstrating
it doesn't change meaning in every supported language. Portuguese and
German use `um` semantically, so it is preserved even though English
speakers may use the same spelling as a hesitation.

**The AI formatter is a different code path.** `TextRefinementService`
does not call an LLM. It returns deterministic cleanup (plus any
post-paste action) first; dictation and transcription services may
then invoke the opt-in AI formatter through `LLMService`. Don't
conflate those two stages — the deterministic pipeline must remain
LLM-free per ADR-004.

**Meetings reuse only the custom-word step, not the whole pipeline.**
`MeetingTranscriptVocabularyApplier` (in `Services/MeetingRecording/`)
applies `CustomWordReplacer` to a finalized meeting transcript's plain
text and word tokens (REQ-PIPE-003). It deliberately does **not** run
filler removal, snippet expansion, or insertion styling — those are
dictation-paste concerns that would corrupt a verbatim meeting record.
Meeting correction is always-on (not gated on Raw/Clean) because the
default processing mode is Raw and the word tokens it fixes drive the
speaker-segmented view and exports. Keep custom-word semantics in
`CustomWordReplacer` so dictation, file/URL, and meetings stay in sync.

## How to verify a change

- `swift test --filter TextProcessing` — covers the pipeline at the
  step level and end-to-end. Add a focused test for any new behaviour
  before changing the pipeline body.
- `swift test` — full suite (~100 s). Pipeline regressions ripple
  into transcription tests because every dictation runs through it.
- Manual: dictate something with each kind of trigger (filler word,
  custom word, text snippet, action snippet) and confirm the result
  is unsurprising. Edge cases worth checking: empty input, input
  that's only fillers, snippet that expands into another snippet's
  trigger (we do not recurse on purpose).
