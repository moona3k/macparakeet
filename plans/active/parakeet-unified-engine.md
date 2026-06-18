# Plan: Parakeet Unified (English) as a selectable Parakeet model

> Status: **ACTIVE**
> Issue: #520 (feature request). Branch: `feat/parakeet-unified`.
> Owner-agent: orchestrated by Claude. Living handoff doc — update as work lands.

## 1. Context & motivation

Issue #520 asks for **Parakeet Unified** (`nvidia/parakeet-unified-en-0.6b`,
English-only, 600M Unified-FastConformer-RNNT). The owner is open to it
"if performance is better or competitive to v2."

**Validated claims** (FluidAudio's current benchmark docs and v0.15.4 source,
full LibriSpeech test-clean, 2620 files; cross-checked vs NVIDIA's model card):

| Mode | Unified WER | Reference |
|------|-------------|-----------|
| Offline batch (15s overlapping windows) | **2.15% avg / 1.68% aggregate WER** | NVIDIA card test-clean: 1.63% |
| Streaming @ 2.08s latency | **2.21% avg / 1.79% aggregate WER** | — |
| Parakeet v2 (English, our docs) | ~2.1% | baseline to beat |
| Parakeet v3 (multilingual, our docs) | ~2.5% | — |

So Unified offline is a strong, competitive English opt-in with
punctuation/capitalization, not a silent replacement for v3 and not something to
overclaim as universally better than v2 on every WER metric. Streaming is real
(single model jointly trained for offline + streaming). The "better than
Nemotron for dictation" claim is **speculative** — our own benchmark (task #7)
will test it.

**Caveats to design around:**
1. **No word-level timestamps** on the offline `transcribe([Float])->String`
   path. Our existing Parakeet TDT path surfaces word timings; Unified will
   not. Handle exactly like Nemotron: `STTResult.words = []`.
2. **English only** — a v2 alternative, never a v3 (multilingual) replacement.
   Must never become a silent default that regresses non-English users.
3. **int8 + `.all` compute units**: FluidAudio's manager auto-coerces int8 to
   `.cpuAndNeuralEngine` at load (MPSGraph MLIR abort otherwise). Safe; just
   don't override compute units post-load.
4. Disk ~565 MB int8; preprocessor + per-token decoder run **CPU-only** (ANE
   shape-inference limits) → higher CPU/battery than the pure-ANE TDT path.
5. License: NVIDIA Open Model License Agreement (runtime-downloaded model, not
   bundled — same posture as every other model we fetch).

## 2. Design decision

**Add `.unified` to `ParakeetModelVariant`** so it appears in the Parakeet
model picker alongside v3/v2 (the user's explicit ask: "add to the list of
parakeet models"). Architecturally Unified is **not** a TDT `AsrModelVersion`
— it uses FluidAudio's separate `UnifiedAsrManager` (offline) /
`StreamingUnifiedAsrManager` (streaming) actors. So we cannot reuse the
existing `AsrManager` path; instead route `.unified` inside `STTRuntime`'s
`.parakeet` branch to a **dedicated `ParakeetUnifiedEngine` actor**, mirroring
exactly how the `.nemotron` branch routes its English variant to
`NemotronEnglishEngine` (`isEnglishOnly` check → different manager).

This honors the product framing (a Parakeet model) while isolating the new
runtime in its own wrapper, leaving the stable v2/v3 TDT path untouched except
for the routing fork.

**Scope (Phase 1, this PR):** Unified **offline** only — `UnifiedAsrManager`
(`parakeet-unified-offline-15s`, int8) for **all** transcription jobs (file,
meeting, dictation paste). This uses FluidAudio's benchmarked batch path, a
single model download (~565 MB), and the lowest-risk slice. Live dictation paste
already comes from the stop-time batch path, so it gets the same offline output.

**Out of scope (Phase 2, follow-up, documented not built):** native
low-latency streaming via `StreamingUnifiedAsrManager` (true 2.08s partials +
`consumeTokenTimings()`), which would require extending the live-dictation
gate currently hard-restricted to `.nemotron`. Phase 1 reuses the existing
display-only Parakeet tail-window preview path (when the live-preview flag is
on) so dictation still shows a live preview.

## 3. FluidAudio bump

`Package.swift`: `0.15.2` → `0.15.4` (`.upToNextMinor(from: "0.15.4")`).
Unified landed in v0.15.3 (PR #693 merge commit `3c6e79f1d744`). v0.15.4 is
latest. Verified: **no breaking changes** to our existing `AsrManager`,
`AsrModelVersion`, Nemotron, EOU, or Whisper usage — the additions
(`StreamingModelVariant.parakeetUnified2080ms/Offline15s`,
`EngineFamily.parakeetUnified`, `UnifiedAsrManager`,
`StreamingUnifiedAsrManager`, `UnifiedConfig`, `UnifiedEncoderPrecision`,
`Repo.parakeetUnified`) are purely additive. Re-resolve + full `swift test`
must stay green after the bump (verify before any feature code).

## 4. FluidAudio Unified API (v0.15.4) — reference

- Variant rawValues: `parakeet-unified-offline-15s`, `parakeet-unified-2080ms`.
- `UnifiedAsrManager` (offline actor):
  - `init(configuration:config:encoderPrecision:)` (int8 default)
  - `loadModels(from: URL)` / `loadModels(to:configuration:progressHandler:)`
    (downloads `FluidInference/parakeet-unified-en-0.6b-coreml`, `variant:"offline"`)
  - `transcribe(_ samples: [Float]) async throws -> String`
  - `transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String`
  - `reset()`, `cleanup()`; conforms to `StreamingAsrManager` (batch-on-finish)
- Cache root: `…/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b-coreml/`
- `Repo.parakeetUnified = "FluidInference/parakeet-unified-en-0.6b-coreml"`.
  (Confirm exact folder name + the offline-encoder filename for cache-detection
  statics during implementation — read the v0.15.4 source, do not guess.)

## 5. File-by-file checklist (template: Nemotron-EN PR #503 / commit 2473828f5)

Core engine + preference
- [ ] `Package.swift` — bump FluidAudio to 0.15.4; `swift package resolve`.
- [ ] `Sources/MacParakeetCore/STT/ParakeetUnifiedEngine.swift` (NEW) — actor
      wrapping `UnifiedAsrManager`; mirror `NemotronEnglishEngine` (two-lane
      interactive/background, `transcribe(audioPath:job:onProgress:)`, prepare/
      unload/isReady, static isModelCached/downloadModel/deleteModel/
      defaultCacheRoot, error mapping). `STTResult(engine: .parakeet,
      engineVariant: ParakeetModelVariant.unified.rawValue, words: [],
      language: "en")`.
- [ ] `Sources/MacParakeetCore/SpeechEnginePreference.swift` — add
      `ParakeetModelVariant.unified` + displayName/modelName/coverageSummary/
      approximateDownloadSize/isEnglishOnly(=true)/alternative; add a
      `usesUnifiedEngine`/`isUnified` flag for routing.
- [ ] `Sources/MacParakeetCore/STT/ParakeetModelVariant+ASR.swift` — make the
      `asrModelVersion` bridge safe for `.unified` (return optional / guard;
      `.unified` has no `AsrModelVersion`). Audit callers.

Runtime + scheduler
- [ ] `STTRuntime.swift` — add `parakeetUnifiedEngine` field; in the `.parakeet`
      transcribe path, route `parakeetModelVariant == .unified` →
      `ParakeetUnifiedEngine`; handle warm-up, `setParakeetModelVariant`
      switch to/from unified (download/swap), cache-clear, shutdown. Preview:
      route unified through existing tail-window preview (or no-op gracefully).
- [ ] `STTScheduler.swift` — confirm variant-switch guards cover `.unified`
      (likely generic already; add a test).
- [ ] `STTClient.swift` / `STTClientProtocol.swift` — CLI/test facade parity.
- [ ] `Sources/MacParakeetCore/STT/README.md` — engine inventory.

CLI (public contract — additive)
- [ ] `TranscribeCommand.swift` — `--parakeet-model` accepts `unified`.
- [ ] `ConfigCommand.swift` — `config set parakeet-model unified`.
- [ ] `ModelsCommand.swift` — `models list` row; `models select/download/delete`
      for the unified build.
- [ ] `SpecCommand.swift` (if it enumerates options) + `Sources/CLI/CHANGELOG.md`.

Settings UI / ViewModels (new variant auto-renders in the Parakeet card)
- [ ] `EngineSettingsViewModel.swift` — ensure `.unified` flows through download/
      delete/select + cached checks.
- [ ] `SettingsView.swift` / `SettingsStatusRules.swift` — verify the Parakeet
      Model card renders the third tile + status; adjust copy/size labels.
- [ ] `TranscriptionViewModel.swift` / `TranscriptResultView.swift` — variant
      attribution ("Parakeet Unified") + re-transcribe option.

Telemetry / docs / specs
- [ ] `TelemetryEvent.swift` — allowlist `unified` for the parakeet-model setting.
- [ ] `spec/adr/001-parakeet-stt.md` amendment; `spec/06-stt-engine.md`;
      `spec/02-features.md`; `spec/README.md`; `spec/kernel/requirements.yaml`
      (new REQ-STT-xxx); `CLAUDE.md`; `README.md`; `AGENTS.md` if needed.

Tests
- [ ] `SpeechEnginePreferenceTests` — `.unified` round-trip + isEnglishOnly.
- [ ] `EngineSettingsViewModelTests` — select/download/delete + switch guard.
- [ ] `STTSchedulerTests` — variant-switch-blocks-active-jobs for unified.
- [ ] CLI tests — `--parakeet-model unified`, `config`, `models` round-trips.
- [ ] Mock STT client updates if needed.

## 6. Benchmark (task #7)

- Dataset: LibriSpeech **test-clean** (canonical; what NVIDIA/FluidAudio
  report on). Already downloaded to `~/asr-bench/LibriSpeech/test-clean`.
- Canonical cross-check: FluidAudio `asr-benchmark --subset test-clean
  --parakeet-variant parakeet-unified-offline-15s` (and `...-2080ms`, `v2`,
  `v3`) — identical normalizer to the reported numbers (built at
  `~/asr-bench/FluidAudio-0154`).
- End-to-end proof: MacParakeet CLI `transcribe` with `--parakeet-model
  unified` on a test-clean subset, scored by `~/asr-bench/score_wer.py`
  (dependency-free WER). Confirms our integration produces correct output in
  the right ballpark.
- Commit harness + results under `benchmarks/parakeet-unified/`; post a
  results table in the PR body.

## 7. Verification gate

- `swift build` + full `swift test` green after the FluidAudio bump (before
  feature code) and again after implementation.
- Dev-app / CLI smoke: select Unified, transcribe a real clip, confirm the
  model is used and output is correct.
- No regression to v2/v3/Nemotron/Whisper paths.
