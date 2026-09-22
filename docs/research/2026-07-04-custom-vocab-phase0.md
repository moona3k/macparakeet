# Custom Vocabulary Phase 0

Date: 2026-07-04
Branch: `custom-vocab-phase0`
Scope: investigation only. No app or CLI product code changed.

## Verdict

FluidAudio 0.15.4 custom vocabulary boosting is useful for MacParakeet's
Parakeet TDT path, but not as a standalone CTC transcription variant. The
working mechanism is TDT transcription plus an auxiliary CTC 110M keyword
spotter/rescorer pass over the same audio and TDT token timings. In the
synthetic OOV set, TDT v3 exact term recall moved from 11/50 (22%) to 37/50
(74%) with a stricter `minSimilarity=0.65`; the same stricter setting kept full
LibriSpeech `test-clean` WER within the Phase 0 guard, 2.312% -> 2.414%
(+0.102 pt absolute). FluidAudio's vocabulary-size default for this 50-term
list (`minSimilarity=0.55`) was too permissive in this harness: it hit 84% OOV
term recall, but failed the first-200 LibriSpeech guard by +1.198 pt and made
52 false vocabulary replacements.

Unified is not ready for the same feature through its public vocabulary API. The
CTC sidecar can detect terms for Unified audio, but the Phase 0 probe had no
Unified rescorer hook, so it could not apply corrections. On the 50-file OOV
set, Unified no-vocab and vocab-requested output were byte-for-byte identical
and recall stayed 13/50 (26%). MacParakeet later wired FluidAudio's Unified
streaming token timings for exports and speaker alignment; that does not by
itself create a recognition-time vocabulary boosting hook.

## Governing Inputs

- The Phase 0 plan asks for mechanism, model applicability, and quality evidence
  before product code, and sets the WER failure bound at >0.3 pt absolute on
  LibriSpeech clean (`plans/active/2026-07-03-parakeet-custom-vocabulary.md`,
  lines 19-43).
- The product decision gate asks whether a CTC-only implementation is worth a
  variant row, or whether to hold for support on the default family
  (`plans/active/2026-07-03-parakeet-custom-vocabulary.md`, lines 65-70).
- ADR-026 section 3 says new ASR work should grow as variants, not new cards,
  and that the ASR benchmark harness decides accuracy copy
  (`spec/adr/026-asr-engine-strategy.md`, lines 75-96).
- `Package.resolved` pins FluidAudio `0.15.4`, revision
  `b9d43724cbdb5a980e441fd54180964e94d470f7` (`Package.resolved`, lines
  13-18). I did not upgrade FluidAudio.

## Source Findings

FluidAudio 0.15.4 has the public vocabulary types, but the effective path is CTC
sidecar rescoring, not a decode-time parameter on our current `AsrManager`
calls.

- `CustomVocabularyTerm` carries `text`, optional `weight`, optional `aliases`,
  optional TDT token IDs, and optional CTC token IDs
  (`.build/checkouts/FluidAudio/.../CustomVocabularyContext.swift`, lines
  3-14).
- `CustomVocabularyContext` exposes the main knobs: `alpha`, `minCtcScore`,
  `minSimilarity`, `minCombinedConfidence`, and `minTermLength`
  (`CustomVocabularyContext.swift`, lines 72-99).
- `loadWithCtcTokens(...)` loads the CTC models, loads a simple one-term-per-line
  vocabulary file, tokenizes with the CTC tokenizer, and defaults to
  `.ctc110m` (`CustomVocabularyContext.swift`, lines 235-275).
- `SlidingWindowAsrManager.configureVocabularyBoosting(...)` is a load/session
  configuration call. It stores the vocabulary, creates a `CtcKeywordSpotter`,
  and creates a `VocabularyRescorer` using size-aware config
  (`SlidingWindowAsrManager.swift`, lines 91-115).
- Streaming rescoring requires non-empty TDT token timings, runs CTC inference on
  window samples, and calls `ctcTokenRescore(...)` with `cbw`, `marginSeconds`,
  and `minSimilarity` (`SlidingWindowAsrManager.swift`, lines 578-630).
