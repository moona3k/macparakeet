# ADR-004: Deterministic Text Processing Pipeline Over LLM-Based Refinement

> Status: **Accepted**
> Date: 2026-02-08
> Note: Core decision (deterministic pipeline for default processing) unchanged and strengthened. LLM-powered modes (formal, email, code, command) referenced below were removed 2026-02-23 — only raw and clean modes remain. Amendment: the pipeline is now five steps after the Voice Return/trailing-action step shipped.

## Context

Raw STT output -- even from a high-quality model like Parakeet TDT 0.6B-v3 -- benefits from post-processing. Common issues include:

- Filler words ("um", "uh", "like", "you know")
- Minor casing errors (proper nouns, sentence starts after pauses)
- Abbreviation handling ("API" vs "a p i", "SQL" vs "sequel")
- Domain-specific vocabulary (product names, technical terms)
- Text expansion needs (custom snippets like "my address" to full address)

Two approaches exist for this cleanup:

1. **LLM-based refinement**: Pass raw text through a language model (local Qwen3-8B or cloud GPT-4) to clean, reformat, and improve it.
2. **Deterministic pipeline**: Apply rule-based transformations in a fixed order -- narrow filler removal, custom word corrections, trailing action extraction, snippet expansion, and whitespace cleanup.

## Decision

Use a **deterministic 5-step pipeline** for the default "clean" processing mode. Only two modes exist: raw (verbatim) and clean (5-step pipeline).

### Pipeline Steps (in order)

| Step | What It Does | Example |
|------|-------------|---------|
| 1. Filler removal | Strip only always-safe hesitation sounds | "um the API" -> "the API" |
| 2. Custom word replacement | User-defined vocabulary anchors and corrections | "kube" -> "Kubernetes", "mac parakeet" -> "MacParakeet" |
| 3. Trailing action extraction | Strip terminal action-snippet triggers and surface a post-paste action | "send this press return" -> text plus Return action |
| 4. Snippet expansion | Trigger phrase text expansion | "my address" -> "123 Main St, Springfield, IL 62704" |
| 5. Whitespace cleanup | Collapse spaces and fix punctuation spacing | "hello   world ." -> "hello world." |

### Processing Modes

| Mode | Pipeline | LLM | Latency | Use Case |
|------|----------|-----|---------|----------|
| Raw | None | No | 0ms | Verbatim transcription |
| **Clean (default)** | **5-step** | **No** | **<5ms** | **General dictation** |

> Note: Formal, Email, Code, and Command modes were removed 2026-02-23 when local LLM (Qwen3-8B) was eliminated. LLM features are now accessed via dedicated service methods (summarize, chat), not processing modes.

## Rationale

### Parakeet already outputs good text

Unlike older Whisper models, Parakeet TDT 0.6B-v3 outputs well-punctuated, well-capitalized text natively. The gap between raw Parakeet output and "clean" text is small -- mostly filler words and occasional casing quirks. A lightweight deterministic pipeline closes this gap without the overhead of an LLM.

### Local LLM is unreliable for simple cleanup

Testing with Qwen3-8B (4-bit quantized) for basic text cleanup revealed:

- **Meaning changes**: The model sometimes rephrases or paraphrases, altering the user's intended words. For dictation, fidelity to the speaker's actual words is paramount.
- **Inconsistency**: The same input can produce different outputs across runs. Users expect deterministic behavior from a "clean" mode.
- **Over-correction**: The model sometimes "improves" text that was already correct, adding formality or changing tone.

A deterministic pipeline, by contrast, does exactly what it's told: remove these fillers, apply these casing rules, substitute these words. Nothing more.

### Latency matters for dictation flow

Dictation is a real-time workflow. Users speak, pause, and expect their words to appear immediately. The latency budget is:

| Component | Latency |
|-----------|---------|
| Audio capture | ~50ms |
| Parakeet STT | 200-500ms |
| **Text processing** | **Must be <50ms** |
| Paste to app | ~10ms |
| **Total** | **<600ms target** |

The deterministic pipeline runs in under 5ms. LLM-based formatting or Transforms can add seconds depending on provider latency. That latency is acceptable only when the user explicitly opts into an LLM surface, and unacceptable for the default deterministic cleanup stage.

### User control via custom words and snippets

The deterministic pipeline includes two user-configurable features:

- **Custom words**: Users define vocabulary anchors (ensure "PostgreSQL" not "post gress q l") and corrections (always replace "kube" with "Kubernetes"). These are predictable and immediate.
- **Text snippets**: Users define natural language trigger phrases ("my address" expands to their full address, "my signature" expands to their email sign-off). Triggers are spoken phrases — not abbreviations — because STT outputs natural speech. These are instant and deterministic.
- **Trailing action snippets**: Users can attach a post-paste action such as Voice Return to a terminal trigger phrase. The pipeline strips the trigger before normal snippet expansion and surfaces the action to the paste layer.

An LLM-based approach would require prompt engineering to respect user-defined words and snippets, with no guarantee of compliance.

## Consequences

### Positive

- Default "clean" mode adds <5ms latency -- effectively instant
- Behavior is 100% predictable and deterministic
- Users can customize via custom words and snippets
- No LLM loading overhead for basic dictation
- Simpler debugging -- pipeline steps are transparent and inspectable
- Works even if LLM model fails to load or is not yet downloaded

### Negative

- Clean mode cannot handle complex transformations (e.g., "rewrite this more formally" requires LLM)
- Custom words require manual setup by users (vs LLM learning from context)
- Pipeline rules are English-optimized; STT supports 25 European languages but clean mode processing (filler removal, snippets) is English-only. Per-language filler lists and rules needed for clean mode in other languages.
- LLM-based features (formatter, summaries, chat, Transforms) are accessed via separate service methods or feature surfaces, not processing modes

### Implementation Notes

- Pipeline is a pure function returning `TextProcessingResult` (`text`, expanded snippet IDs, optional post-paste action), easily testable
- Each step is independent and composable
- Custom words and snippets stored in SQLite (same database as other app data)
- Settings UI for managing custom words and snippets
- CLI `vocab` commands for managing words, snippets, and clean processing (scripting-friendly)

## Prior Art

This decision was validated in the **Oatmeal project** (ADR-012: Clean Processing Pipeline). The Oatmeal/OatFlow dictation feature originally used LLM-based refinement, then switched to a deterministic pipeline after observing the same issues:

- LLM sometimes changed meaning
- Latency was unacceptable for real-time dictation
- Users preferred predictable behavior over "smart" behavior

The Oatmeal implementation (TextProcessingPipeline) had 19 dedicated tests and zero regressions after switching from LLM refinement.

## References

- Oatmeal ADR-012: `spec/adr/012-deterministic-dictation-pipeline.md`
- Oatmeal TextProcessingPipeline: `Sources/OatmealCore/Services/TextProcessingPipeline.swift`
- Parakeet TDT output quality benchmarks: 6.3% WER with native punctuation
