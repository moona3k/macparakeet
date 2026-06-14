# Plan: Live dictation preview — pill UI revamp + single-flight tail-window preview

> **Executor instructions**: Follow this plan phase by phase. **Build Part B0
> (the vertical slice) before anything else in Part B.** Run every verification
> command and confirm the expected result before moving on. If anything in
> "STOP conditions" occurs, stop and report. When done, update this plan's row
> in `plans/README.md` and `plans/active/2026-06-12-advisor-index.md`.
>
> **Background reading (read first)**: `docs/research/live-dictation-streaming.md`
> §0 (how we got here / the two complexities), §2 (mechanism), §3 (hard
> requirements). `Sources/MacParakeetCore/STT/README.md`, `spec/adr/016-*`,
> `spec/adr/021-*`.
>
> **Drift check (run first)**:
> `git diff --stat 8e62661d1..HEAD -- Sources/MacParakeetCore/STT/STTScheduler.swift Sources/MacParakeetCore/STT/STTRuntime.swift Sources/MacParakeetCore/STT/STTClientProtocol.swift Sources/MacParakeetCore/Services/Dictation/DictationService.swift Sources/MacParakeetCore/Audio/AudioRecorder.swift Sources/MacParakeet/App/AppEnvironment.swift Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift`
> Any change since `8e62661d1` → re-verify anchors (STOP on material mismatch).

## Status

- **Priority**: P2
- **Effort**: Part A = S/M (view-only). Part B = **M** — most of the work is the sample-preview API + single-flight scheduling + the decoupled sink. The transcript side is deliberately trivial (reuse batch transcribe; no LocalAgreement/trimming/two-tone).
- **Risk**: Part A LOW. Part B MEDIUM — touches the audio sample path and the ADR-016 interactive lane. The preview is **display-only ephemeral tail text** (never the paste), so it can't corrupt results; the risk is entirely in the plumbing/scheduling, which is why B0 comes first.
- **Depends on**: none. Keeps PR #496 (Nemotron native streaming) as-is.
- **Category**: feature (UI + STT preview)
- **Planned at**: `8e62661d1`, 2026-06-13 (settled after two adversarial reviews — research doc §0)
- **Requirement**: amends **REQ-STT-002** — "Dictation shows a **display-only** live preview for streaming-capable engines (Nemotron native; Parakeet/Whisper via a single-flight tail-window batch preview) while the paste comes from each engine's existing final path."

## Why this matters

