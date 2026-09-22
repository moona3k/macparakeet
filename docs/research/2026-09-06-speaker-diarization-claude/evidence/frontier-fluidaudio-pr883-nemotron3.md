### PR #883
feat(diarizer): Nemotron 3 Diarization support (8-speaker streaming Sortformer)
state: open merged: null updated: 2026-09-04T01:26:45Z

## Summary

Swift runtime for NVIDIA's **Nemotron 3 Diarization** ([early-access preview on HF](https://huggingface.co/nvidia/Nemotron-3-Diarization-preview)): 8 speakers, arrival-order channels, 10 ms output resolution, streaming and offline profiles. Code-only — **model weights are not included**; they load from a local directory and move to HuggingFace auto-download once NVIDIA's public release lands (converted models are staged and ready).

## What's included

- **`Nemotron3Diarizer` / `Nemotron3StateUpdater`** — port of NeMo `streaming_update_async` at batch 1: fixed-capacity speaker-cache/FIFO state, score-based cache compression using the checkpoint's learned silence embedding, first-vs-later compression prediction freezing, NeMo-exact tail chunking, 10 ms high-resolution output extracted before state mutation. Closed-loop output verified against the NeMo/PyTorch reference (99.995% frame agreement on a 120 s fixture; remaining deltas are file-tail padding alignment).
- **`Nemotron3Models`** — local-dir CoreML loading; stride-aware `vDSP_mmov` output readback (model outputs are fp16 with padded rows — naive reads either scramble or run ~40x slower); per-chunk autoreleasepool (long ANE-route runs otherwise exhaust the IOSurface pool — same failure class as #752); optional **split-graph mode** (feature stacking + the 1024→512 projection run host-side via one `cblas_sgemm`) yielding a 100% ANE-resident pure-fp transformer graph that avoids an ANECCompile limit on long chunk inputs.
- **Presets** — the four model-card profiles (`offline`/`low`/`verylow`/`ultra`) plus chunk-ladder profiles (`fast`, `fast24`, `fast32`, `fast128`, `efficient`) and `-int8` / `-split` selectors. Optional VAD gating (`speechMask`) skips inference across silence for sparse audio while preserving the output timeline.
- **CLI** — `nemotron3-diarize`, `nemotron3-benchmark` (AMI/VoxConverse harness, compute-unit routing, config sweep flags), `nemotron3-batch` (concurrent GPU workers).
- **Tests** — state-updater semantics (FIFO pop/flush, cache compression, silence slots), feature-loader tail handling, and padded-stride tensor-layout regression tests.

## Notes

- Benchmark figures are intentionally deferred to post-release documentation per the model's early-access evaluation terms; accuracy and throughput tables will land with the weights.
- The mel frontend reuses the existing `AudioMelSpectrogram` (same 128-mel / 10 ms family as Nemotron ASR).

## Testing

- `swift build -c release` clean; swift-format lint clean.
- Unit tests cover the state updater, feature loader, and tensor-layout regressions (CI).
- End-to-end parity against the NeMo reference validated on real audio via the benchmark harness.
