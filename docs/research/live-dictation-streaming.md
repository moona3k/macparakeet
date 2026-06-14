# Live Dictation Streaming — Findings, Architecture & Decision

> Status: **DECIDED** (architecture: display-only preview, decoupled from the
> result; mechanism: Parakeet → FluidAudio `SlidingWindowAsrManager` by study)
> / **OPEN** (one number: Whisper per-pass latency, settle by a quick probe)
> / **PROPOSAL** (impl).
> Date: 2026-06-13. Base: `origin/main` @ `8e62661d1`. Revised after an
> adversarial code-grounded review (see §0).
>
> Implementation plan: `plans/active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md`.

## 0. Review-driven corrections (2026-06-13, adversarial pass)

A skeptic review with code citations changed two things and hardened the rest.
**Durable:** the architecture (preview is display-only, decoupled from the
paste). **Changed:** the *mechanism* flipped — the generic re-transcriber I'd
recommended reinvents exactly the parts (windowing, confirmation, timing-backed
audio trimming) that FluidAudio's `SlidingWindowAsrManager` already ships, so
**Parakeet should use the vendor manager** (a study conclusion, not a spike).
The only residual unknown is a *number* — Whisper's per-pass latency — settled
by a quick probe, not a project. Accepted findings, now baked into this doc and
the plan:

1. **No live frames for Parakeet/Whisper today.** The `DictationAudioSampleSink`
   is created only on the Nemotron-gated live path
   (`DictationService.swift:714-789`), and `AudioRecorder` mirrors samples only
   when that sink is non-nil (`AudioRecorder.swift:536-541`). → Must decouple a
   *display-preview sample sink* from the *native live STT session*.
2. **No samples-based STT API.** STT is path-based (`STTClientProtocol.swift:17-22`);
   scheduler jobs carry `audioPath` (`STTScheduler.swift:23-29,110-129`). A
   preview that transcribes samples needs a real scheduler-level path, not a
   direct runtime call (ADR-016 one-control-plane).
3. **Text confirmation can't drive audio trimming.** `STTResult` has no
   text↔audio alignment contract (`STTResult.swift:3-5,30-34`); Parakeet pads
   passes to a 15s model window. → Trim on **word/segment timings + an absolute
   sample offset + retained left context**, never on a text prefix.
4. **Vendor streamers already solve the hard parts.** FluidAudio
   `SlidingWindowAsrManager` has left/right context, token dedup,
   confirmed/volatile, token timings, bounded buffers; WhisperKit
   `AudioStreamTranscriber` has confirmed/unconfirmed + clip timestamps. →
   **Resolved by study: Parakeet uses `SlidingWindowAsrManager`** (it solves the
   hard parts for us); the generic re-transcriber is not worth reimplementing
   them. Whisper's mechanism is gated on a latency probe (see finding 5).
5. **Latency under-measured.** Parakeet pads to 15s; Whisper pads *every* pass
   to a 30s decode → likely too slow to be useful. → Measure p50/p95, cold/warm,
   CPU/ANE, and stop-latency before enabling Whisper preview by default.
6. **Display-only removes paste *corruption*, not *divergence*.** The paste goes
   through deterministic cleanup + optional AI formatting
   (`DictationService.swift:940-991`) and pre-roll discard already diverges
   preview from WAV (`:505-512`). → It's a **stable preview**, not a "confirmed
   result"; reset it on pre-roll discard; test divergence + choose UI treatment.
7. **Stop/final ordering is mandatory.** The scheduler rejects an interactive
   `.dictation` job while a live session exists (`STTScheduler.swift:395-397`).
   → On stop: **cancel preview → await drain → then final**, holding no
   live-session reservation.
8. Anchor fixes: WhisperKit `transcribe(audioArray:)` is `WhisperKit.swift:896`
   (`:547` is `detectLangauge`); FluidAudio is pinned 0.15.2 (`Package.resolved`),
   not ADR-016's cited 0.13.6.

**Build order (non-negotiable):** prove the vertical slice (decoupled sink +
scheduler-safe preview job + cancel/drain on stop) with a *fake* transcriber
first — that's the real integration risk and it's the same work for any
mechanism. Only then wire the chosen mechanism (Parakeet `SlidingWindowAsrManager`;
Whisper after the latency probe); only then UI polish.

## TL;DR — what's decided vs open

**Decided (architecture):** The live preview is a **display-only, stable
feedback surface, never the source of truth.** The pasted result stays on each
engine's existing final path (Parakeet/Whisper → full-WAV batch on stop, ~instant
for Parakeet; Nemotron → its native streamed final). The preview can't corrupt
the paste; it *can* differ from it (formatting/cleanup/pre-roll/fallback), which
we handle as a UX matter, not a correctness one.

**Mechanism — settled by study, behind one display-only UI adapter:**

