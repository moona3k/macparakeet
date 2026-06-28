# Plan: Meeting AEC measurement harness (measure before choosing an engine)

> **Status board row**: add to `plans/README.md` under Active plans.

## Status

- **Priority**: P1 (gates the #605 AEC cluster — the next meeting P0)
- **Effort**: S so far (test-only harness shipped); M–L remains (engine adapters + real-recording runs)
- **Risk**: LOW for this slice (test-target only; zero production change)
- **Category**: tests / characterization
- **Planned at**: 2026-06-27, branch `test/meeting-aec-measurement-harness`
- **Relates**: `docs/research/2026-06-meeting-aec-open-issues-prior-art.md`,
  ADR-014, `spec/05-audio-pipeline.md`, issues #605/#480/#430/#501/#542/#106

## Why this matters

The recommended fix for speaker-mode echo (system audio bleeding into the mic)
is reference-based AEC: feed the system-audio track to an echo canceller, derive
a cleaned mic for transcription, keep raw mic/system as truth. The prior-art note
concluded LocalVQE is the best-fitting first engine and WebRTC AEC3 the benchmark
— but **"will it actually work for us" is unproven**: no audio has been run
through the pipeline, and the reported LocalVQE accuracy is on a public dataset,
not our recordings.

A real Zoom recording can't answer this cleanly because it doesn't expose the
separate near-end, far-end, and echo signals, so you can't attribute "removed
echo" vs "damaged the local voice." This harness builds **ground-truth synthetic
fixtures** where all three are known, so the metrics are exact. It is the
yardstick any candidate engine (LocalVQE, WebRTC AEC3, classical NLMS) gets
scored on, and it runs in CI with no model download or native binary.

## What shipped in this slice (test-target only)

`Tests/MacParakeetTests/Services/Capture/MeetingAecMeasurementHarness.swift`:

- **Fixtures** (`MeetingAecScenarioFactory`): deterministic, seeded, speech-like
  near-end and far-end talkers (decorrelated), a configurable sparse echo path
  (delay + gains, optional nonlinearity), composed into the three canonical
  scenarios — far-end-only, near-end-only, double-talk — each retaining full
  ground truth.
- **Metrics** (`MeetingAecMetrics`): ERLE (dB), near-end error vs the ideal local
  voice (dB; captures residual echo AND voice damage), and max-abs drift.
- **Reference processors**: `MeetingAecNLMSProcessor` (classical NLMS baseline,
  deliberately no double-talk detector) and `MeetingAecOracleSubtractor` (knows
  the true echo gain — the perfect-alignment yardstick). Both conform to the real
  `MeetingEchoSuppressing` protocol and run through the shipping
  `StreamingMeetingEchoSuppressor`, so the harness exercises the production
  frame-carry / reference-delay / flush path, not a mock of it.
- **Runner**: streams a scenario through any `MicConditioning` in irregular
  chunks (so chunk boundaries are exercised) and returns output aligned 1:1 to
  the mic.

`Tests/MacParakeetTests/Services/Capture/MeetingAecMeasurementTests.swift`: 7
tests asserting the harness is sound and printing the first real numbers.

## First numbers (this branch, deterministic)

| Scenario | Engine | Result |
| --- | --- | --- |
| far-end-only | pass-through | ERLE ≈ 0 dB (sanity) |
| far-end-only | oracle, reference aligned | **ERLE 56.5 dB** (cancels to the noise floor) |
| far-end-only | oracle, reference 2.5 ms off | **ERLE −2.7 dB** (cancellation destroyed) |
| far-end-only | NLMS baseline | **ERLE 36.0 dB** |
| near-end-only (silent remote) | NLMS baseline | exact pass-through (no voice damage) |
| double-talk | NLMS baseline | near-end error raw −2.8 → −2.1 dB (**−0.7 dB; it slightly hurts**) |

Two findings that should shape the engine work:

1. **Reference/mic time alignment is the dominant risk.** A 2.5 ms (40-sample at
   16 kHz) misalignment turns 56 dB of cancellation into none. Our
   `referenceDelaySamples` is a *static* config today; LocalVQE/Muesli use an
   *adaptive* delay estimator. An adaptive estimator is likely required for real
   recordings, where mic and ScreenCaptureKit clocks drift.
2. **Double-talk is the hard gate.** A naive linear canceller gets 36 dB in
   single-talk but nets a slight regression under continuous double-talk, because
   the near-end perturbs adaptation. Any shipping engine must be scored on
   double-talk near-end retention, not just echo removal.

## What's next (not in this slice)

1. **Adaptive delay estimation** in/around the conditioner, characterized by the
   delay-sweep fixture, so alignment survives real clock drift.
2. **LocalVQE adapter**: build/sign/notarize `liblocalvqe.dylib`, bundle a model
   (test `v1.4-aec` echo-only vs `v1.2` joint), run it through this harness, then
   a `microphone-cleaned.m4a` artifact + cleaned-mic final STT, behind the
   existing runtime/asset gate. Raw mic/system stay truth.
3. **WebRTC AEC3 adapter** scored on the identical fixtures as the benchmark.
4. **Nonlinear-echo and reverberant fixtures** (where neural is expected to beat
   the linear NLMS baseline), plus **real Zoom/Meet/Teams recordings** for the
   final #605 release proof.
5. Consider promoting the harness to a `macparakeet-cli aec-bench` surface so the
   bake-off is reproducible outside the test target.

## Release proof for #605 (unchanged from the research note)

Raw mic/system preserved; cleaned mic path exists; far-end-only → little/no false
`Me`; near-end-only retained; double-talk keeps the local speaker; ≥1 real
speaker-mode recording passes manual QA; fixtures report ERLE/near-end retention,
not just fewer words; missing/partial/delayed references fall back and log.

## Verification

```bash
swift test --filter MeetingAecMeasurementTests   # 7 tests, prints the metrics
swift test                                       # full suite (test-only change)
```

## Scope / invariants

- Test-target only. No production behavior change; Core is untouched.
- The harness drives the real `StreamingMeetingEchoSuppressor` /
  `MicConditioning` seam, so it stays honest as that code evolves.
