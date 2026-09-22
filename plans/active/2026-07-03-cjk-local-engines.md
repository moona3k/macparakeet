# CJK local coverage — Parakeet Japanese + SenseVoiceSmall

> Status: **TODO** (benchmark gate decides ship/kill per model)
> Date: 2026-07-03
> Governing decision: [ADR-026 §3](../../spec/adr/026-asr-engine-strategy.md) — roadmap item 2
> Sequencing: prefer after capability-registry Phase A; each model is an
> independent slice — ship whichever passes its gate, in either order.

## Goal

First-class local Korean/Japanese/Chinese without sending users to
Whisper. Today Parakeet v3 outright fails CJK (romanizes to gibberish,
per the ADR-001 benchmark amendment) and Whisper is the only working
option (FLEURS CER: ko 6.37 / ja 13.42 / zh 11.56). Korea is a known
user cluster we currently serve badly. Our pinned FluidAudio 0.15.4
already ships both candidate models — **Parakeet TDT Japanese**
(`AsrModelVersion.tdtJa`) and **SenseVoiceSmall** (`SenseVoiceManager`;
zh/yue/en/ja/ko) — no dependency upgrade needed.

## Slice 0 — harness enablement (prerequisite; the gate cannot run today)

The FLEURS runner (`benchmarks/asr/run_macparakeet_fleurs.py`) hardcodes
the four current engines and shells out to `macparakeet-cli transcribe`,
which cannot name SenseVoice or Parakeet-JA (and `--engine parakeet
--language ja` silently resolves to language-nil Parakeet). Add a
harness-side FluidAudio runner (or provisional, clearly-temporary CLI
adapters) for `SenseVoiceManager` and `AsrModelVersion.tdtJa`, and wire
the runner/manifest. Harness code only — no app surface.

## Benchmark gate (kills or orders everything else)

Run both models on FLEURS ko/ja/zh (CER — the harness already
character-scores CJK in `score_multi.py`) plus LibriSpeech en (WER
sanity); assets at `~/asr-bench`, harness merged #561/#568. Ship bar, per language: **beat or match Whisper Large v3
Turbo's CER** with paired-bootstrap honesty (the #568 methodology — no
CI-overlap eyeballing). Also record model size, load time, and peak RSS;
a model that wins accuracy but costs multi-GB resident is a different
product decision (cf. Cohere).

Expected outcome to test, not assume: SenseVoiceSmall covers ko/zh (+ja),
Parakeet-JA wins ja. If SenseVoice wins everywhere, Parakeet-JA may be
unnecessary — dropping a model is a success, not a failure.

## Product shape

- These are **variants, not new cards** (ADR-026 §3). Design intent:
  the user picks a language (or language auto-detection where the model
  supports it) and the app maps it to the right local model — mirroring
  how Parakeet v2/v3/Unified already present as variant rows.
- **Known structural gap — design before product code:** the current
  selection model doesn't stretch to language-routed local models.
  `SpeechEngineSelection` always nils Parakeet's language,
  `ParakeetModelVariant` knows only v3/v2/unified, and the FluidAudio
  bridge (`ParakeetModelVariant+ASR`) collapses every non-v2 model back
  to `.v3`. A short written variant-axis design (where these models live
  in `SpeechEngineSelection`, persistence, and the bridge) is a
  deliverable of this plan, reviewed before the product slice starts.
  Capability-registry Phase A is a **hard prerequisite for the product
  slice** (Slice 0 + benchmarks are independent and can run first).
- **One open product decision for Daniel** (bring benchmark numbers):
  where SenseVoiceSmall lives in the UI, since it is not Parakeet-branded.
  Recommendation: keep the four cards; present it as an additional model
  row under the fast-local card with honest naming, and update card copy
  from "Whisper: Korean, Japanese, Chinese" once local CJK exists.
- Downloads on demand like other variants; deletable; capability
  registry rows declare language coverage so Settings/CLI copy is
  generated, not hand-written.
- Whisper stays untouched — it remains the fallback for the long tail
  (ADR-026 §5); this plan only has to beat it on ko/ja/zh.
- CLI parity: language/engine mapping exposed via existing
  `--engine`/`--language` surface; `spec/contracts/` + CLI CHANGELOG in
  the same PR.

## Acceptance

- Benchmark report committed (same convention as the ADR-001 amendment
  evidence) with per-language ship/kill verdicts.
- For each shipped model: variant selection, download/delete lifecycle,
  dictation + file + meeting paths, and capability-gated UI copy — with
  focused tests at the same surfaces the Nemotron variants test today.
- A Korean or Japanese dictation smoke on a real machine before release
  (Daniel or a native-speaker user; note it in the PR).