The preview (PR #496) is a real win but is Nemotron-only (Beta) and deforms the
pill. Parakeet is the default; Whisper is the only engine for
Korean/Japanese/Chinese/+95 langs (zero live feedback today). Decision: the
preview is **display-only ephemeral tail text, never the result** — so the
mechanism is the simplest one that works (reuse batch transcribe), and the only
real complexity is the well-defined scheduler/sample API that keeps it from
touching the paste or engine-switch.

## Scope

**In scope**: (A) move the preview above the pill; (B) a single-flight tail-window
batch preview for Parakeet (+ Whisper if a latency probe clears), behind a
kill-switch, via an explicit sample-preview API.

**Explicitly NOT in v1** (display-only doesn't need them): LocalAgreement,
confirmed/volatile two-tone, timing-backed trimming, audio↔text alignment,
`SlidingWindowAsrManager`, `AudioStreamTranscriber`, streamed-final reuse.

**Invariants (MUST NOT change)**
- Final-result path (`DictationService.swift:856-923`): Parakeet/Whisper full-WAV batch on stop; Nemotron streamed final. Preview never becomes the Parakeet/Whisper paste.
- ADR-016 one-control-plane: preview goes through the scheduler via the new sample API; holds **no** `liveDictationSession` reservation; never starves the background meeting slot.
- Nemotron native path untouched; engine-switch guards (ADR-021) untouched.

## Current state (verified anchors)

- **No live frames for Parakeet/Whisper.** Sink created only on the native live path (`DictationService.swift:714-789`); `AudioRecorder` mirrors only if `sampleSink != nil` (`:536-541`).
- **STT is path-based.** `STTTranscribing.transcribe(audioPath:)` (`STTClientProtocol.swift:17`); jobs carry `audioPath` (`STTScheduler.swift:23`); runtime Parakeet `manager.transcribe(audioURL)` (`STTRuntime.swift:275`). `[Float]` batch exists underneath (`AsrManager.swift:482`, `WhisperKit.swift:896`) but isn't exposed through the scheduler.
- **Scheduler rejects interactive work during a live session** (`STTScheduler.swift:395-397`); slots: `.dictation`→interactive, meetings/file→background (`:654-665`).
- **UI**: preview inside the capsule (`DictationOverlayView.swift:427,509`; capsule wraps `pillContent` `:323-340`); `body` VStack bottom-aligned w/ headroom (`:232,:252`); panel `300×160` (`DictationOverlayController.swift`).
- Engines: `parakeet, nemotron, whisper` (`SpeechEnginePreference.swift:3-6`).

---

## Part A — Preview above the pill (ship-on-its-own, LOW risk)

- **A1**: remove `liveTranscriptPreviewText(...)` from `holdToTalkContent` (`:427`) + `recordingContent` (`:509`) so the capsule returns to its compact shape. Add a floating preview as a sibling **above** `overlayContent` in `body` (`:232`), gated on `state == .recording && preview present`; grows upward into the headroom, pill pinned.
- **A2**: style as **single-style ephemeral tail text** (reuse DesignSystem atoms; shape differs from the pill; display-only — no hit targets). No two-tone.
- **A3**: if 2 lines clip, bump panel height (160→190) keeping the bottom anchor + re-center; don't touch width.
- **A4 verify**: `scripts/dev/run_app.sh` (Nemotron) — capsule identical at all times, preview floats above; `swift build --target MacParakeet`. Shippable as its own PR.

---

## Part B — Single-flight tail-window preview

### B0 — Vertical slice FIRST (plumbing + scheduling, with a FAKE transcriber) — gate before anything else

- **B0.1 Decouple the sample sink.** A *display-preview* sink in `DictationService`/`AudioRecorder` that can be non-nil for Parakeet/Whisper, independent of `beginLiveDictationTranscriptionIfAvailable` (stays Nemotron-only). Frames arrive 16 kHz-mono (`AudioRecorder.swift:536-541`).
- **B0.2 Sample-preview API (explicit, not improvised).** Add a scheduler/runtime entry that transcribes a `[Float]` window on the interactive lane and **does not** hold a `liveDictationSession` reservation (so the final `.dictation` job is never rejected — `STTScheduler.swift:395`) and yields to the background meeting slot. Define cancellation semantics. Wire it to the existing `[Float]` batch underneath (`AsrManager.swift:482` / `WhisperKit.swift:896`).
- **B0.3 Single-flight driver.** A ~1s timer that issues a pass **only if none is in flight**, skips ticks while one runs, and **discards stale results by pass/session ID**.
- **B0.4 Fake transcriber.** Returns canned text after a delay. No real STT.
- **B0.5 Stop ordering.** On stop: cancel preview → await drain → existing final runs (`DictationService.swift:399-410`).
- **B0 gate (STOP if unmet)**: Parakeet/Whisper deliver frames to the fake preview; pill shows canned text; **final paste still from the WAV, unchanged**; a deliberately-slow/blocked preview pass does **not** delay/reject the final or engine-switch; single-flight holds (no overlapping passes, stale results dropped); meeting/background measured unaffected. Tests for each.

### B1 — Whisper latency probe (the one empirical unknown)
Time one `transcribe(audioArray:)` (`WhisperKit.swift:896`) on a ~15s clip, cold + warm; note CPU/ANE. Record in the research doc. Decide Whisper default-on vs off. (Parakeet needs no probe — its batch is fast; still sanity-check one pass.)

### B2 — Build the real preview
- Swap the fake for the real call: each pass transcribes the **last ~15s** `[Float]` window via the existing batch path; show the result as **ephemeral tail text** (single style). No trimming logic of our own (fixed *time* window; boundary artifacts live in the invisible head). Reuse the **existing** interactive `AsrManager`/Whisper engine — **no second manager**.
- **Capability + flag**: `SpeechEnginePreference.supportsLivePreview` (Parakeet true; Nemotron true via its native path; **Whisper per B1**) ANDed with `AppFeatures.liveDictationStreamingEnabled`. Generalize `AppEnvironment.swift:276`; keep the Nemotron native path.
- **Diagnostics**: fix hardcoded `engine=nemotron` (`DictationService.swift:787`); add `dictation_preview_pass engine=… ms=…`.

### B3 — Divergence handling (display-only honesty)
The preview is ephemeral, **not** a confirmed result; it can differ from the paste (cleanup/formatting/pre-roll). Reset/clear it on pre-roll discard (`DictationService.swift:505-512`). UI copy/treatment must not imply preview == paste. Acceptance test: preview text and final paste may differ without error.

### B4 — Verify
```
swift build && swift test
swift test --filter Preview
swift test --filter DictationService
scripts/dev/run_app.sh   # Parakeet preview + status-quo paste; Whisper per B1; Nemotron unchanged; flag-off → none
```
Matrix: Parakeet preview + unchanged paste latency; single-flight (no overlap, stale dropped); blocked preview → final unaffected; Whisper per B1; kill-switch off → none; long dictation → fixed-window passes stay bounded.

**Part B done**: Parakeet (+ Whisper if B1 clears) shows ephemeral tail preview, **no new model download**, **no change to the paste path**, scheduler-safe (final/engine-switch never blocked), single-flight enforced, Nemotron unchanged, full `swift test` green.

---

## Future (explicitly not v1)
Confirmed/volatile two-tone + a smoother source (e.g. `SlidingWindowAsrManager`) only if the ephemeral preview's tail wobble proves distracting in practice. Confirmed-prefix-reuse fast-final for slow engines. Both sit behind the same display-only seam — localized later changes, not now.

## Tests
- B0: Parakeet/Whisper frames → fake preview; final-from-WAV unchanged; blocked-preview-doesn't-block-final; single-flight (no overlap, stale-by-ID dropped); cancel/drain on stop.
- `DictationServiceTests`: Parakeet/Whisper final still WAV; preview/paste divergence allowed; Nemotron unchanged.
- Capability + kill-switch truth tables.
- Part A: screenshots + overlay VM tests.

## Docs to update (after shipping)
REQ-STT-002 (above); `CLAUDE.md` Release Channels (feature + `liveDictationStreamingEnabled` in the main-vs-release delta); `Sources/MacParakeetCore/STT/README.md` (display-only ephemeral preview + sample-preview API + single-flight + "never the paste"); `docs/research/live-dictation-streaming.md` (record Whisper probe; flip status); `spec/02-features.md`/`spec/README.md`. Move plan → `completed/`; update board + advisor index. Note: ADR-016 cites FluidAudio 0.13.6 but `Package.resolved` is 0.15.2 — reconcile.

## STOP conditions
- Drift on any anchor since `8e62661d1`.
- Can't deliver Parakeet/Whisper frames without entangling the Nemotron live path, or can't run a preview pass without a `liveDictationSession` reservation → STOP (re-architect the lane story first).
- A preview pass blocks/rejects the final `.dictation` job or engine-switch, or starves meeting work → STOP.
- The preview can become the Parakeet/Whisper paste → STOP (must stay display-only).
- Tempted to add LocalAgreement / confirmed-volatile / timing-backed trimming / a second manager → STOP, that's explicitly out of v1.
- Whisper pass p95 makes the preview multi-seconds stale → keep Whisper preview default-off.

## References
`docs/research/live-dictation-streaming.md` §0 (reviews + the two complexities), §2 (mechanism), §3 (hard requirements), §9 (file:line index).
