# Custom Vocabulary Phase 0 Probe

Scratch harness for `plans/active/2026-07-03-parakeet-custom-vocabulary.md`.
It resolves FluidAudio 0.15.4 directly so a clean checkout can build the probe
without relying on root `.build` artifacts.

From the repo root:

```bash
swift build -c release --package-path benchmarks/asr/custom-vocab-phase0/probe \
  --product custom-vocab-phase0-probe
python3 benchmarks/asr/custom-vocab-phase0/scripts/generate_oov_say.py
```

Run the OOV mechanism checks:

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

Score term recall:

```bash
python3 benchmarks/asr/custom-vocab-phase0/scripts/term_recall.py \
  --manifest benchmarks/asr/custom-vocab-phase0/generated/oov_manifest.jsonl \
  --records benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_vocab_min065.jsonl \
  --output benchmarks/asr/custom-vocab-phase0/results/oov_tdt-v3_vocab_min065_recall.json
```

Generate the LibriSpeech clean manifests used for the WER guard:

```bash
python3 benchmarks/asr/custom-vocab-phase0/scripts/librispeech_manifest.py \
  --split-dir "$LIBRISPEECH_DIR/test-clean" \
  --limit 200 \
  --output benchmarks/asr/custom-vocab-phase0/generated/librispeech-test-clean-first200.jsonl

python3 benchmarks/asr/custom-vocab-phase0/scripts/librispeech_manifest.py \
  --split-dir "$LIBRISPEECH_DIR/test-clean" \
  --output benchmarks/asr/custom-vocab-phase0/generated/librispeech-test-clean-full.jsonl
```

Score WER with the existing benchmark scorer:

```bash
python3 benchmarks/asr/score.py benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_no-vocab.jsonl \
  --json benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_no-vocab_score.json

python3 benchmarks/asr/score.py benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_vocab_min065.jsonl \
  --json benchmarks/asr/custom-vocab-phase0/results/librispeech-full_tdt-v3_vocab_min065_score.json
```

The OOV audio is synthetic macOS `say` output. It is useful for a controlled
term-recall mechanism check, not as a substitute for human speech QA.
