# Parakeet custom vocabulary (names/jargon boosting)

> Status: **TODO** (Phase 0 investigation first; product decision gate in §4)
> Date: 2026-07-03
> Governing decision: [ADR-026 §3](../../spec/adr/026-asr-engine-strategy.md) — roadmap item 1
> Sequencing: prefer after capability-registry Phase A
> ([2026-07-03-stt-capability-registry.md](2026-07-03-stt-capability-registry.md));
> may proceed before it if the registry stalls, at the cost of one more
> switch-site migration later.

## Goal

Users can maintain a vocabulary list (names, product terms, jargon) that
measurably improves recognition of those terms in dictation — the single
most common accuracy complaint class, and the clearest moat against
Apple's free zero-download engine (which offers only generic
`contextualStrings`).

## Phase 0 — verify the mechanism (do this before any product code)

Our pinned FluidAudio 0.15.4 already ships the API — no upgrade needed:
`CustomVocabularyContext`/`CustomVocabularyTerm`, exposed via
`SlidingWindowAsrManager.configureVocabularyBoosting(...)`. Note it is
**not** a parameter on the plain `AsrManager` file/buffer transcribe
calls MacParakeet uses today (those only carry `language`). Resolve,
with a throwaway harness (not app code):

1. The mechanism in practice: load-time vs per-request boosting; list
   size limits; scoring knobs; and — the key seam decision — how our
   offline/live TDT paths reach it (adopt `SlidingWindowAsrManager`?
   side-load a CTC model next to TDT?) while preserving the shared ANE
   gate and the dictation trailing-silence behavior (#562).
2. Whether boosting applies only to the CTC models or also to
   TDT/Unified — i.e. is custom vocab a *property of the default engine*
   or a *separate variant* users must switch to. This determines the
   whole product shape.
3. Quality: on a small self-recorded eval set of ~50 utterances
   containing OOV names/terms, measure term recall with and without the
   keyword list, and overall WER on LibriSpeech clean (must not regress
   >0.3pt absolute vs the same model without keywords).

If the mechanism only works on the 110M CTC model and its base WER is
far off our default, write that up and stop — the plan dies cheaply.

## Product shape (after Phase 0)

- **Reuse the existing vocabulary feature — mandatory, not optional.**
  The app already has a user-facing dictionary: `CustomWord` /
  `CustomWordRepository` (GRDB `custom_words`), the Vocabulary Settings
  UI (`CustomWordsView`), `TextProcessingPipeline` custom-words handling,
  and CLI `vocab words`. Blank-replacement entries already mean "exact
  spelling" — map enabled words (blank replacement) into FluidAudio
  `CustomVocabularyTerm`s. Do NOT add a second list or store; this
  feature upgrades the existing one from post-hoc text correction to
  recognition-time boosting.
- Applies wherever the active engine supports it; capability-registry
  flag (`supportsCustomVocabulary`) gates UI copy so unsupported engines
  say so honestly.
- CLI parity per repo rule: the existing `vocab words` surface carries
  the list; if transcribe-time behavior changes, update
  `spec/contracts/` + CLI CHANGELOG in the same PR.
- No cloud, no telemetry of vocabulary *content* ever; a count-only
  telemetry property is acceptable if allowlisted (two-repo change).

## Decision gate for Daniel (surface after Phase 0, before product code)

If custom vocab requires switching to a CTC variant (not the default
TDT/Unified): is a "boosted accuracy for your terms" variant worth a
variant row, or do we hold until FluidAudio supports it on the default
family? Bring Phase 0 numbers to that decision.

## Acceptance

- Term-recall improvement demonstrated on the eval set (report numbers in
  the PR); no default-path WER/latency regression beyond the bound above.
- Vocabulary stays in the existing `custom_words` store (one source of
  truth), survives engine switches, and is applied on next load without
  restart (or the restart requirement is stated in UI copy).
- Focused tests: persistence, engine-capability gating, CLI contract.
