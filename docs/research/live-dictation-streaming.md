# Live Dictation Streaming — Findings & Feasibility

> Status: **PROPOSAL** — research + feasibility, no code committed yet.
> Date: 2026-06-13. Author: research pass over `origin/main` @ `4e2303d4b`.
> Scope: the live transcript preview added for Nemotron (PR #496), and whether
> to (a) revamp its UI and (b) extend it to the Parakeet and Whisper engines.

## TL;DR

| Question | Verdict |
|----------|---------|
| Is the Nemotron live preview good enough to keep / build on? | **Yes.** It's a real latency win (the streamed final *becomes* the pasted text; WAV is a safety net), well-guarded, and Beta is acceptable per owner. |
| Can **Parakeet** stream live partials? | **Yes — feasible and recommended.** FluidAudio's `SlidingWindowAsrManager` streams the **same Parakeet TDT models we already load** — *no new model download*. Bonus: it exposes a confirmed/volatile two-tier transcript, word-level timings, and real-time vocabulary boosting. |
| Can **Whisper** stream live partials? | **No — not viable** under our constraints. WhisperKit's only streaming path owns the microphone, can't take our samples, and emits partials only at multi-second (≥30 s window) cadence. Keep Whisper batch-only. |
| UI revamp | **Lift the preview out of the capsule.** It currently renders *inside* `pillContent`, so the capsule stretches to wrap it and deforms. Render it as a sibling **above** the pill in the panel's existing headroom; the pill geometry stays untouched. |

---

## 1. What shipped: Nemotron live dictation (the baseline)

PR **#496** ("Fix Nemotron live dictation streaming", merged 2026-06-12, **not in any release tag yet** — latest ship is v0.6.22, 2026-06-09). It is **Nemotron-only**, gated twice:

- `AppEnvironment.swift:276` — `shouldAttemptLiveDictationTranscription: { SpeechEnginePreference.current() == .nemotron }`
- `STTScheduler.swift:186` — even past that gate, the scheduler re-checks `selection.engine == .nemotron` and throws `unsupportedEngine` otherwise.

**There is no `AppFeatures` kill-switch** — it is unconditionally on whenever Nemotron is selected. (Compare VAD live chunking, which *is* flag-gated: `AppFeatures.meetingVadLiveChunkingEnabled`.) Blast radius is contained because Nemotron is itself opt-in Beta.

### Result path (the important part)

The overlay text is **not just cosmetic**. When the live session is healthy, the streamed final **becomes the pasted result** — the WAV is *not* re-transcribed:

- `DictationService.stopRecording` → `finishLiveDictationTranscription` returns the live `STTResult?` (`DictationService.swift:401`).
- `processCapturedAudio`: if a live result is present it's used directly (`:916`); otherwise the WAV is transcribed (`:921-922`).

The core invariant — **live streaming can never make dictation worse than the proven WAV path** — is enforced at every degrade path, all of which return `nil` and fall back to WAV:
- backpressure drop (>120-chunk ANE backlog) → degrade (`:791`)
- empty live final → WAV, so a real-speech WAV isn't silently dismissed (`:859`)
- pre-roll discarded (instant-dictation, media playing, issue #474) → degrade (`:509`)
- engine switch / shutdown racing `begin` → scheduler re-checks its reservation so the runtime session can't orphan and wedge the interactive lane.

Partials route through a single serialized `AsyncStream` consumer (`bufferingNewest(1)`), so a stale partial can't overwrite a newer one (`:732-744`). Preview text is normalized over a bounded 360→180-char tail to avoid O(n) recompute per redraw (`DictationOverlayView.swift:446`).

### Nemotron engine shape (the template to generalize)

`NemotronEngine` (`Sources/MacParakeetCore/STT/NemotronEngine.swift`) wraps FluidAudio's `StreamingNemotronMultilingualAsrManager` and implements the live methods:
- `beginLiveDictation(language:onPartial:)` → `manager.setPartialCallback { onPartial($0) }` (`:86-110`)
- `processLiveDictationSamples(_ samples: [Float])` → `manager.process(samples:)` (`:112-124`)
- `finishLiveDictation() -> STTResult` → `manager.finish()` (`:126-152`)
- `cancelLiveDictation()` (`:154-166`)

Note: Nemotron returns `words: []` — **no word-level timestamps** (`:74-80`, `:142-148`). Its default variant is `multilingual-1120ms`, so its partial **cadence is ~1.1 s**, not sub-second.

The app-side protocol `STTLiveDictationTranscribing` is **already engine-agnostic** — `STTRuntime`/`STTScheduler` conform and route to the active engine. The only Nemotron-specific things are the two gate checks above. **That's the seam to widen for multi-engine support.**

---

## 2. FluidAudio streaming landscape (reference)

The key realization: in FluidAudio, **streaming is a property of a specialized manager + (a streaming model *or* a sliding window over a batch model)** — it is **not** a free capability of the batch `AsrManager` that powers Parakeet today.

| Manager (FluidAudio) | Model | Used by us? | Notes |
|---|---|---|---|
| `AsrManager` | Parakeet TDT 0.6B v3/v2 (`AsrModels`) | **Yes** — batch dictation/file/meeting | Batch only. No partials. |
| `StreamingNemotronMultilingualAsrManager` | Nemotron 3.5 multilingual (`nemotron-multilingual-1120ms`, ~1.5 GB) | **Yes** — `NemotronEngine` | Streaming. Single partial string. No word timings. |
| `StreamingAsrManager` (protocol) | — | No | Generic streaming protocol: `appendAudio`, `setPartialTranscriptCallback`, `getPartialTranscript`, `finish`. `ASR/Parakeet/Streaming/StreamingAsrManager.swift:20`. |
| **`SlidingWindowAsrManager`** | **Parakeet TDT (same `AsrModels` we already load)** | **No (opportunity)** | Streams the existing batch model via sliding windows. **Confirmed/volatile** transcript + word timings + vocab boosting. See §3 Path A. |
| `StreamingEouAsrManager` | `nvidia/parakeet_realtime_eou_120m-v1` (separate ~tiny realtime model, 160/320/1280 ms) | No | Dedicated Parakeet *realtime* model with end-of-utterance detection. Extra download. See §3 Path B. |
| `StreamingNemotronAsrManager` | Nemotron (English) | No | English-only Nemotron streaming variant. |

WhisperKit is a separate package (`argmax-oss-swift`), not FluidAudio. See §4.

---

## 3. Parakeet streaming — feasible, two paths

The owner's intuition ("Parakeet should support it because it's the same FluidAudio underneath") is **correct.** There are two concrete paths.

### Path A — Sliding window over the existing TDT model ✅ recommended

`SlidingWindowAsrSession.loadModels()` calls `AsrModels.downloadAndLoad()` — **the exact Parakeet TDT models `STTRuntime` already holds** (`STTRuntime.swift:67-69`, `:1093` `AsrModels.downloadAndLoad`). And `SlidingWindowAsrManager.loadModels(_ models: AsrModels)` accepts pre-loaded models. So:

> **Streaming Parakeet reuses the already-cached 465 MB v3/v2 bundle — zero extra model download, and the model weights are already in memory.**

Public API (`ASR/Parakeet/Streaming/SlidingWindowAsrManager.swift`):
- `streamAudio(_ buffer: AVAudioPCMBuffer)` — "any format, converted to 16 kHz mono" internally (`:212`).
- `transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>` (`:217`).
- `finish() -> String` (`:231`), `reset()`, `cleanup()`, `cancel()`.
- `configureVocabularyBoosting(...)` — real-time custom-vocab rescoring on confirmation (`:86`). **MacParakeet has custom vocabulary** — this is a natural fit.

`SlidingWindowTranscriptionUpdate` (`:803`) carries: `text`, **`isConfirmed`** (confirmed vs volatile), `confidence`, `timestamp`, `tokenIds`, **`tokenTimings`** (word-level timings — *richer than Nemotron*), `tokens`.

`SlidingWindowAsrConfig` (`:678`) knobs: `chunkSeconds`, `hypothesisChunkSeconds`, `leftContextSeconds`, `rightContextSeconds`, `minContextForConfirmation`, `confirmationThreshold`, optional `tdtConfig`. Two presets exist — a default (`left=10s, right=2s, threshold 0.85`) and a lower-latency streaming preset (`left=2s, right=2s, threshold 0.80`).

**Latency characteristic:** `rightContextSeconds: 2.0` means *confirmed* text waits ~2 s of look-ahead before it solidifies, but *volatile* text appears each hypothesis chunk (sub-second to ~1 s, tunable). This maps perfectly onto a two-tone UI: render `confirmed` bright, `volatile` dim. Tunable via the config — we can trade stability for latency.

**Pros:** no new download; word timings; confirmed/volatile UX; live vocab boosting; keeps Parakeet (the *default* engine) — so live preview reaches the default path, not just Beta users.
**Cons:** sliding-window decoding does more compute than a single batch pass (continuous ANE work for the dictation duration); needs `[Float]` → `AVAudioPCMBuffer` wrapping (our sink emits `[Float]`; trivial 16 kHz mono buffer).

### Path B — Dedicated Parakeet realtime EOU model

`StreamingEouAsrManager` (`ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift:163`) uses `nvidia/parakeet_realtime_eou_120m-v1` (a separate ~120M realtime model, 160/320/1280 ms chunks, `loadModels` downloads it).

**Pros:** purpose-built for low-latency realtime; built-in **end-of-utterance** detection (could power hands-free auto-stop).
**Cons:** **extra model download** + extra working memory; a *different* model than the user's chosen v3/v2, so streamed text could diverge from the batch result; more surface to maintain.

### A vs B

| | Path A (sliding window) | Path B (EOU 120M) |
|---|---|---|
| Extra download | **None** (reuses TDT) | Separate realtime model |
| Matches user's chosen v3/v2 quality | **Yes** | No (different model) |
| Word timings | Yes | Yes |
| Confirmed/volatile | Yes | Yes |
| Vocab boosting | Yes | Unknown |
| EOU / auto-stop | No | **Yes** |
| Recommendation | **Default choice** | Revisit if we want EOU-driven auto-stop |

**Recommendation: Path A.** It gives Parakeet (the default engine) a live preview with no download cost and richer data than Nemotron, while keeping the streamed text faithful to the user's selected model.

---

## 4. Whisper streaming — not viable (keep batch-only)

`WhisperEngine` (`Sources/MacParakeetCore/STT/WhisperEngine.swift`) is **batch-only** today — `WhisperKit.transcribeWithResults(...)` over a complete file (`:458-462`); it conforms only to `STTTranscribing`, not the live protocol. Default variant `large-v3-v20240930_turbo_632MB`.

WhisperKit's only streaming surface is `AudioStreamTranscriber` (`.build/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift`):

1. **It owns the microphone.** `startStreamTranscription()` calls `audioProcessor.startRecordingLive()` (`:80`) and reads from its own `state.audioSamples`. There is **no public API to feed our `[Float]` samples**. MacParakeet feeds everything from one `SharedMicrophoneStream`; a second component grabbing the mic is a non-starter (ADR-015 concurrent capture, echo, device-conflict).
2. **30-second window model.** Whisper pads/trims to 480,000 samples/window; partials only surface after a window's encode+decode — **multi-second cadence**, vs Nemotron's ~1.1 s and sliding-window Parakeet's tunable sub-second volatile text.
3. It has a confirmed/unconfirmed segment notion, but only at window boundaries — not a low-latency in-utterance hypothesis.

**Verdict:** not viable without forking WhisperKit or building a custom windowing wrapper (buffer our samples → call batch `transcribe()` per overlapping 30 s window → synthesize "partials" from segment boundaries) — still ~5–15 s latency for a much worse experience. **Keep Whisper batch-only.** Whisper's role is broad-language *fallback*, where instant preview matters least.

---

## 5. UI revamp — preview above the pill, capsule untouched

### The problem (from the screenshots)

The live preview text grows the dark capsule into a tall card, deforming the floating pill.

### Root cause

The preview is composed **inside** `pillContent`, which is what the `Capsule` background wraps:
- `liveTranscriptPreviewText(width:)` is a row in the `VStack` of `holdToTalkContent` (`DictationOverlayView.swift:427`) and `recordingContent` (`:509`).
- `pillContent` → `overlayContent` applies the `Capsule().fill(...)` background around all of it (`:326-340`).

So the capsule stretches to wrap two lines of text → the pill loses its shape.

### The fix (clean, minimal)

**Lift the preview out of the capsule and render it as a sibling above the pill, in the panel's existing headroom.** The plumbing already supports this:

- The overlay panel is a fixed **300×160** `ClickablePanel` (`DictationOverlayController.swift`), positioned bottom-center ~12 pt above the Dock. Width re-centers via `updateSize(width:)`; height is fixed.
- The root `body` VStack is **bottom-aligned** — `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)` (`DictationOverlayView.swift:252`). The pill sits at the bottom; there is **~100 pt of empty panel above it** (where the hover tooltip already renders, `:234`).

So:
1. Remove `liveTranscriptPreviewText(...)` from `holdToTalkContent` (`:427`) and `recordingContent` (`:509`); revert those back to just the `HStack` so the capsule returns to its compact shape.
2. Add the preview as a sibling **above** `overlayContent` in the `body` VStack (`:232`), gated on recording + non-empty transcript. Because the stack is bottom-aligned, the preview grows **upward** into the headroom while the pill stays pinned — pill geometry untouched, no window resize for typical 1–2 lines.
3. Style it as a floating caption — either bare text or its own subtle rounded/blurred background distinct from the pill. (Reuse atoms — colors, opacities, timing — but let the shape differ; see the "siblings not twins" UI principle.)
4. If we want >2 lines, bump panel height (e.g. 160→200) and keep the bottom anchor; the pill still doesn't move.

**Confirmed/volatile rendering opportunity (Parakeet/sliding-window):** unlike Nemotron's single partial string, sliding-window gives `confirmed` + `volatile`. Render confirmed bright and volatile dim/italic so users *see* text settling — this reads as higher quality than jittery whole-line rewrites. Design the preview component for the two-tier model up front, even if Nemotron only fills `confirmed`.

Alternatives considered: a separate `NSPanel` for the preview (more positioning math, two windows to keep in sync — unnecessary, the headroom already exists), or a `CATextLayer` à la the meeting pill's time badge (overkill for text that SwiftUI already lays out). The sibling-above-the-pill SwiftUI restructure is the smallest correct change.

> Do not disturb the idle pill — `IdlePillController` is a *separate* panel, never visible during active dictation. The revamp touches only the dictation overlay.

---

## 6. Proposed multi-engine architecture

The live-dictation protocol is already engine-agnostic; the work is mostly (a) a Parakeet streaming engine and (b) widening the gate from "is Nemotron" to "supports live streaming."

1. **Capability gate, not engine gate.** Replace `== .nemotron` (`AppEnvironment.swift:276`, `STTScheduler.swift:186`) with a per-engine capability — e.g. `SpeechEnginePreference.current().supportsLiveDictation` (Parakeet: true, Nemotron: true, Whisper: false). Keep the scheduler's defensive re-check, just make it a capability check.
2. **`ParakeetStreamingEngine`** (mirror `NemotronEngine`): wrap `SlidingWindowAsrManager`, loaded from `STTRuntime`'s existing `AsrModels` (no new download). Implement `beginLiveDictation`/`processLiveDictationSamples`/`finishLiveDictation`/`cancelLiveDictation`. Bridge the `transcriptionUpdates` async stream → the existing partial callback; bridge `[Float]` → `AVAudioPCMBuffer` for `streamAudio`.
3. **Result path unchanged.** `finishLiveDictation` returns `STTResult` (now *with* word timings for Parakeet); the WAV fallback / degrade invariant from §1 stays exactly as is.
4. **Kill-switch flag.** Add `AppFeatures.liveDictationStreamingEnabled` (default decision below) so a field regression is disable-able without a code release — consistent with how VAD chunking is gated. Also retro-document the existing Nemotron behavior in the CLAUDE.md "Release Channels" main-vs-release delta (currently it only lists `aiFormatterProfilesEnabled`).
5. **Minor:** fix the hardcoded `engine=nemotron` diagnostic string (`DictationService.swift:787`) to read the actual engine.

---

## 7. Open decisions for the owner

1. **Parakeet path:** Path A (sliding window, no download — recommended) or Path B (EOU realtime model, extra download but EOU/auto-stop)?
2. **Default-engine impact:** Parakeet is the *default* engine. Turning on live streaming there changes the dictation *result source* for the default path (streamed final instead of post-release WAV pass) — a big perceived-speed win, but a bigger blast radius than Beta-only Nemotron. Ship behind the kill-switch and/or a settings toggle? Default on or off?
3. **Preview scope:** show the live preview for every streaming-capable engine, or keep it a per-engine setting?
4. **Two-tone confirmed/volatile** rendering — yes/no for v1 of the revamp?
5. **EOU auto-stop** (Path B only): worth a separate model to get hands-free end-of-utterance auto-stop later?

---

## 8. References (file:line)

App side:
- `Sources/MacParakeet/App/AppEnvironment.swift:276` — Nemotron-only live gate
- `Sources/MacParakeetCore/STT/STTScheduler.swift:167-234,186` — scheduler live methods + engine re-check
- `Sources/MacParakeetCore/STT/STTRuntime.swift:67-69,157-174,1093,1100` — batch `AsrManager`/`AsrModels`, live routing
- `Sources/MacParakeetCore/STT/NemotronEngine.swift:86-166` — live engine template
- `Sources/MacParakeetCore/STT/WhisperEngine.swift` — batch-only Whisper
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift:375-409,714-822,832-879,898-923` — stop flow, live session, finish, result/fallback
- `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift:232-344,427,441-467,509` — body/capsule/preview
- `Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift` — 300×160 `ClickablePanel`, bottom-center, `updateSize`
- `Sources/MacParakeetCore/AppFeatures.swift:53` — `meetingVadLiveChunkingEnabled` (flag-gating precedent)

FluidAudio (`.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/`):
- `Streaming/StreamingAsrManager.swift:20` — generic streaming protocol
- `SlidingWindow/SlidingWindowAsrManager.swift:212,217,231,803,678` — Parakeet sliding-window stream, update struct, config
- `SlidingWindow/SlidingWindowAsrSession.swift:6,26` — `AsrModels.downloadAndLoad` (same model as batch)
- `Streaming/EOU/StreamingEouAsrManager.swift:7,163` — Parakeet realtime EOU model

WhisperKit (`.build/checkouts/argmax-oss-swift/Sources/WhisperKit/`):
- `Core/Audio/AudioStreamTranscriber.swift:80` — owns the mic via `startRecordingLive` (the blocker)