- FluidAudio's own Parakeet file-mode CLI already demonstrates the per-request
  batch seam: transcribe with TDT, then if `--custom-vocab` is present, load CTC
  models, spot keywords on the samples, and rescore the TDT transcript/token
  timings (`TranscribeCommand.swift`, lines 457-507).
- The same CLI uses `SlidingWindowAsrManager.configureVocabularyBoosting(...)`
  for streaming mode (`TranscribeCommand.swift`, lines 652-661).
- Plain TDT `AsrManager.transcribe(...)` APIs accept buffer/URL/samples plus
  decoder state and language, with no vocabulary argument (`AsrManager.swift`,
  lines 353-379 and 478-482).
- Unified now has a streaming token-timing surface for transcription output, but
  FluidAudio still does not expose a Unified vocabulary-rescoring hook equivalent
  to the TDT-plus-CTC path.
- FluidAudio's CTC model source explicitly warns that greedy CTC decoding is not
  the product path: `ctc110m` greedy is blank-dominant at about 113% WER, while
  the recommended approach is TDT transcription plus CTC vocabulary scoring
  (`CtcModels.swift`, lines 4-11).

The MacParakeet constraints that matter for Phase 1:

- Unified is currently a separate runtime selected before the shared TDT path
  (`STTRuntime.swift`, lines 455-468).
- TDT dictation finalization pads 0.5 s of real trailing silence to prevent
  dropped final words from issue 562 (`STT/README.md`, lines 179-194;
  `STTRuntime.swift`, lines 480-505 and 580-625).
- All Parakeet TDT inference is wrapped in `ANEInferenceGate` to avoid macOS 14
  concurrent CoreML/ANE SIGBUS crashes (`STT/README.md`, lines 196-204;
  `ANEInferenceGate.swift`, lines 3-31 and 54-70).
- Unified live/final calls are also gated and now return token-derived word
  timings through the wrapper (`ParakeetUnifiedEngine.swift`).

No hard vocabulary count cap surfaced in the source. FluidAudio has size-aware
policy thresholds instead: small, large, and extra-large vocabulary configs. At
50 terms, this harness exercised the large-vocab path (`minSimilarity=0.55`,
`cbw=4.5`). The source comments note that larger distractor pools make lower
similarity gates produce false positives; this Phase 0 run reproduced that risk
even at 50 product/jargon terms (`ContextBiasingConstants.swift`, lines
214-255).

## Harness

Scratch code lives under `benchmarks/asr/custom-vocab-phase0/`:

- `probe/`: a Swift package that links against the repo-resolved FluidAudio
  checkout in `.build/checkouts/FluidAudio`.
- `oov_utterances.jsonl`: 50 exact-ground-truth OOV utterances with names,
  product terms, and engineering jargon.
- `vocab_terms.txt`: the 50-term vocabulary list used for all boosted runs.
- `scripts/generate_oov_say.py`: generates synthetic AIFF audio with macOS
  `say` across several installed voices and rates.
- `scripts/term_recall.py`: computes normalized exact term recall.
- `scripts/librispeech_manifest.py`: creates LibriSpeech JSONL manifests from a
  local split.
- `results/`: committed JSONL evidence and compact score/recall summaries.

The OOV audio is synthetic macOS `say` output. It is useful for a controlled
mechanism check because ground truth is exact by construction, but it is not a
substitute for human dictation, accents, microphone conditions, or meeting audio
QA.

The CTC model was loaded through FluidAudio's default Application Support cache,
not duplicated in the repo. Generated audio/manifests and SwiftPM build output
are ignored.

## Replay Commands

From the repo root:

```bash
swift package resolve
swift build -c release --package-path benchmarks/asr/custom-vocab-phase0/probe \
  --product custom-vocab-phase0-probe
python3 benchmarks/asr/custom-vocab-phase0/scripts/generate_oov_say.py
```

OOV TDT v3 runs:

