# Phase 0b Clean-Corpus Voiceprint Validation

- **Date:** 2026-07-04 · Follow-up to `2026-07-04-voiceprints-phase0-calibration.md` (NO-GO attributed to corpus quality)
- **Status:** COMPLETE — **GO: the FluidAudio embedding path is viable.** Same-narrator cross-recording pairs separate from different-narrator pairs with NO overlap (0.05–0.23 vs 0.47–0.84); tau=0.30 + margin 0.10 gives TPR 21/21, FPR 0/84. Confirms the Phase 0 corpus-conditions hypothesis: meeting audio (pre-AEC echo, unfinalized files) destroyed cross-recording identity, not the model.
- **Corpus privacy:** public YouTube videos of four solo narrators (channel = speaker); no private data.
- **Gate consequence:** Phase 1 stays blocked ONLY on a representative post-AEC meeting corpus (ship #605/0.6.25 → dogfood → re-run harness → set product tau).

## Purpose

Validate whether FluidAudio 0.15.4 offline-diarizer embeddings identify the same known narrator across different clean public recordings. Ground truth is `channel == speaker`.

## Corpus

15 public `.m4a` files under `<local scratch>/phase0b-corpus (public YouTube audio, first 10 min per video; IDs in tables below)`.

- `techconnections`: 4 files
- `practicaleng`: 4 files
- `wendover`: 4 files
- `cgpgrey`: 3 files

## Harness

Used externally built read-only binary:

`the Phase 0 harness (docs/research/2026-07-04-voiceprints-phase0/harness/), built with 'swift build -c release'`

Command pattern:

```sh
voiceprint-harness --audio AUDIO --session-id CHANNEL-STEM --track microphone \
  --models-dir "$HOME/Library/Application Support/FluidAudio/Models" \
  --output data/CHANNEL__STEM.json
```

The original `voiceprints-phase0` worktree was not modified or rebuilt.

Runtime note: harness stderr repeatedly logged `E5RT ... Operation not permitted ["/Users/dmoon/Library/Caches/voiceprint-harness"]`, but every run exited 0 and produced a JSON output.

## Extraction

Full-track extraction completed for all 15 files into `./data/`, one JSON per source file. Analysis script and artifacts:

- `analyze_voiceprints.py`
- `analysis_results.json`
- `analysis_results.md`
- `logs/extraction.log`

## Dominant Clusters

| file | clusters | segments | total speech sec | dominant | dominant sec | dominant share | flag |
|---|---:|---:|---:|---|---:|---:|---|
| cgpgrey/100-jlLUuX2a0Cg | 1 | 5 | 400.7 | S1 | 400.7 | 1.000 |  |
| cgpgrey/66-T0fAznO1wA8 | 1 | 7 | 411.4 | S1 | 411.4 | 1.000 |  |
| cgpgrey/80-SumDHcnCRuU | 2 | 3 | 185.2 | S1 | 171.2 | 0.924 |  |
| practicaleng/1-7oi4yMr8Rjk | 1 | 8 | 587.5 | S1 | 587.5 | 1.000 |  |
| practicaleng/100-SH9r94NkZpE | 1 | 15 | 576.3 | S1 | 576.3 | 1.000 |  |
| practicaleng/33-YSQhtlyfPtU | 1 | 19 | 582.4 | S1 | 582.4 | 1.000 |  |
| practicaleng/66-Seb3lULQruE | 2 | 95 | 449.7 | S1 | 447.6 | 0.995 |  |
| techconnections/1-_KWdCqpXB7A | 1 | 112 | 520.6 | S1 | 520.6 | 1.000 |  |
| techconnections/100-_AdBcTMHG0Q | 1 | 93 | 538.3 | S1 | 538.3 | 1.000 |  |
| techconnections/33-XRCprhlz4D8 | 1 | 126 | 514.6 | S1 | 514.6 | 1.000 |  |
| techconnections/66-imMBwUGjXHs | 2 | 88 | 529.6 | S1 | 527.5 | 0.996 |  |
| wendover/1-DPeRd48YfqY | 2 | 23 | 588.8 | S1 | 586.7 | 0.997 |  |
| wendover/100-f66GfsKPTUg | 2 | 34 | 587.2 | S1 | 585.1 | 0.996 |  |
| wendover/33-a5126u88E7E | 1 | 32 | 588.4 | S1 | 588.4 | 1.000 |  |
| wendover/66-S_vc04fveGc | 2 | 17 | 592.8 | S1 | 590.8 | 0.997 |  |

## Population Stats

| population | count | p5 | p25 | p50 | p75 | p95 | min | max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| P | 21 | 0.0546 | 0.0736 | 0.1073 | 0.1418 | 0.2033 | 0.0546 | 0.2270 |
| N | 84 | 0.5342 | 0.6094 | 0.6872 | 0.7485 | 0.7839 | 0.4656 | 0.8388 |

Overlap: P range 0.0546-0.2270; N range 0.4656-0.8388.

## Tau Sweep

Margin interpretation: accept same-speaker when distance <= tau; treat tau < distance < tau+0.10 as gray/no-decision; FPR is negatives accepted at <= tau.

| tau | gray upper | TPR | FPR | P accepted | N accepted | P gray | N gray |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.00 | 0.10 | 0.000 | 0.000 | 0 | 0 | 9 | 0 |
| 0.05 | 0.15 | 0.000 | 0.000 | 0 | 0 | 16 | 0 |
| 0.10 | 0.20 | 0.429 | 0.000 | 9 | 0 | 10 | 0 |
| 0.15 | 0.25 | 0.762 | 0.000 | 16 | 0 | 5 | 0 |
| 0.20 | 0.30 | 0.905 | 0.000 | 19 | 0 | 2 | 0 |
| 0.25 | 0.35 | 1.000 | 0.000 | 21 | 0 | 0 | 0 |
| 0.30 | 0.40 | 1.000 | 0.000 | 21 | 0 | 0 | 0 |
| 0.35 | 0.45 | 1.000 | 0.000 | 21 | 0 | 0 | 0 |
| 0.40 | 0.50 | 1.000 | 0.000 | 21 | 0 | 0 | 2 |
| 0.45 | 0.55 | 1.000 | 0.000 | 21 | 0 | 0 | 6 |
| 0.50 | 0.60 | 1.000 | 0.024 | 21 | 2 | 0 | 14 |
| 0.55 | 0.65 | 1.000 | 0.071 | 21 | 6 | 0 | 24 |
| 0.60 | 0.70 | 1.000 | 0.190 | 21 | 16 | 0 | 29 |
| 0.65 | 0.75 | 1.000 | 0.357 | 21 | 30 | 0 | 34 |
| 0.70 | 0.80 | 1.000 | 0.536 | 21 | 45 | 0 | 35 |
| 0.75 | 0.85 | 1.000 | 0.762 | 21 | 64 | 0 | 20 |
| 0.80 | 0.90 | 1.000 | 0.952 | 21 | 80 | 0 | 4 |
| 0.85 | 0.95 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 0.90 | 1.00 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 0.95 | 1.05 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.00 | 1.10 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.05 | 1.15 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.10 | 1.20 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.15 | 1.25 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.20 | 1.30 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.25 | 1.35 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.30 | 1.40 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.35 | 1.45 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.40 | 1.50 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.45 | 1.55 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |
| 1.50 | 1.60 | 1.000 | 1.000 | 21 | 84 | 0 | 0 |

## Same-Channel Pairs

| distance | left | right |
|---:|---|---|
| 0.0546 | techconnections/100-_AdBcTMHG0Q | techconnections/66-imMBwUGjXHs |
| 0.0546 | wendover/33-a5126u88E7E | wendover/66-S_vc04fveGc |
| 0.0684 | techconnections/33-XRCprhlz4D8 | techconnections/66-imMBwUGjXHs |
| 0.0685 | wendover/100-f66GfsKPTUg | wendover/33-a5126u88E7E |
| 0.0705 | wendover/100-f66GfsKPTUg | wendover/66-S_vc04fveGc |
| 0.0736 | techconnections/1-_KWdCqpXB7A | techconnections/33-XRCprhlz4D8 |
| 0.0864 | practicaleng/1-7oi4yMr8Rjk | practicaleng/33-YSQhtlyfPtU |
| 0.0876 | techconnections/1-_KWdCqpXB7A | techconnections/66-imMBwUGjXHs |
| 0.0995 | techconnections/100-_AdBcTMHG0Q | techconnections/33-XRCprhlz4D8 |
| 0.1014 | techconnections/1-_KWdCqpXB7A | techconnections/100-_AdBcTMHG0Q |
| 0.1073 | wendover/1-DPeRd48YfqY | wendover/100-f66GfsKPTUg |
| 0.1168 | cgpgrey/66-T0fAznO1wA8 | cgpgrey/80-SumDHcnCRuU |
| 0.1256 | wendover/1-DPeRd48YfqY | wendover/66-S_vc04fveGc |
| 0.1288 | wendover/1-DPeRd48YfqY | wendover/33-a5126u88E7E |
| 0.1372 | practicaleng/100-SH9r94NkZpE | practicaleng/66-Seb3lULQruE |
| 0.1418 | practicaleng/1-7oi4yMr8Rjk | practicaleng/66-Seb3lULQruE |
| 0.1543 | practicaleng/33-YSQhtlyfPtU | practicaleng/66-Seb3lULQruE |
| 0.1755 | practicaleng/1-7oi4yMr8Rjk | practicaleng/100-SH9r94NkZpE |
| 0.1781 | practicaleng/100-SH9r94NkZpE | practicaleng/33-YSQhtlyfPtU |
| 0.2033 | cgpgrey/100-jlLUuX2a0Cg | cgpgrey/80-SumDHcnCRuU |
| 0.2270 | cgpgrey/100-jlLUuX2a0Cg | cgpgrey/66-T0fAznO1wA8 |

## Cross-Channel Pairs

| distance | left | right |
|---:|---|---|
| 0.4656 | practicaleng/33-YSQhtlyfPtU | techconnections/33-XRCprhlz4D8 |
| 0.4815 | practicaleng/33-YSQhtlyfPtU | techconnections/100-_AdBcTMHG0Q |
| 0.5038 | practicaleng/33-YSQhtlyfPtU | techconnections/66-imMBwUGjXHs |
| 0.5234 | practicaleng/33-YSQhtlyfPtU | techconnections/1-_KWdCqpXB7A |
| 0.5336 | practicaleng/1-7oi4yMr8Rjk | techconnections/33-XRCprhlz4D8 |
| 0.5373 | practicaleng/33-YSQhtlyfPtU | wendover/1-DPeRd48YfqY |
| 0.5570 | practicaleng/100-SH9r94NkZpE | techconnections/33-XRCprhlz4D8 |
| 0.5644 | techconnections/66-imMBwUGjXHs | wendover/100-f66GfsKPTUg |
| 0.5661 | practicaleng/1-7oi4yMr8Rjk | techconnections/1-_KWdCqpXB7A |
| 0.5722 | practicaleng/66-Seb3lULQruE | techconnections/33-XRCprhlz4D8 |
| 0.5736 | techconnections/100-_AdBcTMHG0Q | wendover/100-f66GfsKPTUg |
| 0.5798 | practicaleng/33-YSQhtlyfPtU | wendover/100-f66GfsKPTUg |
| 0.5840 | techconnections/66-imMBwUGjXHs | wendover/33-a5126u88E7E |
| 0.5947 | practicaleng/1-7oi4yMr8Rjk | techconnections/100-_AdBcTMHG0Q |
| 0.5978 | practicaleng/1-7oi4yMr8Rjk | techconnections/66-imMBwUGjXHs |
| 0.5987 | practicaleng/66-Seb3lULQruE | techconnections/1-_KWdCqpXB7A |
| 0.6009 | techconnections/33-XRCprhlz4D8 | wendover/100-f66GfsKPTUg |
| 0.6013 | practicaleng/100-SH9r94NkZpE | techconnections/1-_KWdCqpXB7A |
| 0.6021 | techconnections/100-_AdBcTMHG0Q | wendover/33-a5126u88E7E |
| 0.6029 | practicaleng/33-YSQhtlyfPtU | wendover/66-S_vc04fveGc |
| 0.6048 | practicaleng/1-7oi4yMr8Rjk | wendover/1-DPeRd48YfqY |
| 0.6109 | techconnections/66-imMBwUGjXHs | wendover/66-S_vc04fveGc |
| 0.6155 | techconnections/1-_KWdCqpXB7A | wendover/100-f66GfsKPTUg |
| 0.6229 | techconnections/100-_AdBcTMHG0Q | wendover/66-S_vc04fveGc |
| 0.6308 | practicaleng/100-SH9r94NkZpE | wendover/1-DPeRd48YfqY |
| 0.6313 | practicaleng/66-Seb3lULQruE | techconnections/100-_AdBcTMHG0Q |
| 0.6404 | techconnections/66-imMBwUGjXHs | wendover/1-DPeRd48YfqY |
| 0.6419 | practicaleng/1-7oi4yMr8Rjk | wendover/100-f66GfsKPTUg |
| 0.6421 | techconnections/33-XRCprhlz4D8 | wendover/33-a5126u88E7E |
| 0.6475 | practicaleng/33-YSQhtlyfPtU | wendover/33-a5126u88E7E |
| 0.6515 | practicaleng/100-SH9r94NkZpE | techconnections/100-_AdBcTMHG0Q |
| 0.6523 | practicaleng/66-Seb3lULQruE | techconnections/66-imMBwUGjXHs |
| 0.6525 | techconnections/100-_AdBcTMHG0Q | wendover/1-DPeRd48YfqY |
| 0.6526 | practicaleng/100-SH9r94NkZpE | techconnections/66-imMBwUGjXHs |
| 0.6560 | cgpgrey/66-T0fAznO1wA8 | techconnections/1-_KWdCqpXB7A |
| 0.6593 | practicaleng/66-Seb3lULQruE | wendover/1-DPeRd48YfqY |
| 0.6610 | techconnections/33-XRCprhlz4D8 | wendover/66-S_vc04fveGc |
| 0.6635 | techconnections/1-_KWdCqpXB7A | wendover/33-a5126u88E7E |
| 0.6658 | techconnections/33-XRCprhlz4D8 | wendover/1-DPeRd48YfqY |
| 0.6710 | practicaleng/100-SH9r94NkZpE | wendover/100-f66GfsKPTUg |
| 0.6798 | techconnections/1-_KWdCqpXB7A | wendover/66-S_vc04fveGc |
| 0.6815 | practicaleng/66-Seb3lULQruE | wendover/100-f66GfsKPTUg |
| 0.6930 | cgpgrey/80-SumDHcnCRuU | techconnections/1-_KWdCqpXB7A |
| 0.6939 | practicaleng/1-7oi4yMr8Rjk | wendover/66-S_vc04fveGc |
| 0.6984 | cgpgrey/100-jlLUuX2a0Cg | wendover/100-f66GfsKPTUg |
| 0.7015 | practicaleng/100-SH9r94NkZpE | wendover/66-S_vc04fveGc |
| 0.7121 | cgpgrey/66-T0fAznO1wA8 | practicaleng/1-7oi4yMr8Rjk |
| 0.7130 | cgpgrey/66-T0fAznO1wA8 | wendover/100-f66GfsKPTUg |
| 0.7141 | cgpgrey/100-jlLUuX2a0Cg | wendover/66-S_vc04fveGc |
| 0.7148 | cgpgrey/66-T0fAznO1wA8 | techconnections/66-imMBwUGjXHs |
| 0.7177 | practicaleng/1-7oi4yMr8Rjk | wendover/33-a5126u88E7E |
| 0.7188 | techconnections/1-_KWdCqpXB7A | wendover/1-DPeRd48YfqY |
| 0.7239 | practicaleng/66-Seb3lULQruE | wendover/66-S_vc04fveGc |
| 0.7242 | cgpgrey/66-T0fAznO1wA8 | techconnections/100-_AdBcTMHG0Q |
| 0.7247 | cgpgrey/66-T0fAznO1wA8 | techconnections/33-XRCprhlz4D8 |
| 0.7283 | cgpgrey/80-SumDHcnCRuU | practicaleng/100-SH9r94NkZpE |
| 0.7302 | cgpgrey/100-jlLUuX2a0Cg | wendover/33-a5126u88E7E |
| 0.7340 | cgpgrey/66-T0fAznO1wA8 | practicaleng/100-SH9r94NkZpE |
| 0.7418 | cgpgrey/66-T0fAznO1wA8 | wendover/33-a5126u88E7E |
| 0.7435 | cgpgrey/80-SumDHcnCRuU | wendover/100-f66GfsKPTUg |
| 0.7451 | cgpgrey/66-T0fAznO1wA8 | wendover/66-S_vc04fveGc |
| 0.7452 | practicaleng/100-SH9r94NkZpE | wendover/33-a5126u88E7E |
| 0.7485 | cgpgrey/100-jlLUuX2a0Cg | techconnections/1-_KWdCqpXB7A |
| 0.7486 | cgpgrey/100-jlLUuX2a0Cg | practicaleng/1-7oi4yMr8Rjk |
| 0.7555 | cgpgrey/66-T0fAznO1wA8 | practicaleng/66-Seb3lULQruE |
| 0.7555 | cgpgrey/100-jlLUuX2a0Cg | practicaleng/33-YSQhtlyfPtU |
| 0.7608 | cgpgrey/66-T0fAznO1wA8 | practicaleng/33-YSQhtlyfPtU |
| 0.7613 | cgpgrey/80-SumDHcnCRuU | techconnections/100-_AdBcTMHG0Q |
| 0.7614 | cgpgrey/100-jlLUuX2a0Cg | practicaleng/100-SH9r94NkZpE |
| 0.7616 | cgpgrey/80-SumDHcnCRuU | wendover/66-S_vc04fveGc |
| 0.7650 | cgpgrey/80-SumDHcnCRuU | techconnections/66-imMBwUGjXHs |
| 0.7662 | cgpgrey/100-jlLUuX2a0Cg | techconnections/66-imMBwUGjXHs |
| 0.7662 | practicaleng/66-Seb3lULQruE | wendover/33-a5126u88E7E |
| 0.7679 | cgpgrey/80-SumDHcnCRuU | wendover/33-a5126u88E7E |
| 0.7680 | cgpgrey/100-jlLUuX2a0Cg | techconnections/33-XRCprhlz4D8 |
| 0.7686 | cgpgrey/100-jlLUuX2a0Cg | techconnections/100-_AdBcTMHG0Q |
| 0.7789 | cgpgrey/100-jlLUuX2a0Cg | wendover/1-DPeRd48YfqY |
| 0.7803 | cgpgrey/80-SumDHcnCRuU | techconnections/33-XRCprhlz4D8 |
| 0.7821 | cgpgrey/80-SumDHcnCRuU | practicaleng/66-Seb3lULQruE |
| 0.7843 | cgpgrey/80-SumDHcnCRuU | practicaleng/1-7oi4yMr8Rjk |
| 0.8073 | cgpgrey/66-T0fAznO1wA8 | wendover/1-DPeRd48YfqY |
| 0.8094 | cgpgrey/100-jlLUuX2a0Cg | practicaleng/66-Seb3lULQruE |
| 0.8265 | cgpgrey/80-SumDHcnCRuU | practicaleng/33-YSQhtlyfPtU |
| 0.8388 | cgpgrey/80-SumDHcnCRuU | wendover/1-DPeRd48YfqY |

## Verdict

1. Clean-audio same-person cross-recording pairs separate decisively from different-person pairs. P max is 0.2270; N min is 0.4656; observed separation gap is 0.2386 with no overlap.
2. Recommended operating point from this corpus: `tau = 0.30`, `margin = 0.10`. At this point, TPR is 21/21 = 1.000, FPR is 0/84 = 0.000, and neither P nor N pairs fall in the gray band `(0.30, 0.40)`.
3. Compared with Phase 0 meeting numbers, where same-user cross-recording distances were 0.73-0.85, the meeting same-user distances land deep in the clean-corpus different-speaker region, not near clean same-speaker behavior. This supports the corpus-conditions hypothesis: the embedding path can work on clean narrator audio, while the meeting corpus likely had conditioning/track/AEC/contamination problems severe enough to destroy cross-recording identity consistency.
4. Recommendation: GO on the embedding path as viable, but do not treat Phase 0 meeting audio as representative; collect or derive a post-AEC, clean-segment meeting corpus before productizing thresholds.
