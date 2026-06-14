# Plan: Live dictation preview — pill UI revamp + all-engine streaming preview

> **Executor instructions**: Follow this plan phase by phase. **Build Part B0
> (the vertical slice) before anything else in Part B** — do not wire a real
> mechanism or UI polish until B0's gate passes. Run every verification
> command and confirm the expected result before moving on. If anything in
> "STOP conditions" occurs, stop and report. When done, update this plan's row
> in `plans/README.md` and `plans/active/2026-06-12-advisor-index.md`.
>
> **Background reading (read first)**: `docs/research/live-dictation-streaming.md`
> — especially §0 (review-driven corrections) and §3 (hard constraints).
> `Sources/MacParakeetCore/STT/README.md`, `spec/adr/016-*` (scheduler/slots),
> `spec/adr/021-*` (engine routing).
>
> **Drift check (run first)**:
> `git diff --stat 8e62661d1..HEAD -- Sources/MacParakeetCore/STT/STTScheduler.swift Sources/MacParakeetCore/STT/STTRuntime.swift Sources/MacParakeetCore/STT/STTClientProtocol.swift Sources/MacParakeetCore/Services/Dictation/DictationService.swift Sources/MacParakeetCore/Audio/AudioRecorder.swift Sources/MacParakeet/App/AppEnvironment.swift Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift`
> Any change since `8e62661d1` → re-verify the anchors before proceeding (STOP on material mismatch).

## Status

- **Priority**: P2
- **Effort**: Part A = S/M (view-only). Part B = **L** (audio-plumbing + scheduler work, then wire Parakeet `SlidingWindowAsrManager` + a short Whisper latency probe, then build). The earlier "M" estimate was wrong — see the review corrections.
- **Risk**: Part A LOW. Part B MEDIUM — touches the audio sample path and the ADR-016 interactive slot. The preview stays **display-only** (never the paste), so it can't corrupt results, but the plumbing/scheduling is real work.
- **Depends on**: none. Keeps PR #496 (Nemotron native streaming) as-is.
- **Category**: feature (UI + STT preview)
- **Planned at**: `8e62661d1`, 2026-06-13 (revised after an adversarial code review — see research doc §0)
- **Requirement**: amends **REQ-STT-002** — generalize to: "Dictation shows a **display-only** live preview for streaming-capable engines (Nemotron native; Parakeet/Whisper via the chosen preview mechanism) while the paste continues to come from each engine's existing final path."

## Why this matters