```bash
swift run -c release --package-path benchmarks/asr/custom-vocab-phase0/probe custom-vocab-phase0-probe \
  --engine tdt-v3 \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_no-vocab.jsonl \
  --append-silence-seconds 0.5

swift run -c release --package-path benchmarks/asr/custom-vocab-phase0/probe custom-vocab-phase0-probe \
  --engine tdt-v3 \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --vocab benchmarks/asr/custom-vocab-phase0/vocab_terms.txt \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_vocab_default.jsonl \
  --append-silence-seconds 0.5

swift run -c release --package-path benchmarks/asr/custom-vocab-phase0/probe custom-vocab-phase0-probe \
  --engine tdt-v3 \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --vocab benchmarks/asr/custom-vocab-phase0/vocab_terms.txt \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_vocab_min065.jsonl \
  --append-silence-seconds 0.5 \
  --min-similarity 0.65
```

Unified applicability check:

```bash
swift run -c release --package-path benchmarks/asr/custom-vocab-phase0/probe custom-vocab-phase0-probe \
  --engine unified \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_unified_no-vocab.jsonl \
  --append-silence-seconds 0.5

swift run -c release --package-path benchmarks/asr/custom-vocab-phase0/probe custom-vocab-phase0-probe \
  --engine unified \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --vocab benchmarks/asr/custom-vocab-phase0/vocab_terms.txt \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_unified_vocab_requested.jsonl \
  --append-silence-seconds 0.5
```

Term recall:

```bash
python3 benchmarks/asr/custom-vocab-phase0/scripts/term_recall.py \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --records benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_no-vocab.jsonl \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_no-vocab_recall.json
```

Repeat the recall command with the other OOV result files. The committed
`*_recall.json` files are the outputs.

LibriSpeech manifests and WER:

```bash
python3 benchmarks/asr/custom-vocab-phase0/scripts/librispeech_manifest.py \
  --split-dir /Users/dmoon/asr-bench/LibriSpeech/test-clean \
  --limit 200 \
  --output benchmarks/asr/custom-vocab-phase0/generated/librispeech-test-clean-first200.jsonl

python3 benchmarks/asr/custom-vocab-phase0/scripts/librispeech_manifest.py \
  --split-dir /Users/dmoon/asr-bench/LibriSpeech/test-clean \
  --output benchmarks/asr/custom-vocab-phase0/generated/librispeech-test-clean-full.jsonl
```

Run the probe over those manifests with `--engine tdt-v3`, optionally
`--vocab .../vocab_terms.txt`, and for the stricter condition add
`--min-similarity 0.65`. Score with the existing ASR scorer:

```bash
python3 benchmarks/asr/score.py benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_no-vocab.jsonl \
  --json benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_no-vocab_score.json

python3 benchmarks/asr/score.py benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_vocab_min065.jsonl \
  --json benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_vocab_min065_score.json
```

I used the canonical scorer normalizer. In this worktree, the full pinned
`benchmarks/asr/requirements.txt` install was blocked by the local package index
missing `rapidfuzz==3.14.5`; `score.py` still ran with `whisper-normalizer` and
its pure-Python edit-distance fallback. No new Python dependency is committed.

## Results

### OOV Term Recall

| Engine / condition | Recall | Modified records | Applied vocab terms | False applied terms | Notes |
|---|---:|---:|---:|---:|---|
| TDT v3, no vocab | 11/50 (22%) | 0 | 0 | 0 | Baseline exact term recall. |
| TDT v3, FluidAudio default large-vocab gate | 42/50 (84%) | 34 | 41 | 9 | Best recall, but too many hallucinated vocabulary replacements. |
| TDT v3, `minSimilarity=0.65` | 37/50 (74%) | 26 | 28 | 1 | Lower recall, much cleaner replacements. |
| Unified, no vocab | 13/50 (26%) | 0 | 0 | 0 | Baseline exact term recall. |
| Unified, vocab requested | 13/50 (26%) | 0 | 0 | 0 | Output identical to no-vocab; 50/50 rows marked unsupported. |

Examples of useful TDT corrections at `minSimilarity=0.65`: `MAC Parakeet` ->
`MacParakeet`, `Fluid Audio` -> `FluidAudio`, `Swiftly` -> `SwiftUI`, and
`Core ML` -> `CoreML`. The single OOV false replacement at this stricter gate was
`telemetry` -> `OpenTelemetry` in the sentence "Szymon reviewed the telemetry
numbers."

Unified vocab-requested rows still had CTC detections in 50/50 rows, which means
the CTC sidecar ran. The blocker is applying those detections: no token timings
or public rescorer hook are exposed by the Unified batch API used by
MacParakeet.

