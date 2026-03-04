# ADR-004: Deterministic Text Processing Pipeline Over LLM-Based Refinement

> Status: **Accepted**
> Date: 2026-02-08
> Note: Core decision (deterministic pipeline for default processing) unchanged and strengthened. LLM-powered modes (formal, email, code, command) referenced below were removed 2026-02-23 — only raw and clean modes remain.

## Context

Raw STT output -- even from a high-quality model like Parakeet TDT 0.6B-v3 -- benefits from post-processing. Common issues include:

- Filler words ("um", "uh", "like", "you know")
- Minor casing errors (proper nouns, sentence starts after pauses)
- Abbreviation handling ("API" vs "a p i", "SQL" vs "sequel")
- Domain-specific vocabulary (product names, technical terms)
- Text expansion needs (custom snippets like "my address" to full address)

Two approaches exist for this cleanup:

1. **LLM-based refinement**: Pass raw text through a language model (local Qwen3-8B or cloud GPT-4) to clean, reformat, and improve it.
2. **Deterministic pipeline**: Apply rule-based transformations in a fixed order -- filler removal, casing fixes, custom word corrections, snippet expansion.

## Decision

Use a **deterministic 4-step pipeline** for the default "clean" processing mode. Reserve LLM processing for advanced modes (formal, email, code) and command mode, where users explicitly opt into LLM latency for higher-quality output.

### Pipeline Steps (in order)

| Step | What It Does | Example |
|------|-------------|---------|
| 1. Filler removal | Strip filler words and phrases | "um so like the API" -> "the API" |
| 2. Custom word replacement | User-defined vocabulary anchors and corrections | "kube" -> "Kubernetes", "mac parakeet" -> "MacParakeet" |
| 3. Snippet expansion | Trigger phrase text expansion | "my address" -> "123 Main St, Springfield, IL 62704" |
| 4. Whitespace cleanup | Collapse spaces, fix punctuation spacing, capitalize | "hello   world ." -> "Hello world." |

### Processing Modes

| Mode | Pipeline | LLM | Latency | Use Case |
|------|----------|-----|---------|----------|
| Raw | None | No | 0ms | Verbatim transcription |
| **Clean (default)** | **4-step** | **No** | **<5ms** | **General dictation** |
| Formal | 4-step | Yes (Qwen3-8B) | 2-5s | Professional writing |
| Email | 4-step | Yes (Qwen3-8B) | 2-5s | Email composition |
| Code | 4-step | Yes (Qwen3-8B) | 2-5s | Code dictation |
| Command | None | Yes (Qwen3-8B) | 2-5s | System commands, app control |

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

The deterministic pipeline runs in under 5ms. LLM-based refinement adds 2-5 seconds (model loading on first call, then 1-3s per inference). This latency is acceptable for advanced modes where users explicitly choose to wait, but unacceptable for the default dictation flow.

### User control via custom words and snippets

The deterministic pipeline includes two user-configurable features:

- **Custom words**: Users define vocabulary anchors (ensure "PostgreSQL" not "post gress q l") and corrections (always replace "kube" with "Kubernetes"). These are predictable and immediate.
- **Text snippets**: Users define natural language trigger phrases ("my address" expands to their full address, "my signature" expands to their email sign-off). Triggers are spoken phrases — not abbreviations — because STT outputs natural speech. These are instant and deterministic.

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
- Advanced modes (formal, email, code) still require LLM, with associated latency

### Implementation Notes

- Pipeline is a pure function: `String -> String`, easily testable
- Each step is independent and composable
- Custom words and snippets stored in SQLite (same database as other app data)
- Settings UI for managing custom words and snippets
- CLI commands for managing words and snippets (scripting-friendly)

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