The preview (PR #496) is a real win but is Nemotron-only (Beta) and deforms the
pill. **Parakeet is the default**; **Whisper is the only engine** for
Korean/Japanese/Chinese/+95 langs (zero live feedback today). The architecture
decision: **the preview is a display-only, stable feedback surface, never the
result** — so it can't corrupt the paste and the heavy PR #496 machinery isn't
generalized.

## Scope

**In scope**: (A) move the preview above the pill; (B) extend a display-only
preview to Parakeet + Whisper via the studied mechanism (Parakeet `SlidingWindowAsrManager`; Whisper after a latency probe), behind a
kill-switch; (C) stable/volatile two-tone rendering.

**Out of scope / invariants (MUST NOT change)**
- The **final-result path** (`DictationService.swift:856-923`). Parakeet/Whisper keep full-WAV batch on stop; Nemotron keeps its streamed final. The preview never becomes the Parakeet/Whisper paste.
- ADR-016 one-control-plane: preview transcription goes **through the scheduler**, not a direct runtime call. It must not hold a `liveDictationSession` reservation (else the final `.dictation` job is rejected — `STTScheduler.swift:395`) and must not starve the background meeting slot.
- Nemotron native streaming path — untouched.
- Engine-switch guards while speech work / a meeting lease is active (ADR-021).

## Current state (verified anchors)

- **Sample frames are Nemotron-gated.** Sink created only on the native live path (`DictationService.swift:714-789`); `AudioRecorder` mirrors only if `sampleSink != nil` (`:536-541`). Parakeet/Whisper get **no** live frames today.
- **STT is path-based.** `STTTranscribing` (`STTClientProtocol.swift:17-22`), scheduler jobs carry `audioPath` (`STTScheduler.swift:23-29,110-129`). No samples API.
- **Scheduler rejects interactive work during a live session** (`STTScheduler.swift:395-397`). Slots: `.dictation`→interactive, meetings/file→background (`:654-665`).
- **No text↔audio alignment contract** on `STTResult` (`STTResult.swift:3-5,30-34`); Parakeet passes pad to 15s, Whisper to 30s.
- **UI**: preview inside the capsule (`DictationOverlayView.swift:427,509`; capsule wraps `pillContent` `:323-340`); `body` VStack bottom-aligned with headroom (`:232,:252`). Panel fixed `300×160` (`DictationOverlayController.swift`).
- Engines: `parakeet, nemotron, whisper` (`SpeechEnginePreference.swift:3-6`). Batch-on-samples exists underneath: FluidAudio `AsrManager.transcribe`, WhisperKit `transcribe(audioArray:)` (`WhisperKit.swift:896`).

---

## Part A — Preview above the pill (ship-on-its-own, LOW risk)

Independent of Part B; fixes the visible deformation for Nemotron today.

- **A1**: remove `liveTranscriptPreviewText(...)` from `holdToTalkContent` (`:427`) + `recordingContent` (`:509`) so the capsule returns to its compact shape. Add a floating preview view as a sibling **above** `overlayContent` in `body` (`:232`), gated on `state == .recording && preview present`; bottom-aligned stack grows it upward into the headroom, pill pinned.
- **A2**: style as a floating caption (reuse DesignSystem atoms, shape differs from the pill; display-only — no hit targets).
- **A3**: if 2 lines clip, bump panel height (160→190) keeping the bottom anchor + re-center; don't touch width.
- **A4 verify**: `scripts/dev/run_app.sh` (Nemotron) — capsule identical at all times, preview floats above; `swift build --target MacParakeet`. Shippable as its own PR.

---

## Part B — All-engine display-only preview

### B0 — Vertical slice FIRST (plumbing, with a FAKE transcriber) — gate before anything else

Prove the two risky systems end-to-end before any mechanism/UI work.

- **B0.1 Decouple the sample sink.** Add a *display-preview* sample sink path in `DictationService`/`AudioRecorder` that can be non-nil for **Parakeet/Whisper** independent of `beginLiveDictationTranscriptionIfAvailable` (which stays Nemotron-only). Frames already arrive 16 kHz-mono in the recorder's converted path (`AudioRecorder.swift:536-541`).
- **B0.2 Scheduler-safe preview task.** Define how a preview pass runs as STT work: a cancellable scheduler task that does **not** take a `liveDictationSession` reservation and yields to the background meeting slot. (Likely a new lightweight preview admission path on the interactive slot, or an explicit non-queued preview API that still respects the one-control-plane — decide here, with cancellation semantics.)
- **B0.3 Fake preview transcriber.** Wire a stub that returns canned text on a timer. No real STT, no LocalAgreement.
- **B0.4 Stop ordering.** On stop: **cancel preview → await drain → then the existing final** runs (`DictationService.swift:399-410`). Verify the final `.dictation` job is never rejected/queued behind a preview pass.
- **B0 gate (STOP if unmet)**: Parakeet/Whisper deliver live frames to the fake preview; overlay shows the canned text; **final paste still comes from the WAV, unchanged**; a deliberately-blocked preview pass does **not** delay/booby the final; meeting + background work measured as unaffected. Tests for each.

### B1 — Mechanism (decided by study) + one Whisper latency probe

The mechanism is settled by reading the code, not a bake-off:
- **Parakeet → FluidAudio `SlidingWindowAsrManager`.** It ships windowing, token dedup, confirmed/volatile, **token timings** (→ safe trimming), and bounded buffers, and reuses the loaded `AsrModels`. The generic re-transcriber would reimplement exactly these with less engine knowledge — don't. No spike.
- **Whisper → one latency probe, then decide.** Whisper pads every pass to a 30s decode, so reasoning can't tell you if the preview is fast enough. Probe: time one `transcribe(audioArray:)` on a ~15s clip, cold + warm, and note CPU/ANE. If usable, pick `AudioStreamTranscriber` (+ a passthrough `AudioProcessing` fed by our mic) or a thin batch re-transcriber (small choice, made then) and consider default-on; if too slow, ship Whisper preview **off**. Record the number in the research doc.
- **Constraints any choice must meet** (research doc §3): timing-backed confirmation + absolute sample offset + left-context retention (never text-prefix trimming); display-only; the B0 scheduling/stop rules.

### B2 — Build the chosen mechanism(s)
- Parakeet: a thin adapter around `SlidingWindowAsrManager` behind the B0 display-only sink (map its confirmed/volatile + token timings to the preview). Whisper (if the probe cleared): its chosen mechanism.
- **Capability + flag**: `SpeechEnginePreference.supportsLivePreview` (Parakeet/Nemotron true; **Whisper gated on B1 latency** — may ship default-off) ANDed with `AppFeatures.liveDictationStreamingEnabled`. Generalize `AppEnvironment.swift:276` accordingly; keep the Nemotron native path as-is.
- **Diagnostics**: fix the hardcoded `engine=nemotron` (`DictationService.swift:787`); add `dictation_preview_pass engine=… ms=…`.

### B3 — Final-result policy (unchanged) + divergence handling
- Parakeet/Whisper final stays full-WAV batch; Nemotron streamed final. Document **confirmed-prefix-reuse** fast-final for slow engines as a *follow-up*, not v1.
- **Divergence (review finding 6)**: the preview is a **stable preview, not a confirmed result**. Reset/clear it on pre-roll discard (`DictationService.swift:505-512`). UI copy/treatment must not imply the preview *is* the paste. Add an acceptance test asserting preview text and final paste may differ (formatting/cleanup/pre-roll) without error.

### B4 — Verify
```
swift build && swift test
swift test --filter Preview        # B0 plumbing + mechanism
swift test --filter DictationService
scripts/dev/run_app.sh             # Parakeet preview + status-quo paste; Whisper (if enabled) preview + paste; Nemotron unchanged; flag-off → none
```
Matrix: Parakeet preview + unchanged paste latency; Whisper per B1 decision; Nemotron unchanged; kill-switch off → no preview anywhere; long dictation → bounded passes (no slowdown); blocked preview pass → final unaffected.

**Part B done**: live preview for Parakeet (and Whisper if B1 clears latency) with **no new model download**, **no change to the paste path**, scheduler-safe (final never blocked), Nemotron unchanged, full `swift test` green.

---

## Part C — Stable/volatile two-tone (folds into Part A once B2 emits two tiers)
Widen the preview field from `String` to `{ stable, volatile }` through `DictationService` → snapshot → overlay VM; render stable bright / volatile dim. Uniform across engines. Own commit after A+B.

## Tests
- B0: Parakeet/Whisper deliver frames to a fake preview; final-from-WAV unchanged; blocked-preview-doesn't-block-final; cancel/drain on stop.
- Mechanism: timing-backed confirmation + trimming correctness (no mid-word cuts; absolute offset); no pass pile-up; cancel teardown.
- `DictationServiceTests`: Parakeet/Whisper final still WAV; preview/paste divergence allowed; Nemotron unchanged.
- Capability + kill-switch truth tables.
- Part A: screenshots + overlay VM tests.

## Docs to update (after shipping)
- REQ-STT-002 (generalization above); `CLAUDE.md` Release Channels (feature + `liveDictationStreamingEnabled` in the main-vs-release delta); `Sources/MacParakeetCore/STT/README.md` (display-only preview path + "never the paste" rule + the chosen mechanism); `docs/research/live-dictation-streaming.md` (record Whisper probe numbers + flip status); `spec/02-features.md`/`spec/README.md`. Move plan → `completed/`; update board + advisor index. Note: ADR-016 cites FluidAudio 0.13.6 but `Package.resolved` is 0.15.2 — reconcile.

## STOP conditions
- Drift on any anchor since `8e62661d1`.
- B0 can't deliver Parakeet/Whisper frames without entangling the Nemotron live path, or can't run preview without a `liveDictationSession` reservation → STOP (re-architect the slot story before building).
- A preview pass blocks/rejects the final `.dictation` job, or starves meeting work → STOP.
- The preview can become the Parakeet/Whisper paste → STOP (must stay display-only).
- Whisper pass p95 makes the preview multi-seconds stale → keep Whisper preview default-off; don't force it.
- Trimming based on text prefix instead of timings → STOP (finding 3).

## References
`docs/research/live-dictation-streaming.md` §0 (corrections), §3 (constraints), §9 (full file:line index).