### LibriSpeech WER Guard

WER is corpus WER with the existing `benchmarks/asr/score.py` canonical
normalizer. The Phase 0 failure bound is >0.3 pt absolute regression against the
same model without keywords.

| Dataset | Condition | Files | WER | Delta | RTFx | Gate |
|---|---|---:|---:|---:|---:|---|
| `test-clean` first 200 | TDT v3, no vocab | 200 | 3.337% | - | 119.7 | Baseline |
| `test-clean` first 200 | TDT v3, FluidAudio default gate | 200 | 4.535% | +1.198 pt | 34.8 | Fail |
| `test-clean` first 200 | TDT v3, `minSimilarity=0.65` | 200 | 3.465% | +0.128 pt | 34.8 | Pass |
| `test-clean` full | TDT v3, no vocab | 2620 | 2.312% | - | 103.1 | Baseline |
| `test-clean` full | TDT v3, `minSimilarity=0.65` | 2620 | 2.414% | +0.102 pt | 31.4 | Pass |

The default FluidAudio large-vocab threshold made 52 false vocabulary
replacements in the first 200 LibriSpeech files. The stricter threshold made 5
false replacements in the same 200-file sample and 48 false replacements across
the full 2620-file `test-clean` split. Those false replacements are still real
product risk (`lines` -> `Linear`, `swiftly` -> `SwiftUI`, `wine alone` ->
`Pinecone`), but the aggregate WER impact at `minSimilarity=0.65` stayed under
the Phase 0 bound.

The boosted path is slower because it adds CTC inference and rescoring. On the
full `test-clean` run, throughput dropped from 103.1 RTFx to 31.4 RTFx. That is
still well above realtime in this harness, but Phase 1 should measure perceived
dictation-stop latency and long-file throughput before product launch.

## Answers To The Three Questions

### 1. Mechanism

The mechanism is load/config-time CTC model and vocabulary setup plus
per-request rescoring for batch/offline work. For file-mode TDT, FluidAudio's own
CLI transcribes first with TDT, then loads/tokenizes the vocabulary, runs CTC
keyword spotting over the samples, and applies `VocabularyRescorer` to the TDT
transcript and token timings. Streaming exposes the same idea as
`SlidingWindowAsrManager.configureVocabularyBoosting(...)`, which configures the
vocabulary and CTC models once for the manager and rescoring runs as confirmed
text is produced. I found no hard list-size cap; the practical limit is the
false-positive curve controlled by FluidAudio's size-aware gates. The knobs that
mattered here were `minSimilarity`, `cbw`, `marginSeconds`, `minCtcScore`,
`minTermLength`, and `alpha`; in this corpus, the default 50-term gate
(`minSimilarity=0.55`) was unsafe, while `minSimilarity=0.65` passed the WER
guard. For MacParakeet, the lowest-risk seam is the existing TDT path with a CTC
sidecar after TDT finalization. It must run under the same `ANEInferenceGate` and
must rescore audio equivalent to the audio TDT decoded. For dictation, that means
the same padded samples used for issue 562; for file/meeting jobs, Phase 1 needs
to preserve the long-audio URL/disk-backed memory behavior instead of casually
loading multi-hour files into RAM just to feed the sidecar. Otherwise the feature
can reintroduce either the macOS 14 ANE race, final-word clipping behavior, or a
memory regression.

### 2. Model Applicability

Boosting works empirically on TDT v3 as a TDT-plus-CTC sidecar, not as a
user-visible switch to CTC greedy transcription. TDT v3 OOV recall improved from
22% without vocab to 84% with FluidAudio's default gate and 74% with the stricter
gate, with result rows showing real replacements such as `MAC Parakeet` ->
`MacParakeet`. This proves custom vocabulary can be a property of the default
TDT engine path. It does not currently work on the Unified path available to
MacParakeet: Unified no-vocab and vocab-requested hypotheses were identical
for all 50 OOV rows, recall stayed 26%, and every vocab-requested row was marked
unsupported because FluidAudio does not expose a Unified vocabulary-rescoring
hook. The CTC-only kill switch is not triggered for TDT, and the
110M CTC model should not be exposed as its own transcription variant based on
this evidence.

