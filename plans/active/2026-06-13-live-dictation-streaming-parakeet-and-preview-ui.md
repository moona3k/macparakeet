# Plan: Live dictation streaming — preview-above-pill UI revamp + Parakeet sliding-window streaming

> **Executor instructions**: Follow this plan phase by phase. Run every
> verification command and confirm the expected result before moving on. Part A
> (UI) and Part B (Parakeet) are independently shippable — Part A can merge
> alone. If anything in "STOP conditions" occurs, stop and report — do not
> improvise. When done, update this plan's row in `plans/README.md` and
> `plans/active/2026-06-12-advisor-index.md`.
>
> **Background reading (read first)**: `docs/research/live-dictation-streaming.md`
> is the feasibility study this plan executes. `spec/adr/016-...`,
> `spec/adr/021-whisperkit-multilingual-stt.md`, and
> `Sources/MacParakeetCore/STT/README.md` are the governing constraints.
>
> **Drift check (run first)**:
> `git diff --stat 4e2303d4b..HEAD -- Sources/MacParakeetCore/STT/STTScheduler.swift Sources/MacParakeetCore/STT/STTRuntime.swift Sources/MacParakeetCore/STT/NemotronEngine.swift Sources/MacParakeetCore/STT/STTClientProtocol.swift Sources/MacParakeet/App/AppEnvironment.swift Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
> If any changed since `4e2303d4b`, re-read the "Current state" excerpts against
> live code before proceeding; on a material mismatch treat it as a STOP.
> Also confirm FluidAudio still exposes `SlidingWindowAsrManager` /
> `SlidingWindowAsrSession` (it ships in the pinned checkout today).

## Status

- **Priority**: P2 (UX upgrade + capability extension; not a correctness fix)
- **Effort**: Part A = S/M (SwiftUI restructure). Part B = L (new engine + runtime/scheduler routing). Part C = M (optional).
- **Risk**: Part A LOW (view-only). Part B MEDIUM (touches the interactive STT slot; mitigated by the unchanged WAV-fallback invariant + kill-switch).
- **Depends on**: none. Builds on PR #496 (Nemotron live dictation, on `main`, unreleased).
- **Category**: feature (UI + STT engine)
- **Planned at**: commit `4e2303d4b`, 2026-06-13
- **Requirement**: amends **REQ-STT-002** (today: "Nemotron dictation streams live partial text…"). Generalize to "streaming-capable engines (Nemotron, Parakeet via sliding window)…"; the streamed-final/WAV-fallback invariant is unchanged.

## Why this matters

The live transcript preview (PR #496) is a real perceived-speed win — the
streamed text *becomes* the paste, so there's no post-release transcription
pause — but it ships with two limits worth removing:

1. **The preview deforms the floating pill.** It renders *inside* the capsule,
   so the capsule stretches into a tall card (see the screenshots in the
   research doc). The pill is a brand surface (sacred-geometry family); it
   should keep its shape, with the preview floating above it.
2. **It's Nemotron-only.** Nemotron is opt-in **Beta**. Parakeet is the
   **default** engine, and FluidAudio can stream the *exact Parakeet TDT model
   we already load* via `SlidingWindowAsrManager` — **no new download**, plus
   richer data (confirmed/volatile transcript, word timings, live vocab
   boosting). Extending streaming to Parakeet brings the preview to the default
   path. (Whisper is **out** — its only streaming API grabs the mic and is
   multi-second-latency; see research doc §4.)

## Scope

**In scope**
- Part A: move the preview out of the capsule to a floating element above the pill; pill geometry untouched.
- Part B: a `ParakeetStreamingEngine` (sliding window over existing `AsrModels`); generalize the Nemotron-only gates to a per-engine capability; add an `AppFeatures` kill-switch.
- Part C (optional/recommended follow-up): confirmed/volatile two-tone rendering, which requires widening the partial callback beyond a single `String`.

**Out of scope / invariants (MUST NOT change)**
- The **result/degrade invariant**: a healthy live final is the result; every degrade path (drop, empty final, pre-roll discard, lifecycle race) falls back to WAV transcription. Do not weaken this for either engine (`DictationService.swift:856-878,898-923`).
- Whisper stays batch-only.
- ADR-016 slot model: live dictation owns the **interactive** slot; meeting work stays on the background slot.
- The scheduler's post-`begin` reservation re-check and orphan-unwind (`STTScheduler.swift:195-205`).
- No change to engine *switching* guards while speech work / a meeting lease is active (ADR-021).

## Current state (anchors — verify in drift check)

**Gates that are Nemotron-specific (the seams to widen):**
- `Sources/MacParakeet/App/AppEnvironment.swift:276` — `shouldAttemptLiveDictationTranscription: { SpeechEnginePreference.current() == .nemotron }`
- `Sources/MacParakeetCore/STT/STTScheduler.swift:186` — `guard selection.engine == .nemotron else { throw …unsupportedEngine }`
- `Sources/MacParakeetCore/STT/STTRuntime.swift:165` — `guard speechEngine == .nemotron …`; and `appendLiveDictationSamples`/`finishLiveDictationTranscription`/`cancel` **hardcode `nemotronEngine`** (`:188`, `:165`+ following methods).

**Engine + protocol shapes:**
- `Sources/MacParakeetCore/SpeechEnginePreference.swift:3-6` — `enum SpeechEnginePreference { case parakeet, nemotron, whisper }`.
- `Sources/MacParakeetCore/STT/STTClientProtocol.swift:42-52` — app-facing `STTLiveDictationTranscribing` (`beginLiveDictationTranscription(onPartial: (String)->Void)`, `appendLiveDictationSamples([Float], sessionID:)`, `finishLiveDictationTranscription(sessionID:)->STTResult`, `cancelLiveDictationTranscription(sessionID:)`). Error enum at `:25-40` (`unsupportedEngine`, `sessionNotActive`, `modelNotReady`).
- `Sources/MacParakeetCore/STT/NemotronEngine.swift:86-166` — the **engine-level** live methods (`beginLiveDictation(language:onPartial:)`, `processLiveDictationSamples([Float])`, `finishLiveDictation()->STTResult`, `cancelLiveDictation()`). This is the de-facto interface `ParakeetStreamingEngine` must match.
- `Sources/MacParakeetCore/STT/STTRuntime.swift:67-69` — `interactiveManager/backgroundManager: AsrManager?`, `models: AsrModels?` (Parakeet batch; **already loaded** — reuse for streaming).

**FluidAudio (pinned checkout):**
- `…/ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift` — `loadModels(_ models: AsrModels)` (`:140`), `streamAudio(_ buffer: AVAudioPCMBuffer)` (`:212`), `transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>` (`:217`), `finish()->String` (`:231`), `reset/cleanup/cancel`, `configureVocabularyBoosting` (`:86`). Update struct `:803` (`text`, `isConfirmed`, `confidence`, `tokenTimings`). Config `:678`.
- `…/SlidingWindow/SlidingWindowAsrSession.swift:26` — `AsrModels.downloadAndLoad()` (same model family as our batch path).

**UI (the deformation):**
- `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift`:
  - `liveTranscriptPreview` (`:441-453`) + `liveTranscriptPreviewText(width:)` (`:455-467`).
  - Embedded **inside** the capsule: a row in `holdToTalkContent` VStack (`:427`) and `recordingContent` VStack (`:509`).
  - Capsule background wraps `pillContent` (`:323-340`).
  - Root `body` VStack is **bottom-aligned** (`:252`), with the hover tooltip already living above the pill (`:234`). ~100 pt of headroom exists above the pill.
- `Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift` — fixed `300×160` `ClickablePanel`, bottom-center; `updateSize(width:)` re-centers horizontally, height fixed.
- Data flow: `DictationFlowCoordinator.swift:1104` polls `snapshot.liveTranscript` → `overlayViewModel.liveTranscript` (single `String`); reset at `:445,:454`.

---

## Part A — Preview above the pill (ship-on-its-own)

Goal: pill keeps its exact capsule shape; the preview floats above it. Engine-agnostic (single `String`, works for Nemotron today and Parakeet later). No data-flow change.

### A1. Lift the preview out of the capsule
- In `DictationOverlayView.swift`, **remove** `liveTranscriptPreviewText(...)` from `holdToTalkContent` (`:427`) and `recordingContent` (`:509`); revert each to just its `HStack` (so `pillContent` — and thus the `Capsule` — returns to the compact one-row shape).
- Add a new floating preview view as a **sibling above** `overlayContent` in the `body` VStack (`:232`), placed after the tooltip slot. Gate it on `viewModel.state == .recording && liveTranscriptPreview != nil`. Because the stack is bottom-aligned, it grows **upward** into the headroom; the pill stays pinned.
- Keep the existing tail-normalization (`:446-453`) and `.transition(.opacity…)`.

### A2. Style the floating caption
- Reuse atoms (DesignSystem colors/opacities, 0.16s ease timing) but let the **shape differ** from the pill (the "siblings not twins" UI principle). Options: bare 2-line text, or its own subtle translucent rounded background distinct from the capsule. Keep width ≤ pill width; center-align under the pill.
- Confirm it does not intercept hover/clicks (the panel's single `NSTrackingArea` covers the whole panel; the preview is display-only — no buttons).

### A3. Panel headroom
- Verify 1–2 lines render fully within the current `300×160` panel above the pill. If 2 lines clip, bump panel height in `DictationOverlayController` (e.g. 160→190) keeping the bottom anchor and re-centering on show; **do not** change width logic. Document the new constant inline.

### A4. Verify (Part A)
```
scripts/dev/run_app.sh        # select Nemotron, dictate; confirm pill keeps shape, preview floats above
swift build --target MacParakeet
swift test --filter DictationOverlay   # if any view-model-level coverage exists; else rely on manual
```
Expected: capsule identical to its non-preview shape at all times; preview text appears above, grows upward, never widens/stretches the capsule; idle pill (separate panel) unaffected.

**Part A done criteria**: screenshots before/after show the capsule unchanged; no regression in `swift test`; ship as its own PR if desired.

---

## Part B — Parakeet sliding-window streaming (Path A)

Goal: Parakeet (default engine) streams live partials by sliding-window over the **already-loaded** `AsrModels` — no new download. Generalize the Nemotron-only gates to a capability; gate the whole feature behind a new kill-switch.

### B1. Engine capability + kill-switch
- `SpeechEnginePreference` (`SpeechEnginePreference.swift`): add
  ```swift
  public var supportsLiveDictation: Bool {
      switch self { case .parakeet, .nemotron: return true; case .whisper: return false }
  }
  ```
- `AppFeatures.swift`: add `public static let liveDictationStreamingEnabled: Bool = true` with a doc comment mirroring `meetingVadLiveChunkingEnabled` (`:53`). This is the single off-switch for the whole live-dictation feature (both engines).

### B2. Extract an engine-level live protocol
- In `STTClientProtocol.swift`, add an **internal engine-facing** protocol (distinct from the app-facing `STTLiveDictationTranscribing`), matching what `NemotronEngine` already implements:
  ```swift
  protocol STTLiveDictating: Actor {
      func beginLiveDictation(language: String?, onPartial: @escaping @Sendable (String) -> Void) async throws
      func processLiveDictationSamples(_ samples: [Float]) async throws
      func finishLiveDictation() async throws -> STTResult
      func cancelLiveDictation() async
  }
  ```
- Conform `NemotronEngine` to it (it already has the methods; just declare conformance — `NemotronEngine.swift:5`).

### B3. `ParakeetStreamingEngine`
- New `Sources/MacParakeetCore/STT/ParakeetStreamingEngine.swift`, an `actor` conforming to `STTLiveDictating`. Mirror `NemotronEngine`'s lane/guard discipline (`activeLanes`, generation/`sessionNotActive` guards).
- Construct/hold a `SlidingWindowAsrManager`. **Load from the runtime's already-loaded `AsrModels`** via `loadModels(_ models:)` — the engine takes `AsrModels` at init or via a `prepare(models:)` call; do **not** call `AsrModels.downloadAndLoad()` again. Pick the lower-latency streaming config preset (left=2s/right=2s) and document the choice.
- `beginLiveDictation`: `reset()`, optionally `configureVocabularyBoosting(...)` from the user's custom vocabulary (nice-to-have; can defer), then start consuming `transcriptionUpdates`:
  - For each `SlidingWindowTranscriptionUpdate`, compute the **collapsed string** = `confirmedTranscript + volatileTranscript` (manager exposes both; or accumulate from updates) and call `onPartial(collapsed)`. (Two-tone is Part C.)
  - Serialize like Nemotron — the consumer task owns the stream; finish it on every finish/cancel path.
- `processLiveDictationSamples([Float])`: wrap `[Float]` → `AVAudioPCMBuffer` (16 kHz mono; `streamAudio` re-converts but expects a buffer) and call `streamAudio(_:)`.
- `finishLiveDictation()`: `finish()` → `String`; return `STTResult(text:, words: <map tokenTimings if available else []>, language:, engine: .parakeet, engineVariant: <v3/v2>)`. **Word timings are available from sliding-window** — map them if cheap; else `[]` is acceptable for v1.
- `cancelLiveDictation()`: `cancel()`/`reset()`, finish the updates stream, release the lane (mirror `NemotronEngine.swift:154-166`).

### B4. Runtime routing (the hardcoded-`nemotronEngine` fix)
- `STTRuntime.swift`: add `private var activeLiveEngine: (any STTLiveDictating)?` and a lazily-prepared `parakeetStreamingEngine: ParakeetStreamingEngine?`.
- `beginLiveDictationTranscription` (`:157`): replace `guard speechEngine == .nemotron` with `guard speechEngine.supportsLiveDictation`. Then:
  ```
  switch speechEngine {
  case .nemotron: engine = nemotronEngine (ensure ready)
  case .parakeet: engine = parakeet streaming engine, prepared from self.models (ensure models loaded — they are, for the interactive slot)
  case .whisper:  unreachable (guarded) — throw unsupportedEngine
  }
  activeLiveEngine = engine
  ```
- `appendLiveDictationSamples`/`finishLiveDictationTranscription`/`cancelLiveDictationTranscription`: route through `activeLiveEngine` instead of `nemotronEngine` directly; clear `activeLiveEngine` on finish/cancel. Preserve the `liveDictationSession == .active(sessionID)` guards exactly.
- **Models availability**: Parakeet streaming needs `self.models` loaded. The interactive slot already loads `AsrModels` for batch dictation; ensure the streaming engine reuses that instance (no second load). If models aren't loaded yet at `begin`, prepare them (same path batch dictation uses) — and if that fails, throw so the caller falls back to WAV.

### B5. Scheduler gate
- `STTScheduler.swift:186`: replace `guard selection.engine == .nemotron` with `guard selection.engine.supportsLiveDictation`. Keep everything else (reservation, post-begin re-check, orphan unwind) byte-for-byte.

### B6. App gate
- `AppEnvironment.swift:276`: change to
  `shouldAttemptLiveDictationTranscription: { AppFeatures.liveDictationStreamingEnabled && SpeechEnginePreference.current().supportsLiveDictation }`.

### B7. Diagnostics
- `DictationService.swift:787`: replace the hardcoded `engine=nemotron` with the actual engine (thread it from the runtime selection, or log `engine=\(selection)`).

### B8. Verify (Part B)
```
swift build
swift test
swift test --filter STTScheduler
swift test --filter DictationService
swift run macparakeet-cli health
scripts/dev/run_app.sh   # select Parakeet, dictate: live preview appears; release → pasted text matches; switch to Nemotron: still works
```
Manual matrix: Parakeet healthy stream (preview + correct paste), Parakeet degrade (kill network mid-stream? force drop) → WAV fallback still pastes, Nemotron unchanged, Whisper shows **no** preview and pastes via batch (unchanged), kill-switch off → no preview on any engine.

**Part B done criteria**: Parakeet live preview works end-to-end with no new model download (verify FluidAudio cache unchanged); the WAV-fallback invariant holds under each degrade path; Nemotron/Whisper behavior unchanged; full `swift test` green.

---

## Part C — Confirmed/volatile two-tone (optional, recommended follow-up)

Only after A+B. Sliding-window distinguishes `isConfirmed`; render confirmed bright, volatile dim/italic so users see text settling (reads higher-quality than whole-line rewrites).

- Widen the partial callback from `(String) -> Void` to a small `LiveDictationPartial { confirmed: String; volatile: String }` through: engine `onPartial`, `STTLiveDictating`, app-facing `STTLiveDictationTranscribing.beginLiveDictationTranscription`, `DictationService.updateLiveTranscript`, the snapshot, and `overlayViewModel.liveTranscript` (→ a two-field type).
- Nemotron fills `confirmed` only (it has no volatile distinction); UI renders identically to today for Nemotron.
- Update the Part A preview view to render the two tones.
- This is a cross-layer signature change — keep it a **separate PR** so A+B can ship first.

---

## Tests

- `ParakeetStreamingEngineTests` (new): begin→append→finish returns non-empty `STTResult` with `engine == .parakeet` (mock or fixture `AsrModels` if feasible; otherwise gate behind a model-available check like existing STT integration tests). Cancel releases the lane. Empty final → caller falls back (assert at `DictationService` level).
- `DictationServiceTests` (extend): the existing WAV-fallback assertions must pass with `engine == .parakeet` as the live engine (drop/empty/preroll-discard → WAV). Reuse the `MockSTTClient` live-dictation seam.
- `STTSchedulerTests` (extend): `supportsLiveDictation == false` (Whisper) → `unsupportedEngine`; Parakeet/Nemotron accepted; the begin-vs-shutdown race test still passes.
- Capability unit test: `SpeechEnginePreference.supportsLiveDictation` truth table.
- Kill-switch: `AppFeatures.liveDictationStreamingEnabled == false` → `shouldAttemptLiveDictationTranscription` closure returns false for all engines (test the closure or its inputs).
- Part A is view-layer; rely on manual screenshots + any existing overlay VM tests.

## Docs to update (after shipping)

- `spec/kernel/requirements.yaml` REQ-STT-002: generalize "Nemotron dictation streams…" → "streaming-capable engines (Nemotron, Parakeet via sliding window) stream live partials…"; note Whisper excluded.
- `CLAUDE.md` "Release Channels": the live-dictation streaming feature (and the new flag) belongs in the `main`-vs-release delta until it ships in a tag — currently that block only lists `aiFormatterProfilesEnabled`. Also note the new `AppFeatures.liveDictationStreamingEnabled`.
- `Sources/MacParakeetCore/STT/README.md`: add the Parakeet sliding-window streaming path + the "live owns the interactive slot, reuses loaded `AsrModels`" rule.
- `spec/02-features.md` / `spec/README.md`: progress markers.
- `docs/research/live-dictation-streaming.md`: flip §7 decisions to "decided: Part A + Path A".
- Move this plan to `plans/completed/` and update `plans/README.md` + advisor index.

## STOP conditions

- Drift check shows material change to any anchor since `4e2303d4b`.
- FluidAudio pinned checkout no longer exposes `SlidingWindowAsrManager`/`SlidingWindowAsrSession` (API moved/renamed) — re-research before coding.
- Parakeet streaming requires a *new* model download (it must reuse `AsrModels`) — if `loadModels(_ models:)` can't take our instance, STOP and reconsider (the no-download property is a core premise).
- Any degrade path stops falling back to WAV (the result invariant) — STOP; that's a release-blocker.
- Idle-CPU regression from continuous sliding-window decoding during dictation that materially exceeds Nemotron's — measure app-frontmost (occluded reads 0% and lies); if pathological, gate or revisit config.

## References

See `docs/research/live-dictation-streaming.md` §8 for the full `file:line`
index (app side, FluidAudio, WhisperKit). Key seams repeated above.
