# Apple SpeechTranscriber spike (macOS 26) — evaluate, don't integrate

> Status: **TODO** (small, self-contained; output is a report, not a feature)
> Date: 2026-07-03
> Governing decision: [ADR-026 §6](../../spec/adr/026-asr-engine-strategy.md)
> Evidence context: [`docs/research/2026-07-03-asr-landscape-verified.md`](../../docs/research/2026-07-03-asr-landscape-verified.md)
> (no public WER benchmarks exist; a naive `supportedLocales` probe returned 0)

## Goal

Answer, with measurements, whether Apple's SpeechAnalyzer/SpeechTranscriber
earns a future role as (a) an onboarding bridge — instant dictation on
macOS 26 while the ~465 MB Parakeet download runs — and/or (b) a long-tail
language fallback. **Deliverable is a written report + go/no-go, shipped as
a docs PR.** No engine card, no settings surface, no product wiring.

## Questions to answer (all of them; each gets a number or a "blocked-by")

1. **Asset reality.** On a clean macOS 26 machine: what does
   `SpeechTranscriber.supportedLocales` return, what triggers
   `AssetInventory` model download, how big/fast is it, and does it work
   without our app bundling anything? (Our earlier probe returned 0
   locales — determine why: missing assets, entitlement, or API misuse.)
2. **Quality.** Build a small macOS-26-only runner binary/script the
   harness can shell out to (the existing FLEURS runner drives
   `macparakeet-cli`, which cannot name this engine — so this is new
   harness-side code, not a manifest entry; still zero app code) and run
   LibriSpeech clean/other + FLEURS en/ko/ja/zh. Compare against the ADR-001 amendment table (Parakeet
   2.38-3.22 WER, Whisper 3.00). This produces the first real
   SpeechTranscriber WER numbers we know of — write them up regardless of
   outcome; it's citable research either way.
3. **Latency + streaming fit.** Volatile-partials cadence and finalization
   latency on live mic input; does its streaming API shape fit our
   `NativeLiveDictating` protocol (partials + final), and what does
   first-transcription cold-start cost?
4. **Constraints inventory.** `contextualStrings` limits, on-device
   guarantee (confirm no network at transcribe time via a network-denied
   run), process-memory accounting, macOS 26 API availability gating cost
   in a codebase that back-deploys to macOS 14.

## Go/no-go rubric (pre-committed so the report can't be vibes)

- **Onboarding bridge**: viable if cold-start-to-first-word < Parakeet's
  remaining download time on a typical connection AND en WER is within
  ~2× Parakeet's. Otherwise: not viable, revisit next macOS release.
- **Long-tail fallback**: viable only if it beats Whisper on ≥2 of the
  FLEURS non-en languages tested or covers locales we otherwise lack.

## Boundaries

An acceptable outcome for any question is a documented "blocked-by"
(e.g. no supported locales/assets enumerable on the test machine) —
that verdict is itself the answer for this macOS cycle; do not burn the
timebox fighting asset plumbing.

Timebox: ~2 days. No `SpeechEnginePreference` case, no registry row, no
UI. If the answer is "go", the follow-up is a fresh plan + likely an
ADR-026 amendment — not scope creep inside this spike.
