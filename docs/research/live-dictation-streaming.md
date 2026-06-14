# Live Dictation Streaming — Findings, Architecture & Decision

> Status: **DECIDED** (architecture) / **PROPOSAL** (implementation). No code yet.
> Date: 2026-06-13. Author: research pass over `origin/main` @ `8e62661d1`.
> Scope: the live transcript preview added for Nemotron (PR #496), and the
> decision on how to (a) revamp its UI and (b) extend it to **all three**
> engines (Parakeet, Nemotron, Whisper).
>
> Implementation plan: `plans/active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md`.

## TL;DR — what we decided

**The live preview is a display-only feedback surface, never the source of
truth. The pasted result still comes from each engine's existing final path.**
That one reframe makes the preview engine-agnostic and removes all correctness
risk, which is why the chosen design is:

| Piece | Decision |
|-------|----------|
| **Mechanism** | **One generic re-transcription preview** shared by all batch engines — periodically re-transcribe a sliding tail window via the engine's *existing* `[Float]` batch transcribe, split confirmed vs. volatile text with **LocalAgreement-2**. (Nemotron keeps its already-shipped native streaming.) |
| **Parakeet** (default) | ✅ Preview via the generic re-transcriber. ~100–250 ms/pass (155× realtime) — trivial. **Not** the FluidAudio sliding-window path (rejected: a 3rd bespoke mechanism that doesn't help Whisper). |
| **Nemotron** (Beta) | ✅ Keep its native streaming (PR #496) as-is — shipped, tested, gives a free instant-final. Don't regress working code. |
| **Whisper** | ✅ **In** (reversing the earlier "not viable"). Same generic re-transcriber. Latency is inherently higher (slow engine), but it's the *only* engine for Korean/Japanese/Chinese/+95 langs, who today get zero live feedback. |
| **Final result** | Unchanged per engine. Parakeet/Whisper → existing full-WAV batch (Parakeet ~instant). Nemotron → its streamed final. Display-only preview can't corrupt it. |
| **UI** | Lift the preview **out of the capsule** so the pill keeps its shape; render confirmed bright / volatile dim. Two-tone now works **uniformly** across all engines (it comes from LocalAgreement, not a vendor feature). |
| **Gating** | A `supportsLivePreview` capability (**true for all three**) ANDed with a new `AppFeatures.liveDictationStreamingEnabled` kill-switch. |

Rejected alternative: best-in-class vendor streaming per engine (Nemotron
native + Parakeet `SlidingWindowAsrManager` + Whisper `AudioStreamTranscriber`).
More per-engine polish, but ~3× the integration surface and three different
APIs to maintain. The product's "simplicity is the product" North Star and the
display-only reframe favor one generic mechanism.

---

## 1. The reframe: preview ≠ result

The preview answers "is the app hearing me, and roughly what did it get?" — a
*feedback* surface. The paste comes from the final transcription on stop, which
is proven. Accepting **"display-only, never the result"** dissolves three
problems at once:

1. **No correctness risk.** A jumpy/wrong preview can't corrupt the paste. The
   entire PR #496 degrade/fallback machinery (streamed-final-becomes-result,
   drop detection, empty-final fallback) exists *only* because Nemotron's
   preview **is** its result; it does **not** need to be generalized to other
   engines.
2. **Engine-agnostic.** Any mechanism that yields approximate live text works.
   Native streaming becomes an *optimization*, not a *requirement*.
3. **Whisper stops being special.** All three engines can batch-transcribe a
   raw `[Float]` array (verified: FluidAudio `AsrManager.transcribe(...)`,
   WhisperKit `transcribe(audioArray:)` `WhisperKit.swift:547`, Nemotron
   `manager.process(samples:)`). So all three can preview.

## 2. The two mechanisms (first principles)

- **Native streaming** (Nemotron; also FluidAudio sliding-window / WhisperKit
  `AudioStreamTranscriber` if we used them): engine keeps internal state, emits
  incremental hypotheses as samples arrive. Lowest latency, but per-engine and
  bespoke.
- **Periodic re-transcription** (engine-agnostic): accumulate samples,
  periodically run the engine's *batch* transcribe over a sliding tail window,
  diff results to confirm stable text. Higher latency, more re-encode compute,
  but **one mechanism for every batch engine, present and future**.

We pick **periodic re-transcription** as the strategic go-forward path, and
keep Nemotron's already-shipped native streaming as sunk cost. Two mechanisms
total; the generic one is the one we extend.

## 3. The generic re-transcription preview (the build)

A single `RetranscribingPreviewSource`:
- Holds a rolling `[Float]` buffer (we already have these frames from
  `SharedMicrophoneStream`; the live sink already feeds `[Float]`).
- Every ~700 ms–1 s (or "when the previous pass finishes," whichever is slower
  — this self-throttles slow engines), re-transcribes a sliding **tail window**
  (~10–15 s) via the engine's existing sample batch transcribe.
- **LocalAgreement-2**: text two consecutive passes agree on is **confirmed**
  (render solid); the newest unstable tail is **volatile** (render dim). Trim
  confirmed audio out of the buffer so passes stay cheap and bounded.

This is the same windowing+confirmation that FluidAudio's sliding-window and
WhisperKit's `AudioStreamTranscriber` each implement internally — built once,
generically, reusing the batch path we already trust. ~a few hundred lines +
tests, shared across all engines.

## 4. Latency model — does display-only cost us?

**No meaningful cost on the default path.** Parakeet has no native streaming, so
**today's Parakeet dictation already does batch-final** (record → release →
transcribe WAV → paste) — the experience users already call "fast." Display-only
preview keeps that final path identical and only *adds* a preview. Purely
additive, zero regression.

Post-release wait (release → paste):

| Engine | Final = | Wait | Note |
|---|---|---|---|
| **Parakeet** | full-WAV batch (155× realtime) | ~100–250 ms typical | **same as today**; below the clipboard/paste/AI-formatter floor |
| **Nemotron** | its streamed final (kept) | ~0 | unchanged |
| **Whisper** | batch | ~1–3 s | slow regardless; no streamed-final exists for Whisper |

**Self-optimizing where it matters.** "Display-only" is the safe *default*, but
the final on stop need not be a *cold* pass:
- **Cold full-WAV final** — simplest; right for Parakeet (already fast).
- **Confirmed-prefix-reuse** — keep the LocalAgreement-*confirmed* prefix and
  only finalize the short volatile tail on release → near-zero post-release
  wait. Safe because confirmed = two passes already agreed; falls back to a cold
  full-WAV pass if the session looks degraded (same invariant). This is the
  documented **fast-final option for slow engines (Whisper)**, so Whisper's
  final reuses work already done during preview instead of paying transcription
  time twice.

So: Parakeet stays simple and already-fast; Nemotron unchanged; Whisper (the
only slow engine) actually *benefits*.

## 5. Whisper specifics (correcting the earlier "not viable")

Earlier framing called Whisper streaming "not viable / would need a fork." That
was wrong. Two feasible routes:
- **(chosen) Generic re-transcriber** over `WhisperKit.transcribe(audioArray:)`
  — no WhisperKit streaming API needed at all; same component as Parakeet.
- (alternative) WhisperKit's own `AudioStreamTranscriber` — it takes
  `audioProcessor: any AudioProcessing`, and `AudioProcessing` is a **public
  protocol** (`AudioProcessor.swift:52`). A passthrough conformer whose
  `startRecordingLive` is a no-op and whose `audioSamples` we fill from
  `SharedMicrophoneStream` reuses WhisperKit's built-in confirmation logic — no
  fork. We don't need this if we use the generic re-transcriber.

The real Whisper constraint is **architecture, not feasibility**: it's a 30 s
encoder-decoder, so partials are window-bound (multi-second) and re-encode is
heavier. That's inherent to Whisper and identical under any approach — which is
exactly why the generic re-transcriber (which it shares with Parakeet) is the
right home for it.

## 6. Reference — vendor streaming landscape (the path we did *not* take)

Kept for context; these are the bespoke per-engine alternatives we rejected in
favor of one generic mechanism.

| Manager (FluidAudio) | Model | Notes |
|---|---|---|
| `AsrManager` | Parakeet TDT 0.6B v3/v2 (`AsrModels`) | **Batch** — what we re-transcribe against. Same loaded model we already use. |
| `StreamingNemotronMultilingualAsrManager` | Nemotron 3.5 (`nemotron-multilingual-1120ms`) | Native streaming; `NemotronEngine` uses it. Partial cadence ~1.1 s; no word timings. |
| `SlidingWindowAsrManager` | Parakeet TDT (same `AsrModels`) | Native sliding-window streaming over the existing model (no new download); confirmed/volatile + word timings + vocab boosting. **Rejected** as a 3rd bespoke mechanism; the generic re-transcriber covers Parakeet without it. |
| `StreamingEouAsrManager` | `parakeet_realtime_eou_120m-v1` (separate model) | Realtime + end-of-utterance. Extra download; revisit only if we want EOU-driven auto-stop. |

WhisperKit (`argmax-oss-swift`): `AudioStreamTranscriber` + the public
`AudioProcessing` protocol (see §5).

## 7. What shipped already (Nemotron baseline — keep)

PR **#496** (merged 2026-06-12, **unreleased**; latest tag v0.6.22). Nemotron-only,
gated at `AppEnvironment.swift:276` and `STTScheduler.swift:186`; no `AppFeatures`
flag. The streamed final *is* the paste, with a guarded fallback to WAV on every
degrade path (`DictationService.swift:856-923`). `NemotronEngine.swift:86-166`
is the engine-level live shape. We keep all of this; the new work sits alongside it.

## 8. UI revamp — preview above the pill

The preview currently renders *inside* `pillContent`, which the `Capsule`
background wraps (`DictationOverlayView.swift:323-340,427,509`), so the capsule
stretches into a card. Fix: remove it from the capsule and render it as a
sibling **above** the pill in the bottom-aligned `body` VStack (`:232,:252`) —
it grows upward into the ~100 pt of existing headroom (where the tooltip already
lives), pill geometry untouched. Panel is a fixed `300×160` `ClickablePanel`
(`DictationOverlayController.swift`). Render confirmed bright / volatile dim —
now uniform across all engines because confirmation comes from LocalAgreement.

## 9. References (file:line)

- `Sources/MacParakeet/App/AppEnvironment.swift:276` — current Nemotron-only gate
- `Sources/MacParakeetCore/STT/STTScheduler.swift:167-205` — scheduler live methods + reservation re-check
- `Sources/MacParakeetCore/STT/STTRuntime.swift:67-69,157-200` — batch `AsrManager`/`AsrModels`; live routing (currently hardcodes `nemotronEngine`)
- `Sources/MacParakeetCore/STT/NemotronEngine.swift:86-166` — native live engine (template, kept)
- `Sources/MacParakeetCore/STT/STTClientProtocol.swift:42-52` — `STTLiveDictationTranscribing`; `:17` `STTTranscribing` (batch)
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift:375-409,856-923` — stop flow; final/fallback (display-only keeps this)
- `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift:232-344,427,441-467,509` — body/capsule/preview
- `Sources/MacParakeetCore/AppFeatures.swift:53` — `meetingVadLiveChunkingEnabled` (flag precedent)
- FluidAudio `AsrManager.transcribe(...)` (samples), `SlidingWindowAsrManager`, `StreamingEouAsrManager` — see §6
- WhisperKit `WhisperKit.swift:547` `transcribe(audioArray:)`; `AudioProcessor.swift:52` `AudioProcessing` protocol