### 3. Quality Numbers

The synthetic OOV set gives a clear mechanism signal but should not be treated
as human speech quality proof. TDT v3 exact term recall was 11/50 (22%) without
vocab, 42/50 (84%) with FluidAudio defaults, and 37/50 (74%) with
`minSimilarity=0.65`. Unified was 13/50 (26%) with or without requested vocab
because no corrections were applied. On LibriSpeech `test-clean`, the default
FluidAudio threshold failed the first-200 WER guard (3.337% -> 4.535%, +1.198 pt).
The stricter `minSimilarity=0.65` setting passed both the first-200 check
(3.337% -> 3.465%, +0.128 pt) and the full-set check (2.312% -> 2.414%,
+0.102 pt). The quality tradeoff is therefore real: stricter gating sacrifices
10 OOV recall points versus the default gate, but removes most false OOV
replacements and keeps standard-set WER inside the plan's bound.

## Surprises

- FluidAudio's own comments say CTC greedy decoding is unusable for this product
  shape, but the sidecar path is already wired in both file-mode CLI code and
  sliding-window streaming code.
- The 50-term list hit false positives even though it is not a huge vocabulary.
  Product code should not ship FluidAudio's 50-term default blindly.
- Unified produced CTC detections for the requested vocab but could not apply
  them. That makes Unified support a separate API/runtime project, not a small
  Settings toggle.
- The stricter gate still made 48 false vocabulary replacements over full
  LibriSpeech clean, even though aggregate WER stayed within the threshold. Phase
  1 needs a product-level opt-in posture and probably per-term disable/undo
  affordances if false corrections show up in real dictation.

## Recommended Seam

Use the existing Parakeet TDT path and side-load FluidAudio's CTC 110M model as
an auxiliary scorer/rescorer after TDT produces a final transcript and token
timings. Cache the CTC model and tokenized vocabulary by vocabulary hash, run the
CTC pass under `ANEInferenceGate`, and feed it audio aligned to the TDT output.
For dictation, that means the existing 0.5 s padded samples, preserving issue
562's trailing-silence fix. For long file/meeting jobs, preserve the existing
URL/disk-backed memory posture when plumbing audio into the sidecar. Use a
stricter starting gate than FluidAudio's 50-term default: this Phase 0 evidence
supports `minSimilarity=0.65` as the first Phase 1 candidate.

Runner-up: adopt `SlidingWindowAsrManager` for live/streaming TDT and use its
`configureVocabularyBoosting(...)` API. It is attractive because FluidAudio
already owns the streaming integration, but it is the larger MacParakeet seam:
we would swap more runtime behavior at once, revalidate scheduler/progress/live
partial semantics, preserve the ANE gate, and preserve dictation finalization
behavior. The batch TDT sidecar gives the same mechanism with less product-code
surface area.

## Decision Gate For Daniel

This is not CTC-only in the product sense. The default TDT v3 path can gain
custom vocabulary by adding a CTC 110M sidecar, while the 110M CTC model itself
should not become a user-facing transcription variant. The numbers to decide
against are: TDT v3 OOV recall 22% -> 74% at the stricter gate, full
LibriSpeech clean WER 2.312% -> 2.414% (+0.102 pt, pass), and throughput
103.1 -> 31.4 RTFx. If Daniel wants a variant-row framing, it should be "ship a
TDT v3 boosted-accuracy mode with a sidecar and strict gate, or hold until
FluidAudio exposes an equally clean Unified/default-family API?" not "ship a
CTC 110M model variant."

## Phase 1 Product Touches

Phase 1 should wire the existing `CustomWord` / `CustomWordRepository` source of
truth into Parakeet TDT transcription only, add a capability flag so Settings and
CLI copy are honest for Unified/unsupported engines, cache/load the CTC sidecar
and tokenized vocabulary without duplicating model assets, and apply rescoring
inside the current TDT dictation/file/meeting finalization paths while preserving
`ANEInferenceGate` and the 0.5 s dictation trailing-silence padding. Because this
changes user-visible transcription behavior and CLI transcribe semantics, it
should update the matching `spec/contracts/` document and focused tests in the
same product PR.
