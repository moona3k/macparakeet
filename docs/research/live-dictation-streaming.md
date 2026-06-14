# Live Dictation Streaming — Findings, Architecture & Decision

> Status: **DECIDED** (architecture: display-only *ephemeral tail* preview,
> decoupled from the paste; mechanism: single-flight tail-window batch preview
> reusing the existing batch transcriber) / **OPEN** (one number: Whisper
> per-pass latency) / **PROPOSAL** (impl).
> Date: 2026-06-13. Original study base: `origin/main` @ `8e62661d1`.
> Anchors re-verified against `origin/main` @ `2473828f5` after the Nemotron
> streaming merge. Settled after two adversarial code reviews (see §0).
>
> Implementation plan: `plans/active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md`.

## 0. How we got here (two reviews, one settled answer)

The durable decisions never moved: **preview is display-only, decoupled from the
paste; build the plumbing first; one modular seam.** The *mechanism* moved as two
reviews separated two different complexities:

- **Review 1 (skeptic)** found real blockers and, correctly, warned against
  hand-rolling a generic re-transcriber (LocalAgreement + timing-backed audio
  trimming) — that reinvents fiddly, correctness-sensitive logic we'd own.
- **Review 2 (Codex)** then made the key separation: a display-only preview does
  **not** need transcript-correctness machinery at all (no LocalAgreement, no
  confirmed/volatile, no trimming/alignment). It **does** need real, well-defined
  scheduler/API plumbing. So the answer is **the simplest transcript mechanism
  (single-flight tail-window batch) with a rigorously specified preview API and
  single-flight scheduling.**

Two complexities, handled oppositely:

