# Plan: Live dictation preview — pill UI revamp + unified all-engine streaming preview

> **Executor instructions**: Follow this plan phase by phase. Run every
> verification command and confirm the expected result before moving on. Part A
> (UI) and Part B (all-engine preview) are independently shippable — Part A can
> merge alone. If anything in "STOP conditions" occurs, stop and report — do not
> improvise. When done, update this plan's row in `plans/README.md` and
> `plans/active/2026-06-12-advisor-index.md`.
>
> **Background reading (read first)**: `docs/research/live-dictation-streaming.md`
> is the decided architecture this plan executes (read its TL;DR + §1–§5).
> `Sources/MacParakeetCore/STT/README.md`, `spec/adr/016-*` (scheduler/slots),
> `spec/adr/021-*` (engine routing).
>
> **Drift check (run first)**:
> `git diff --stat 8e62661d1..HEAD -- Sources/MacParakeetCore/STT/STTScheduler.swift Sources/MacParakeetCore/STT/STTRuntime.swift Sources/MacParakeetCore/STT/NemotronEngine.swift Sources/MacParakeetCore/STT/STTClientProtocol.swift Sources/MacParakeet/App/AppEnvironment.swift Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
> If any changed since `8e62661d1`, re-read the "Current state" excerpts against
> live code before proceeding; on a material mismatch treat it as a STOP.

## Status

- **Priority**: P2 (UX upgrade + capability extension; not a correctness fix)
- **Effort**: Part A = S/M (SwiftUI restructure). Part B = M/L (one new generic component + runtime sample-transcribe entry + wiring). Part C (two-tone) folds into A once B exists.
- **Risk**: Part A LOW (view-only). Part B MEDIUM-LOW — **the preview is display-only and never the paste**, so it cannot corrupt the result; the existing final/fallback path is unchanged. Mitigated further by the kill-switch.
- **Depends on**: none. Builds on PR #496 (Nemotron native streaming, on `main`, unreleased) which we **keep as-is**.
- **Category**: feature (UI + STT preview)
- **Planned at**: commit `8e62661d1`, 2026-06-13
- **Requirement**: amends **REQ-STT-002**. Today it reads "Nemotron dictation streams live partial text…". Generalize to: "Dictation shows a **display-only** live preview for all streaming-capable engines — Nemotron via native streaming, Parakeet and Whisper via periodic re-transcription — while the pasted result continues to come from each engine's existing final path."

## Why this matters

The live preview (PR #496) is a real perceived-speed win, but ships with two
limits worth removing: (1) it deforms the floating pill (renders inside the
capsule), and (2) it's Nemotron-only — and Nemotron is opt-in **Beta**, while
**Parakeet is the default** and **Whisper is the only engine** for
Korean/Japanese/Chinese/+95 languages (those users get zero live feedback today).

The architecture decision (see research doc): **the preview is a display-only
feedback surface, never the result.** That lets one generic re-transcription
mechanism cover every engine by reusing its existing batch transcribe — no
per-engine streaming integrations, no new correctness surface.

## Scope

**In scope**
- Part A: move the preview out of the capsule to a floating element above the pill; pill geometry untouched.
- Part B: a generic `RetranscribingPreviewSource` (LocalAgreement-2 over each engine's existing `[Float]` batch transcribe), wired for **Parakeet + Whisper**; Nemotron keeps its native streaming. A `supportsLivePreview` capability (true for all three) + an `AppFeatures.liveDictationStreamingEnabled` kill-switch.
- Part C: confirmed/volatile two-tone rendering — folds into Part A's preview view once B produces the two tiers. Uniform across engines.

**Out of scope / invariants (MUST NOT change)**
- The **final-result path**. Parakeet/Whisper keep full-WAV batch on stop; Nemotron keeps its streamed final + degrade-to-WAV machinery (`DictationService.swift:856-923`). The preview never becomes the paste for Parakeet/Whisper.
- Whisper does **not** get its own bespoke streaming integration (no `AudioStreamTranscriber` adapter) — it rides the generic re-transcriber.
- ADR-016 slot model: live preview runs on the **interactive** slot; meeting work stays on the background slot. The scheduler's reservation re-check / orphan-unwind (`STTScheduler.swift:195-205`) stays.
- No change to engine *switching* guards while speech work / a meeting lease is active (ADR-021).

## Current state (anchors — verify in drift check)

**Gates that are Nemotron-specific (widen to a capability):**
- `Sources/MacParakeet/App/AppEnvironment.swift:276` — `shouldAttemptLiveDictationTranscription: { SpeechEnginePreference.current() == .nemotron }`
- `Sources/MacParakeetCore/STT/STTScheduler.swift:186` — `guard selection.engine == .nemotron …`
- `Sources/MacParakeetCore/STT/STTRuntime.swift:165` — `guard speechEngine == .nemotron …`; `append/finish/cancel` **hardcode `nemotronEngine`** (`:188`+).

**Batch transcribe on `[Float]` (the re-transcriber's primitive) — verified to exist:**
- FluidAudio `AsrManager.transcribe(...)` (sample-based; Parakeet TDT, the model already loaded for the interactive slot — `STTRuntime.swift:67-69`).
- WhisperKit `transcribe(audioArray: [Float])` (`WhisperKit.swift:547`).
- Nemotron `manager.process(samples:)` (already used by the live path).
- App-facing `STTTranscribing` (`STTClientProtocol.swift:17`) is **path-based** today — Part B adds a samples entry on the interactive slot.

**Engine enum:** `SpeechEnginePreference { case parakeet, nemotron, whisper }` (`SpeechEnginePreference.swift:3-6`).

**UI (the deformation):** `DictationOverlayView.swift` — `liveTranscriptPreviewText(width:)` (`:455-467`) embedded **inside** the capsule via `holdToTalkContent` (`:427`) and `recordingContent` (`:509`); capsule wraps `pillContent` (`:323-340`); root `body` VStack bottom-aligned with headroom above the pill (`:232,:252`, tooltip at `:234`). Panel: fixed `300×160` `ClickablePanel` (`DictationOverlayController.swift`). Data flow: `DictationFlowCoordinator.swift:1104` polls `liveTranscript` (single `String`) → overlay VM; reset at `:445,:454`.

---

## Part A — Preview above the pill (ship-on-its-own)

Goal: pill keeps its exact capsule shape; the preview floats above it. Works for the single-`String` preview we have today (Nemotron) and the two-tier one from Part B. No data-flow change for v1.

### A1. Lift the preview out of the capsule
- Remove `liveTranscriptPreviewText(...)` from `holdToTalkContent` (`:427`) and `recordingContent` (`:509`); revert each to just its `HStack` so `pillContent` (and the `Capsule`) returns to the compact one-row shape.
- Add a new floating preview view as a **sibling above** `overlayContent` in the `body` VStack (`:232`), after the tooltip slot, gated on `state == .recording && preview present`. Bottom-aligned stack → it grows upward into the headroom; pill stays pinned.

### A2. Style the floating caption
- Reuse DesignSystem atoms (colors/opacities, 0.16 s ease) but let the shape differ from the pill ("siblings not twins"). Width ≤ pill width, centered. Display-only — no hover/click targets.

### A3. Panel headroom
- Verify 1–2 lines render within the `300×160` panel above the pill; if 2 lines clip, bump panel height (e.g. 160→190) keeping the bottom anchor + re-center on show; do not touch width logic.

### A4. Verify
```
scripts/dev/run_app.sh        # Nemotron, dictate: pill keeps shape, preview floats above
swift build --target MacParakeet
```
**Part A done**: capsule visually identical at all times; preview floats above, grows upward, never stretches the capsule; idle pill unaffected. Shippable as its own PR.

---

## Part B — Unified all-engine display-only preview

Goal: Parakeet + Whisper get a live preview via one generic re-transcriber over their existing batch transcribe; Nemotron keeps native streaming. Behind the kill-switch.

### B1. Capability + kill-switch
- `SpeechEnginePreference`: add `var supportsLivePreview: Bool { true }` for all three cases (Parakeet/Nemotron/Whisper). (Name it `supportsLivePreview`, not `…LiveDictation`, to signal display-only.)
- `AppFeatures.swift`: `public static let liveDictationStreamingEnabled: Bool = true`, doc-commented like `meetingVadLiveChunkingEnabled` (`:53`). Single off-switch for the whole feature.

### B2. Samples batch-transcribe entry on the interactive slot
- Add a runtime method to transcribe a `[Float]` window on the **interactive** slot using the *currently selected engine's* batch path — e.g. `STTRuntime.transcribeInteractiveSamples(_ samples: [Float]) async throws -> STTResult`. Route by engine to the underlying sample API (Parakeet `AsrManager.transcribe`, Whisper `WhisperKit.transcribe(audioArray:)`, Nemotron unused here). Must not disturb the background slot or meeting work.
- This reuses already-loaded models (Parakeet `AsrModels`, Whisper engine). No new downloads.

### B3. `RetranscribingPreviewSource` (the one generic component)
- New `Sources/MacParakeetCore/Services/Dictation/RetranscribingPreviewSource.swift` (actor). Responsibilities:
  - Accept `[Float]` frames (fed from the same live sample sink that exists today).
  - On a cadence (~700 ms–1 s, or "when the previous pass finishes," whichever is slower), call `transcribeInteractiveSamples` over a sliding **tail window** (~10–15 s).
  - **LocalAgreement-2**: maintain `confirmed` (text two consecutive passes agree on) + `volatile` (latest unstable tail). Trim confirmed audio from the buffer so passes stay bounded.
  - Emit updates (`confirmed`, `volatile`) to a callback/stream.
  - Serialize passes; cancel cleanly on stop. Skip a pass if one is in flight (no pile-up).
- Pure-ish and unit-testable: inject a `transcribe(samples:) -> STTResult` closure so tests drive it with canned results (assert LocalAgreement confirm/volatile behavior, trimming, no-pile-up).

### B4. Wire it into the dictation flow
- In `DictationService`, when `shouldAttemptLivePreview` is true and the engine is **Parakeet/Whisper**, start a `RetranscribingPreviewSource` instead of (or alongside) the Nemotron native path; for **Nemotron**, keep the existing native `STTLiveDictating` path untouched.
- Both feed the same overlay preview field. For v1 you may collapse `confirmed+volatile` into the existing single `String` (Part C upgrades the UI to two tiers).
- **Final result is unchanged**: on stop, Parakeet/Whisper still transcribe the full WAV (existing path); the preview source is just torn down. (Document the optional **confirmed-prefix-reuse** fast-final for Whisper as a follow-up — not required for v1.)

### B5. Generalize the gates (capability, not engine)
- `AppEnvironment.swift:276`: `{ AppFeatures.liveDictationStreamingEnabled && SpeechEnginePreference.current().supportsLivePreview }`.
- `STTScheduler.swift:186` / `STTRuntime.swift:165`: the **native** live path stays Nemotron-only (it's the only native engine) — leave those guards, OR if the scheduler also fronts the re-transcriber, gate on `supportsLivePreview`. Keep the reservation re-check / orphan unwind byte-for-byte. (Re-transcription does not need the native live-session reservation; it just uses the interactive slot for short batch passes — confirm it cooperates with the slot scheduler and doesn't fight a meeting job.)

### B6. Diagnostics
- Replace the hardcoded `engine=nemotron` in `DictationService.swift:787` with the actual engine; add a `dictation_preview_pass engine=… ms=…` diagnostic for the re-transcriber.

### B7. Verify
```
swift build && swift test
swift test --filter RetranscribingPreviewSource
swift test --filter DictationService
scripts/dev/run_app.sh   # Parakeet dictate → preview appears; release → correct paste (unchanged latency). Whisper → preview (laggier) + correct paste. Nemotron → unchanged. Kill-switch off → no preview anywhere.
```
Manual matrix: Parakeet preview + ~status-quo paste latency; Whisper preview (slower cadence) + correct paste; Nemotron unchanged; kill-switch off → no preview on any engine; long dictation → buffer trimming keeps passes bounded (no slowdown over time).

**Part B done**: Parakeet + Whisper show a live preview with **no new model download** and **no change to the final/paste path**; Nemotron unchanged; long-dictation passes stay bounded; full `swift test` green.

---

## Part C — Confirmed/volatile two-tone (folds into Part A)

Once B emits `confirmed`+`volatile`, widen the preview field from a single
`String` to `{ confirmed, volatile }` through `DictationService` → snapshot →
overlay VM, and render confirmed bright / volatile dim in the Part A preview
view. Uniform across engines (Nemotron fills `confirmed` only). Cross-layer
signature change — can be its own commit after A+B work.

## Tests
- `RetranscribingPreviewSourceTests` (new, pure): LocalAgreement confirm promotion; volatile tail updates; buffer trimming on confirmation; no pass pile-up; cancel tears down cleanly. Driven by an injected fake transcribe.
- `DictationServiceTests` (extend): with Parakeet/Whisper selected, the **final still comes from the WAV path** (preview teardown doesn't change the result); Nemotron path unchanged.
- Capability + kill-switch unit tests (`supportsLivePreview` truth table; flag-off → gate closure false).
- Part A is view-layer; rely on screenshots + any overlay VM tests.

## Docs to update (after shipping)
- `spec/kernel/requirements.yaml` REQ-STT-002 — the generalization above.
- `CLAUDE.md` "Release Channels" — add the preview feature + `liveDictationStreamingEnabled` to the `main`-vs-release delta until it ships in a tag.
- `Sources/MacParakeetCore/STT/README.md` — the display-only re-transcription preview path + "preview never becomes the paste for Parakeet/Whisper" rule.
- `docs/research/live-dictation-streaming.md` — flip status to implemented; `spec/02-features.md` / `spec/README.md` progress.
- Move plan → `plans/completed/`; update `plans/README.md` + advisor index.

## STOP conditions
- Drift check shows material change to any anchor since `8e62661d1`.
- A re-transcription pass on the interactive slot contends with or stalls meeting work / the final transcription — STOP and reconcile slot scheduling before continuing.
- Any change makes the preview able to become the Parakeet/Whisper paste (it must stay display-only) — STOP.
- Long-dictation passes grow unbounded (buffer not trimmed) causing idle-CPU/latency growth — measure app-frontmost (occluded reads 0% and lies); fix trimming before shipping.

## References
See `docs/research/live-dictation-streaming.md` §9 for the full `file:line`
index. Key seams repeated in "Current state" above.
