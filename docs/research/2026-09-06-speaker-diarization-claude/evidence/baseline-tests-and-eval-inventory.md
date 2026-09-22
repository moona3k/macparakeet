# Evidence: tests and evaluation assets touching speaker attribution (origin/main 57e3391a)

## Unit tests in the repo

| File | What it covers | What it does not cover |
|---|---|---|
| Tests/MacParakeetTests/Services/Diarization/DiarizationServiceTests.swift (1-174) | Mock behavior; model cache dir; `offlineConfig` constraint mapping; chronological "S1" remap with a recording fake manager | Never runs the real FluidAudio pipeline; no audio |
| Tests/MacParakeetTests/Services/Diarization/SpeakerMergerTests.swift (1-186) | Empty inputs, exact/partial overlap, gaps, ties, many speakers, content preservation | Real word-timing jitter; overlapping segments; short segments |
| Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift:540-600 | File path skips diarization without word timings | |
| Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift:2465-2546 | Meeting: system-only diarization, offset shift, "Me"/"Others 1"/"Others 2" roster | |
| Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift:2548-2648 | Meeting preference gating | |
| Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift:2649-2711 | Uncovered system words keep "Others" alongside "Others 1" | |
| Tests/MacParakeetTests/Services/MeetingRecording/MeetingTranscriptSourceReconcilerTests.swift | Echo duplicate removal rules (10 tests) | |
| Tests/MacParakeetTests/Services/MeetingRecording/MeetingTranscriptAssemblerTests.swift | Live preview source labels (6 tests) | |
| Tests/MacParakeetTests/Utilities/TranscriptSegmenterTests.swift | Segment boundaries, nil-speaker inheritance, stats, labels (21 tests) | |
| Tests/CLITests/TranscribeCommandTests.swift | Flag resolution | |
| Tests/MacParakeetTests/Benchmarks/LongMeetingPipelineBenchmarkTests.swift | Env-gated end-to-end timing on a retained session with real `DiarizationService()` (118-119, 379-380) | Measures elapsed time and RSS only; no accuracy metric |

There is no `MeetingTranscriptFinalizerTests.swift`; finalizer behavior is exercised through
TranscriptionServiceTests and the reconciler tests.

## Accuracy harnesses

- No RTTM, DER, or word-attribution scoring code exists under Sources/, Tests/, or scripts/
  (grep for `DER`, `rttm`, `diarization error` over the repo found only docs).
- scripts/dev/benchmark_stt_engines.sh benchmarks ASR only.
- docs/research/2026-07-04-voiceprints-phase0/harness/ is a separate SwiftPM package that runs
  the FluidAudio offline diarizer on a file and exports per-cluster embeddings (used for the
  voiceprint calibration, not DER).
- FluidAudio checkout: `Sources/FluidAudioCLI/Commands/DiarizationBenchmark.swift`,
  `Sources/FluidAudioCLI/Utils/DiarizationMetrics.swift`, `Scripts/diarizer_subset_benchmark.sh`
  (AMI SDM and VoxConverse, auto-download) and the library-level `DiarizationDER.compute`.

## Telemetry

- `diarizationStarted`, `diarizationCompleted(source:speakerCount:durationSeconds:)`,
  `diarizationFailed` (TranscriptionService.swift:1504-1512, 1542-1546, 1694-1725). Only the
  detected speaker count is reported; no accuracy or correction signal.
- `renameSpeaker` persistence failures are classified (TranscriptionViewModel.swift:1662-1673);
  successful renames are not counted as a correction-burden signal.