| Complexity | Kind | v1 decision |
|---|---|---|
| Transcript correctness (LocalAgreement, confirmed/volatile, timing-backed trimming, audio↔text alignment) | **owned, fiddly** | **Cut.** Not needed for a display-only preview. |
| Scheduler / sample API / lifecycle (sample-preview API, single-flight, cancel/drain, don't block final or engine-switch) | **well-defined, modular, deterministic** | **Keep and spec explicitly.** This is the necessary complexity. |

Why **not** the vendor `SlidingWindowAsrManager` for Parakeet, despite it being
encapsulated: it's a *long-lived streaming session* (start → stream → updates →
finish) — the same session-shaped lifecycle as Nemotron's native path, which is
what creates the "final `.dictation` rejected while a live session is held"
hazard (`STTScheduler.swift:426`) — plus it's a *second* Parakeet manager, and the
confirmed/volatile quality it provides is something we don't surface. Discrete
**single-flight** passes reusing the one existing manager have fewer lifecycle
hazards and trivial rollback. (It stays a fallback behind the seam if the naive
preview's tail wobble ever actually bothers us.)

Accepted code-cited findings now baked in:
1. **No live frames for Parakeet/Whisper today** — the sample sink is created only on the Nemotron-gated live path (`DictationService.swift:714-789`); `AudioRecorder` mirrors only if it's non-nil (`:536-541`). → decouple a display-preview sink.
2. **No samples-based STT API** — STT is path-based (`STTClientProtocol.swift:17`), scheduler jobs carry `audioPath` (`STTScheduler.swift:23`), runtime Parakeet calls `manager.transcribe(audioURL)` (`STTRuntime.swift:345`). FluidAudio *does* have `[Float]` batch (`AsrManager.swift:482`) and WhisperKit too (`WhisperKit.swift:896`), but MacParakeet doesn't expose it through the scheduler. → add an explicit sample-preview API; **don't improvise** `.dictation` jobs.
3. **Single-flight** — one preview pass in flight at a time; skip timer ticks while one runs; ignore stale results by pass/session ID.
4. **Stop / switch / quiesce ordering** — scheduler rejects an interactive `.dictation` job while a live session exists (`:426`). Preview holds **no** live-session reservation, but it still needs explicit cancellation: on stop, cancel preview → bounded drain → final; on engine switch, cancel preview → bounded drain → switch if drained, or fast `engineBusy` if runtime work is still active; on shutdown/cache-clear, wait for real preview drain under the unhealthy-runtime watchdog before runtime teardown.
5. **Ephemeral, not stable** — earlier words *can* shift (different right-context + sliding left boundary each pass). Render as **ephemeral tail text**; never label it "stable"/"confirmed."
6. **Divergence is expected** — the paste runs through cleanup + optional AI formatting (`DictationService.swift:940-991`) and pre-roll discard trims audio the preview showed (`:505-512`). The preview can legitimately differ from the paste; reset it on pre-roll discard.
7. **Whisper latency** — Whisper pads every pass to a 30s decode; measure before enabling by default.
8. Anchor fixes: WhisperKit `transcribe(audioArray:)` is `:896` (`:547` is `detectLangauge`); FluidAudio pinned 0.15.2 (`Package.resolved`), not ADR-016's 0.13.6.

**Build order (non-negotiable):** prove the vertical slice (decoupled sink +
sample-preview API + single-flight + cancel/drain) with a **fake** transcriber
first. Only then wire the real batch transcribe; only then UI polish.

## 1. The architecture (durable)

The preview is **display-only feedback, never the paste.** The paste comes from
the existing final transcription on stop (Parakeet ~instant). A jumpy/approximate
preview can't corrupt the result, so none of PR #496's streamed-final/degrade
machinery is generalized. The preview is **ephemeral tail text**: it updates and
re-settles as you talk, and it can differ from the final paste — that's expected
and we don't promise otherwise. Users can turn the live transcript preview off
from Settings -> Capture -> Dictation without changing the final dictation path.

All three engines can batch-transcribe raw `[Float]` — FluidAudio
`AsrManager.transcribe` (`:482`), WhisperKit `transcribe(audioArray:)` (`:896`),
Nemotron `manager.process(samples:)` — which is what makes one simple,
engine-agnostic mechanism possible.

## 2. The mechanism: single-flight tail-window batch preview

While recording, accumulate the mic `[Float]`. On a ~1s timer, **if no pass is in
flight**, transcribe the last ~15s window via the engine's existing batch path
and show the text. No windowing/trimming logic of our own (a fixed *time* window
is trivially correct, and any boundary artifact lives in the invisible head — the
pill shows the head-truncated tail). No confirmed/volatile. One manager, reused.

- **Parakeet**: existing `AsrManager` `[Float]` batch. ~15s is its natural
  min-cost pass (passes pad to a 15s window).
- **Whisper**: same shape via `transcribe(audioArray:)`, **gated on the latency
  probe** (30s-padded passes → likely default-off).
- **Nemotron**: keep its shipped native streaming; don't route it through this.

## 3. Hard requirements (the necessary, well-managed complexity)

- **Sample sink** decoupled from the Nemotron native live session; non-nil for Parakeet/Whisper while the paste still comes from the WAV. Frames are already 16 kHz-mono in `AudioRecorder`'s converted path.
- **Sample-preview API**: an explicit scheduler/runtime entry that transcribes a `[Float]` window on the interactive lane **without** a long-lived live-session reservation and without starving the background meeting slot (ADR-016). Specify it; don't improvise.
- **Single-flight**: one pass max; skip ticks while running; discard stale results by pass/session ID.
- **Stop / switch / quiesce**: cancel preview → bounded drain for final/engine-switch paths. Final never queues behind a preview pass; engine switch proceeds when drained or fails fast with `engineBusy` rather than hanging or reloading under active inference. Shutdown/cache-clear wait for drain before unloading or clearing model state.
- **Latency**: measure per engine before default-on (Whisper especially).

## 4. Latency model

Parakeet already does batch-final today, so display-only preview is purely
additive — no paste-latency regression. Post-release wait: Parakeet ~100–250 ms
(measure; passes pad to 15s), Nemotron ~0 (native, kept), Whisper ~1–3 s (slow
regardless; probe it). No streamed-final reuse in v1 — final stays full-WAV.

## 5. Whisper

Feasible via the same single-flight batch path (`transcribe(audioArray:)`), no
fork, no `AudioStreamTranscriber` needed. The real constraint is architecture: a
30s-padded decode per pass → multi-second cadence. So **probe first** (time one
pass on a ~15s clip, cold+warm); default-on only if it clears. Worth getting
right — it's the only engine for Korean/Japanese/Chinese/+95 langs (zero live
feedback today).