| Engine | Mechanism |
|---|---|
| **Parakeet** (default) | **FluidAudio `SlidingWindowAsrManager`** — it ships the hard parts (windowing, confirmed/volatile, token timings, bounded buffers) and reuses the loaded model. No generic re-transcriber, no spike. |
| **Whisper** | One **latency probe** decides viability first (its passes pad to a 30s decode). If usable: `AudioStreamTranscriber` (+ a passthrough `AudioProcessing` fed by our mic) or a thin batch re-transcriber — small choice, made then. **Default-on only if the probe clears.** |
| **Nemotron** (Beta) | Keep its shipped native streaming (PR #496). Don't regress. |

**Gating:** a `supportsLivePreview` capability ANDed with a new
`AppFeatures.liveDictationStreamingEnabled` kill-switch.

**UI:** lift the preview out of the capsule so the pill keeps its shape; render
stable text bright / volatile dim.

---

## 1. The reframe: preview ≠ result (the durable decision)

The preview answers "is the app hearing me, roughly what did it get?" — feedback,
not the paste. Treating it as **display-only** dissolves the correctness problem:
a jumpy/wrong preview can't corrupt the result, so the entire PR #496
streamed-final/degrade machinery does **not** need to be generalized.

**Caveat (review finding 6):** display-only removes paste *corruption*, not
*divergence*. The final paste is the full-WAV transcription run through
deterministic cleanup + optional AI formatting, and pre-roll discard trims audio
the preview already showed. So the bright "stable" preview text can legitimately
differ from what gets pasted. We treat this as expected: call it a **stable
preview** (not "confirmed result"), reset it on pre-roll discard, and pick UI
copy/treatment that doesn't promise the preview *is* the paste.

All three engines can batch-transcribe a raw `[Float]` array — FluidAudio
`AsrManager.transcribe(...)`, WhisperKit `transcribe(audioArray:)`
(`WhisperKit.swift:896`), Nemotron `manager.process(samples:)` — which is what
makes an engine-agnostic preview possible at all.

## 2. The mechanism, reasoned out (not spiked)

What can be settled by reading the code (and is):

- **Parakeet → `SlidingWindowAsrManager`.** It already implements the *hard*
  parts a preview needs — left/right context, token dedup, confirmed/volatile,
  **token timings** (which is what makes safe audio trimming possible, review
  finding 3), bounded buffers — and reuses the model we already load. A generic
  re-transcriber would reimplement all of that with less engine knowledge
  (finding 4) **and** need a new scheduler sample-job (finding 2). There is no
  reason to prefer the generic path for Parakeet; the study decides it. No spike.
- **Nemotron** keeps its native manager (sunk + good).

What reasoning genuinely *can't* give you is a number:

- **Whisper per-pass latency.** Whisper pads every decode to a 30s window
  (`TranscribeTask.swift` / `Models.swift`), so "155× realtime" doesn't apply and
  the real ms drives the product call ("is a multi-second-stale preview worth
  showing?"). This is a **~10-minute probe**, not a project: time one
  `transcribe(audioArray:)` on a ~15s clip (cold + warm). If it clears, pick
  `AudioStreamTranscriber`-with-adapter or a thin re-transcriber (a small
  decision, made then) and consider default-on; if not, ship Whisper preview off.

Whatever the mechanism, keep it **display-only** — vendor streaming carries a
temptation to let the stream become the result; don't.

## 3. Hard constraints any mechanism must satisfy

(From the review — these bind the mechanism and the build.)

- **Audio plumbing:** a display-preview sample sink, **decoupled** from the
  Nemotron native live session, that can be non-nil for Parakeet/Whisper while
  the final paste still comes from the WAV (finding 1). Frames are already
  16 kHz-mono in `AudioRecorder`'s converted path.
- **Scheduler:** preview transcription runs as a real, cancellable scheduler
  task that does **not** hold a `liveDictationSession` reservation (or the final
  `.dictation` interactive job is rejected — `STTScheduler.swift:395`) and does
  not starve the background meeting slot (ADR-016).
- **Stop ordering:** on stop, **cancel preview → await drain → then run the
  final**. Never queue the final behind an in-flight preview pass.
- **Trimming/confirmation:** confirm only timing-backed words/segments; track an
  absolute sample offset; retain left context; never trim on a text prefix
  (finding 3).
- **Latency:** measure before enabling per engine; Whisper's 30s-padded passes
  likely disqualify it from default-on until proven (finding 5).

## 4. Latency model — does display-only cost us?

**No meaningful cost on the default path.** Parakeet already does batch-final
today (record → release → transcribe WAV → paste) — the "fast" experience users
have. Display-only preview keeps that final path identical and only *adds* a
preview. Post-release wait: Parakeet ~100–250 ms (same as today; **measure** —
passes pad to a 15s window), Nemotron ~0 (native, kept), Whisper ~1–3 s (slow
regardless; its passes pad to a 30s decode). Optional **confirmed-prefix-reuse**
fast-final (keep timing-backed confirmed text, finalize only the tail on stop)
is a *follow-up* for slow engines, not v1.

## 5. Whisper (correcting the earlier "not viable")

Whisper preview is feasible — not via a fork. Either a generic re-transcriber
over `transcribe(audioArray:)` (`WhisperKit.swift:896`), or WhisperKit's own
`AudioStreamTranscriber` (it takes `audioProcessor: any AudioProcessing`, a
**public protocol** at `AudioProcessor.swift:52`; a passthrough conformer fed by
`SharedMicrophoneStream` reuses its confirmation logic — no fork). The real
constraint is architecture: a 30s encoder-decoder pads every pass to a 30s
decode, so partials are multi-second. That's inherent and identical under any
approach — and it's why Whisper preview must be **measured before default-on**,
and is the *only* engine for Korean/Japanese/Chinese/+95 langs (who get zero live
feedback today), so it's worth getting right.

## 6. Reference — vendor streaming landscape

| Manager (FluidAudio 0.15.2) | Model | Notes |
|---|---|---|
| `AsrManager` | Parakeet TDT v3/v2 (`AsrModels`) | Batch (what we re-transcribe against / load already). Sample passes pad to a 15s window. |
| `StreamingNemotronMultilingualAsrManager` | Nemotron 3.5 (`nemotron-multilingual-1120ms`) | Native streaming; `NemotronEngine` uses it. ~1.1 s cadence; no word timings. |
| `SlidingWindowAsrManager` | Parakeet TDT (same `AsrModels`) | **Chosen for Parakeet.** Left/right context, dedup, confirmed/volatile, **token timings**, bounded buffers, vocab boosting. No new download. |
| `StreamingEouAsrManager` | `parakeet_realtime_eou_120m-v1` | Realtime + EOU; separate model. Revisit only for EOU auto-stop. |

WhisperKit (`argmax-oss-swift`): `AudioStreamTranscriber` (confirmed/unconfirmed,
clip timestamps), public `AudioProcessing` protocol; batch
`transcribe(audioArray:)` at `WhisperKit.swift:896`.

## 7. What shipped already (Nemotron baseline — keep)

PR **#496** (merged 2026-06-12, **unreleased**; latest tag v0.6.22). Nemotron-only,
gated at `AppEnvironment.swift:276` + `STTScheduler.swift:186`; no `AppFeatures`
flag. Streamed final *is* the paste, with guarded WAV fallback on every degrade
path (`DictationService.swift:856-923`). `NemotronEngine.swift:86-166` is the
engine-level live shape. Kept as-is; new work sits alongside it.

## 8. UI revamp — preview above the pill

Preview currently renders *inside* `pillContent`, which the `Capsule` wraps
(`DictationOverlayView.swift:323-340,427,509`), so the capsule stretches. Fix:
remove it from the capsule and render it as a sibling **above** the pill in the
bottom-aligned `body` VStack (`:232,:252`) — grows upward into the ~100 pt of
headroom (tooltip already lives there), pill geometry untouched. Panel: fixed
`300×160` `ClickablePanel` (`DictationOverlayController.swift`). Stable text
bright / volatile dim; uniform across engines.

## 9. References (file:line)

- `Sources/MacParakeet/App/AppEnvironment.swift:276` — Nemotron-only gate
- `Sources/MacParakeetCore/STT/STTScheduler.swift:23-29,110-129,167-205,395-397` — job=audioPath; live methods + reservation re-check; **interactive-rejected-during-live guard**
- `Sources/MacParakeetCore/STT/STTRuntime.swift:5-16,67-69,157-200` — path-based protocol; batch `AsrManager`/`AsrModels`; live routing (hardcodes `nemotronEngine`)
- `Sources/MacParakeetCore/STT/STTClientProtocol.swift:17-22,42-52` — `STTTranscribing` (path-based); `STTLiveDictationTranscribing`
- `Sources/MacParakeetCore/STT/STTResult.swift:3-5,30-34` — no text↔audio alignment contract
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift:505-512,714-789,856-923,940-991` — pre-roll discard; Nemotron-gated sink creation; final/fallback; cleanup+formatting
- `Sources/MacParakeetCore/Audio/AudioRecorder.swift:536-541` — sample mirror gated on non-nil sink
- `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift:232-344,427,441-467,509` — body/capsule/preview
- `Sources/MacParakeetCore/AppFeatures.swift:53` — flag precedent
- FluidAudio `SlidingWindowAsrManager`, `AsrManager` (15s pad); WhisperKit `WhisperKit.swift:896` `transcribe(audioArray:)`, `AudioProcessor.swift:52` `AudioProcessing`
