# Parakeet Unified Benchmarks

This folder records the merge-readiness benchmark evidence for PR #552.

## Canonical FluidAudio Benchmark

FluidAudio 0.15.4 reports the full LibriSpeech `test-clean` results below for
Parakeet Unified EN 0.6B. The run uses FluidAudio's Swift managers directly and
scores with FluidAudio's `TextNormalizer`.

Sources:

- FluidAudio benchmarks:
  <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md#parakeet-unified-english-batch--streaming>
- NVIDIA model card:
  <https://huggingface.co/nvidia/parakeet-unified-en-0.6b>

Command noted by FluidAudio:

```bash
swift run -c release fluidaudiocli unified-benchmark
```

| Mode | Files | Avg WER | Aggregate WER | Median WER | Median RTFx | Overall RTFx |
|------|------:|--------:|--------------:|-----------:|------------:|-------------:|
| batch | 2620 | 2.15% | 1.68% | 0.00% | 111.5x | 123.3x |
| streaming | 2620 | 2.21% | 1.79% | 0.00% | 53.1x | 29.1x |

FluidAudio's same-harness comparison for Parakeet TDT v3 is 2.6% average WER
and 110x overall RTFx. Unified remains English-only; v3 remains the default
multilingual Parakeet build.

## MacParakeet CLI End-to-End Check

MacParakeet was also validated end to end through the release CLI, using
`transcribe --parakeet-model unified` and writing transcript files through
`--output-dir` so CoreML stdout diagnostics cannot contaminate hypotheses.

Run:

```bash
export LIBRISPEECH_TEST_CLEAN=/path/to/LibriSpeech/test-clean
swift build --product macparakeet-cli -c release
benchmarks/parakeet-unified/run_macparakeet_librispeech.py \
  --dataset "$LIBRISPEECH_TEST_CLEAN" \
  --cli .build/release/macparakeet-cli \
  --limit 300 \
  --selection stride \
  --records benchmarks/parakeet-unified/macparakeet-unified-test-clean-stride300.jsonl

# Re-score the committed JSONL without re-running transcription.
benchmarks/parakeet-unified/run_macparakeet_librispeech.py \
  --score-only \
  --records benchmarks/parakeet-unified/macparakeet-unified-test-clean-stride300.jsonl
```

Unified result:

```text
files=300  ref_words=5809  I=11 D=10 S=91
CORPUS WER = 1.93%
```

The same deterministic 300-file sample was also run through v2 for an
end-to-end CLI comparison:

```bash
benchmarks/parakeet-unified/run_macparakeet_librispeech.py \
  --dataset "$LIBRISPEECH_TEST_CLEAN" \
  --cli .build/release/macparakeet-cli \
  --limit 300 \
  --selection stride \
  --parakeet-model v2 \
  --records benchmarks/parakeet-unified/macparakeet-v2-test-clean-stride300.jsonl
benchmarks/parakeet-unified/run_macparakeet_librispeech.py \
  --score-only \
  --records benchmarks/parakeet-unified/macparakeet-v2-test-clean-stride300.jsonl
```

| Model | Files | Corpus WER | Errors | Elapsed |
|-------|------:|-----------:|--------|--------:|
| Parakeet Unified | 300 | 1.93% | I=11 D=10 S=91 | 39.20s |
| Parakeet v2 | 300 | 2.41% | I=15 D=27 S=98 | 64.20s |

The MacParakeet runner and scorer are intentionally dependency-free and use a
simpler English ASR normalizer than FluidAudio's canonical benchmark. The CLI
result is therefore an end-to-end integration check, not the headline model-card
number.

## Partial-Cache Regression Smoke

Before the cache-repair fix, a cache containing only:

```text
parakeet_unified_decoder.mlmodelc
parakeet_unified_encoder_int8.mlmodelc
```

failed on first use because FluidAudio's loader considered the encoder enough
to skip download, then errored on the missing preprocessor. After the fix,
this command repaired the cache and completed successfully:

```bash
.build/release/macparakeet-cli transcribe \
  "$LIBRISPEECH_TEST_CLEAN/1089/134686/1089-134686-0000.flac" \
  --format transcript \
  --parakeet-model unified \
  --no-history
```

The repaired cache contained all six required offline files:

```text
metadata.json
parakeet_unified_decoder.mlmodelc
parakeet_unified_encoder_int8.mlmodelc
parakeet_unified_joint_decision_single_step.mlmodelc
parakeet_unified_preprocessor.mlmodelc
vocab.json
```