## 6. Considered and not chosen (reference)

| Option | Why not (v1) |
|---|---|
| FluidAudio `SlidingWindowAsrManager` (Parakeet) | Long-lived session lifecycle (the F7 hazard shape) + a second manager; its confirmed/volatile/token-timings are unused by a display-only preview. Fallback only. |
| Generic re-transcriber + LocalAgreement + timing-backed trimming | Owned, fiddly, correctness-sensitive (review 1's blocker). Unneeded for display-only. |
| WhisperKit `AudioStreamTranscriber` | Same session-shaped lifecycle + a passthrough `AudioProcessing` adapter; the plain `transcribe(audioArray:)` batch path is simpler. |
| `StreamingEouAsrManager` (`parakeet_realtime_eou_120m`) | Separate model download; revisit only for EOU auto-stop. |

## 7. Nemotron baseline (keep)

PR **#496** (merged 2026-06-12, unreleased; latest tag v0.6.22). Nemotron-only
native streaming; the streamed final *is* its paste with guarded WAV fallback
(`DictationService.swift:898-923`). Kept as-is alongside the new path.

## 8. UI

Lift the preview **out of the capsule** (it currently sits inside `pillContent`,
which the `Capsule` wraps — `DictationOverlayView.swift:323-340,427,509`), and
render it as a sibling **above** the pill in the bottom-aligned `body` VStack
(`:232,:252`), growing upward into the ~100 pt of headroom; pill geometry
untouched. **Single-style ephemeral tail text** (no two-tone). Panel: fixed
`300×160` `ClickablePanel` (`DictationOverlayController.swift`).

## 9. GUI QA hook

Debug builds can show the real overlay surface without microphone/STT setup:

```bash
scripts/dev/run_app.sh
APP_BUNDLE=".build/xcode-dev/Build/Products/Debug/MacParakeet-Dev.app"
pkill -f "MacParakeet-Dev.app/Contents/MacOS/MacParakeet" || true
open -na "$APP_BUNDLE" --args \
  --qa-dictation-preview-overlay \
  --qa-dictation-preview-text "Drafting the launch notes now. The live preview updates while final dictation is still streaming in."
```

The hook is `#if DEBUG`-only and presents `DictationOverlayController` with a
fixture `DictationOverlayViewModel`, so screenshots exercise the same SwiftUI
preview panel and pill layout as the app.

## 10. References (file:line)

- `STTScheduler.swift:23,426-428` — jobs carry `audioPath`; interactive rejected during live session
- `STTRuntime.swift:345` — Parakeet `manager.transcribe(audioURL)` (path-based)
- `STTClientProtocol.swift:17` — path-based `STTTranscribing`
- `DictationService.swift:505-512,714-789,898-923,940-991` — pre-roll discard; Nemotron-gated sink; final/fallback; cleanup+formatting
- `AudioRecorder.swift:536-541` — sample mirror gated on non-nil sink
- `AppEnvironment.swift:276-281` — Nemotron-only native-live gate
- `DictationOverlayView.swift:232-344,427,509` — body/capsule/preview
- `AppFeatures.swift:53` — flag precedent
- FluidAudio `AsrManager.swift:482` `[Float]` batch; WhisperKit `WhisperKit.swift:896` `transcribe(audioArray:)`
