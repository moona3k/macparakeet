# Issue 997 — long-file Parakeet STT Core ML failure

Date: 2026-09-09
Status: diagnosis + fix (`ParakeetTDTASRConfig`, `parallelChunkConcurrency: 1` on macOS 14).

**Verdict:** Hour-class Parakeet TDT file / YouTube / meeting transcription was
broken on macOS 14. The YouTube URL in
[#997](https://github.com/moona3k/macparakeet/issues/997) is valid. The crash is
four concurrent Core ML `prediction()` calls on a shared ANE model, which
FluidAudio documents as non-reentrant. MacParakeet's `ANEInferenceGate` does
not serialize those inner workers. macOS 15+ rewrote the ANE runtime and
succeeds at ~99%.

The product fix is `ParakeetTDTASRConfig.make()`: concurrency 1 on macOS 14,
FluidAudio default 4 on 15+. Dictation is unchanged.

Read [report.md](report.md). Telemetry SQL is in
[evidence/d1-queries.md](evidence/d1-queries.md).
