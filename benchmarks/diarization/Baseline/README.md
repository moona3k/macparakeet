# Frozen FluidAudio 0.15.7 baseline

This standalone package reproduces the acoustic diarization configuration from
MacParakeet commit `7ad569afae560266b37a0003e9e2b9f17a2dfa47`, in
[`DiarizationService.swift`](../../../Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift).
It resolves FluidAudio **exactly 0.15.7**, revision
`41540ea237350afe5117a082b5c28eda642d0612`. A separate Swift package is necessary
because the main app now resolves the candidate SDK; running its `community1`
backend would measure the upgraded SDK rather than the original baseline.

Preserved behavior:

- `OfflineDiarizerConfig.default`, with segmentation step ratio `0.1`, embedding
  minimum duration `0`, and zero-vote re-embedding enabled.
- Automatic speaker count; no oracle count, calendar cap, profile consolidation,
  or threshold retuning.
- `OfflineDiarizerModels.load(from:)` without prewarming or custom compute units:
  segmentation/embedding/PLDA use `.all`; FBank uses `.cpuOnly`.
- Chronological stable speaker IDs, rounded/clamped integer millisecond boundaries,
  and a successful empty result for `noSpeechDetected`.

The runner emits raw acoustic intervals before word assignment and smoothing,
matching the candidate benchmark boundary. It does not run ASR, enroll voiceprints,
write library history, or normalize centroids that the scorer does not consume.
Model preparation is timed separately from audio loading/inference and segment
mapping. Compile both runners in release mode for throughput comparisons. Do not
run their inferences concurrently; otherwise timing and shared accelerator load
are not comparable. The standalone runner has no cross-process macOS 14 ANE gate.

## Build and run

The standalone benchmark requires Swift 6.2 or newer for package traits. This
does not change the app package's tools-version or its CI toolchain requirement.

From this directory:

```bash
swift build -c release -j 2
.build/release/diarization-baseline --help
.build/release/diarization-baseline /path/ami_ES2004a_mhm.wav \
  --models-directory "$HOME/Library/Application Support/FluidAudio/Models" \
  --output /path/predictions/community1-0.15.7/ami_ES2004a_mhm.json
```

The model root must contain `speaker-diarization/` with `Segmentation.mlmodelc`,
`Embedding.mlmodelc`, `FBank.mlmodelc`, `PldaRho.mlmodelc`, and
`plda-parameters.json`. This is the parent directory accepted by the SDK, not the
model repository directory itself. The runner requires existing models and sets
`ModelHub.offlineMode = true`; it will not download or repair shared cache files.
Malformed PLDA metadata fails visibly instead of invoking the app's network repair.

The package pin does not establish the revision of cached model bytes. Every JSON
records SHA-256 for the audio and all required model files, plus the full effective
configuration. Compare these hashes between baseline and upgraded Community-1
controls; record the candidate model export separately. Do not label an existing
cache as a particular upstream model revision without matching its bytes.

TTS text normalization is disabled through FluidAudio's optional package trait to
avoid linking its unrelated runtime. SwiftPM may still resolve its cached binary
artifact while evaluating the dependency manifest. Diarization is unmodified.
