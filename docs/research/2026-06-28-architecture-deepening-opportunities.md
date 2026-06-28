# Architecture Deepening Opportunities — Meeting flow state + STT engine adapters

> Status: **PROPOSED** (exploration, not committed work; no ADR yet — do not
> treat as a decision). Surfaced 2026-06-28 via the
> `/improve-codebase-architecture` review against `origin/main` at `8ab6dddd4`,
> then hardened against three independent design reviews (Codex, Gemini,
> adversarial-document-reviewer) that verified every claim against the code.
> Re-check line numbers before acting — they drift.

This note documents the two highest-leverage **deepening opportunities** from
that review, for a future agent to pick up. "Deepening" = turning a shallow
module (interface nearly as complex as its implementation) into a deep one (a
lot of behaviour behind a small interface), to improve **locality** (change /
bugs / verification concentrate in one place) and **leverage** (callers and
tests get more per unit of interface they must learn).

Vocabulary: **module / interface / implementation / seam / depth / leverage /
locality**, and the **deletion test** (delete a module — if complexity vanishes
it was a pass-through; if complexity reappears across N callers it earned its
keep).

## The shared meta-pattern

Both findings have the same shape, and it is a *good* shape to build on: **the
clean, pure core already exists; the friction is one layer out, in how that core
is wired or dispatched.**

- Meeting recording: `MeetingRecordingFlowStateMachine` is a pure, testable,
  generation-guarded state machine. The friction is that the **service has no
  way to push a capture-state transition** to the coordinator feeding it, so an
  unsolicited failure is reconstructed by sampling.
- STT: every optional engine is already an actor behind a shared protocol
  (`STTTranscribing`, partially `NativeLiveDictating`). The friction is the
  **runtime** that dispatches to them — it answers "what can this engine do?"
  with scattered `switch`/`if` chains instead of asking the engine.

Both deepenings **extend a pattern the codebase already uses** (an `AsyncStream`
from the same actor; an engine protocol). That contains *part* of the risk — the
wiring — but not all of it (see each finding's constraints). Don't over-read the
precedent as proof the whole change is safe.

---

## Decision case

### Why write this down (vs. just doing it, or ignoring it)

These are sizeable refactors at load-bearing seams (the STT runtime; the meeting
flow). Acting blind risks re-opening solved problems (the ANE SIGBUS, crash
recovery). Ignoring them lets the dispatch tax and the polling latency compound.
A committed, evidence-backed proposal lets the *direction* be reviewed before
anyone writes the diff, and gives the eventual implementation PR a justification
to point at.

### Risk posture / what this PR is

Docs-only, zero behavior change — trivial risk by the repo's review-scaling rule.
The *implementation* of either finding is **not** in scope here and is gated
behind: (a) the `/improve-codebase-architecture` grilling / design-twice step to
design the actual interface, (b) tests proportional to risk, (c) full Greptile +
multi-LLM **code** review on the real diff. This document is the *case*, not the
build plan — a detailed build plan would be speculative until the seam interface
is designed. Greptile is a code reviewer and would no-op on this markdown; the
review that matters for a *proposal* is design/document review (already done for
this draft).

### Honest scope of the payoff

Neither finding is a correctness emergency. Finding 1's status quo loses **no
audio** during its latency window (the service stops capture on failure and all
handlers gate on `captureFailed`); the cost is UI staleness, split locality, and
untestability. Finding 3 ships today with five engines via a compiler-enforced
`switch`; the cost is maintenance friction and an untestable capability matrix,
not a live bug. Both earn their keep on **locality + leverage + testability** —
state the case there, not on inflated correctness or an imagined flood of
engines.

### Why these two first

Highest leverage of the eight candidates surfaced, both with an in-repo
precedent that contains the wiring risk, both verified against real code. The
other six (injectable clock seam — Finding 2; LLM provider adapters; text-processing
orchestration; hotkey matching+validation; preferences write-side; CLI/GUI
shared policy) are recorded in the session transcript and can be written up if
prioritized.

### Sequencing

Commit this → design review of the *reasoning* (done) → pick one finding →
grill/design the interface → implement with tests → that diff gets Greptile +
multi-LLM code review.

---

## Finding 1 — Push capture-state transitions instead of sampling for them

### Problem

The authoritative recording state lives in the `MeetingRecordingService` actor.
When capture fails unexpectedly mid-meeting (mic unplugged, writer error, OS
audio-route change), `failCapture(_:)` flips an internal flag and stops capture
but **emits no notification**. The app-layer `MeetingRecordingFlowCoordinator`
therefore *reconstructs* that transition by sampling `captureMode` on a 1 s
timer and synthesizing a `.captureFailed` event. The "is this recording healthy"
truth is split between the service (authoritative) and the polling reconciler,
and the failure surfaces up to ~1 s late in the UI.

This is not a data-loss bug: `failCapture` calls `audioCaptureService.stop()` and
every capture handler early-returns on `captureFailed`, so nothing new is written
during the window, and the eventual stop path "saves whatever made it to disk."
The cost is **lost locality + UI latency + untestability**, not a corrupt
artifact.

### Verified evidence

| What | Location |
|------|----------|
| Service exposes capture state as **pull-only async getters** (`micLevel`, `systemLevel`, `elapsedSeconds`, `captureMode`, `microphoneMuteState`) | `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift:67-73` |
| `CaptureMode` (`.full`/`.paused`/`.stopped`); `captureMode` returns `.stopped` when `currentSession == nil \|\| captureFailed` | same file `:15-23`, getter `:316-321` |
| `failCapture(_:)` sets `captureFailed = true`, stops capture — **emits no transition** | same file `:935-943` |
| Capture handlers all gate on `!captureFailed` (no audio processed after failure) | same file `:726, :757, :857, :888, :909, :912` |
| Service **already** exposes a *push* stream for transcript text — but it is **lossy** (`bufferingNewest(12)`), the wrong semantics for a state stream | same file `:74, :347-356` (policy at `:353`) |
| `failCapture` has **multiple call paths** (write error, source interruption, error event) → any emitter must be idempotent | reachable from `handleCaptureEvent` `:854-912` |
| 1 s `startPillPolling`: writes levels/elapsed/mute to VMs; reconciles pause/resume divergence (#235); **synthesizes** `.captureFailed` from `captureMode == .stopped` | `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift:887-971` (failure synth `:946-965`) |
| Separate 33 ms loop drives only the live audio visualizer (CALayer opacity + change-gated orb) — no state logic | same file `:987-1014` |
| `togglePause` flips state **after** awaiting the service **deliberately** — its comment says an optimistic pre-await flip would race the poll | same file `:174-201` |
| State machine's `.captureFailed` event doc-comment says it is "Emitted by the pill polling task when it detects that audio capture has stopped unexpectedly" — the missing seam, documented in code | `Sources/MacParakeetCore/MeetingRecordingFlow/MeetingRecordingFlowStateMachine.swift:29-35`, handled `:135-138` |
| Contrast: dictation **also polls** (a 50 ms snapshot loop for levels / live-transcript / silence-auto-stop), but dictation surfaces capture *failure* as an **awaited task result**, not a sampled flag | `Sources/MacParakeet/App/DictationFlowCoordinator.swift:1150-1179`; failure via awaited tasks at `:545-549, :972-982` |

### Why it's friction (deletion test, locality)

The contrast that matters is **not** "dictation is event-driven, meeting polls" —
both poll for levels and UI. It is narrower and real: dictation's capture failure
returns through an `await`; meeting's `failCapture` notifies nothing, so the
coordinator must sample `captureMode` to learn a transition the service already
knows precisely. Lost **locality**: "the recording just failed" is true in the
service at `:936` but only actionable a poll-tick later.

Apply the **deletion test** to `startPillPolling`: deleting it removes the *only*
path that surfaces capture failure (and pause divergence) to the flow. It earns
its keep **only because the seam it substitutes for is missing.**

### Deepening direction (not a final interface — design it in the grilling loop)

Give `MeetingRecordingService` a way to **push the transitions the coordinator
currently samples for**. Two shapes, to be chosen during design:

- **One-shot failure signal** (minimal): a single `CheckedContinuation` /
  `@Sendable` callback resumed in `failCapture`. Closes the genuinely-missing
  seam (`captureFailed` is a one-time terminal event per session) with no
  buffering policy, no coalescing risk, no consumer lifecycle. Pause/resume and
  stop are *already* delivered synchronously (`togglePause` awaits; stop is
  caller-initiated), so a one-shot may be all that's missing.
- **Discrete transition `AsyncStream`** (broader): emits
  `paused`/`resumed`/`captureFailed`/`stopped`. Worth it **only** if we also move
  pause/resume-divergence reconciliation off the poll. Must be **lossless**
  (`bufferingPolicy: .unbounded`) — never drop/coalesce a `captureFailed` — and
  the emitter must be **idempotent** across `failCapture`'s multiple call paths.

Whichever is chosen, **a timer still runs** for the genuinely continuous concerns
(`elapsedSeconds`, `micLevel`, `systemLevel`, `microphoneMuteState`); only
failure (and optionally pause divergence) moves to the push seam. Generation
guards stay. Do **not** collapse the state machine — it is already clean.

### Payoffs

- **Locality**: capture health authoritative in one place; the coordinator stops
  re-deriving a transition the service owns.
- **Leverage**: one push source feeds every consumer — pill VM, panel VM,
  menu-bar icon, the Transcribe-tab tile, the auto-stop coordinator
  (`isCapturingMeetingAudioForAutoStop`, coordinator `:25-27`).
- **Tests**: the capture-failure → stop+transcribe path becomes unit-testable by
  resuming the signal on a fake service — no real mic unplug, no 1 s wait.
- **UI latency**: failure surfaces immediately instead of up to a poll tick later.

### Constraints / non-goals

- A state stream must use a **lossless** buffering policy and an **idempotent**
  emitter (multiple `failCapture` paths). The existing `transcriptUpdates` stream
  is `.bufferingNewest(12)` — it de-risks only the actor-as-stream *wiring*, not
  lossless terminal delivery; that part is new work.
- Keep `togglePause`'s post-await flip (it intentionally avoids optimism to not
  race the poll). If the stream takes over pause-divergence, retire the poll
  branch in the same change; if not, the poll keeps that branch and the scope is
  smaller than the broad-stream framing implies.
- No ADR conflict. Does not touch crash-resilience (ADR-019), notes (ADR-020), or
  auto-stop (ADR-023) behaviour — only how a transition reaches the UI.

### Suggested verification

`swift test --filter Meeting` plus a new test that resumes the failure signal on
a fake service and asserts the flow reaches `.stopping` + saves a Transcription;
dev-app smoke: unplug a USB mic mid-meeting and confirm the pill reacts at once.
Confirm `elapsedSeconds`/level/mute UI still updates after the poll branch is
narrowed.

---

## Finding 3 — Capability-based engine adapter seam inside `STTRuntime`

> *Numbered 1 and 3 after their original candidate indices in the eight-candidate
> review; the gap is intentional — Finding 2 (an injectable clock seam) is among
> the six not written up here, per "Why these two first" above.*

> Read `Sources/MacParakeetCore/STT/README.md` first — it is an excellent,
> current subsystem guide and documents the routing rules this finding reorganizes.

### Problem

`STTRuntime` (`Sources/MacParakeetCore/STT/STTRuntime.swift`, ~1942 lines) is the
sole owner of every speech engine. Engine **capabilities** — can it do live
dictation? a tail-window preview? which variant axis does it have? — are answered
by `switch`/`if` chains spread across ~10 engine-discriminating sites plus ~15
variant checks, rather than by the engines declaring what they support. Adding an
engine means editing those sites in lockstep, and the capability matrix is not
unit-testable without loading real models.

### The strongest counter-argument (state it honestly)

The status-quo `switch selection.engine` blocks have **no `default`**, so they
are **compiler-enforced exhaustive**: adding a case to `SpeechEnginePreference`
produces a compile error at every site that must handle it — you cannot forget
one. That exhaustiveness is a real safety asset, and it is how the team already
shipped five engines without disaster. A capability-registry / property-read
model trades compile-time exhaustiveness for **runtime** capability lookups (a
missing/wrong flag becomes a runtime `unsupported` or a silent mis-route). The
deepening is only worth it if the locality/testability win is paired with
loud-failing capability tests (and ideally a registry that is itself
exhaustively keyed). Do not frame the status quo as "just tax" — it buys
compiler safety.

### Verified evidence

The adapter pattern **already partly exists** — extend it, don't invent it:

| What | Location |
|------|----------|
| All 5 optional engines are actors sharing one batch protocol `STTTranscribing` | `NemotronEngine.swift:5`, `NemotronEnglishEngine.swift:18`, `ParakeetUnifiedEngine.swift:27`, `WhisperEngine.swift:8`, `CohereTranscribeEngine.swift:68` |
| Three native streaming engines share a second partial protocol, `NativeLiveDictating`; implementations own their own `ANEInferenceGate` calls | `Sources/MacParakeetCore/STT/NativeLiveDictating.swift:1-34` |
| **Parakeet TDT (v2/v3), the default engine, is NOT wrapped** — bare `interactiveManager`/`backgroundManager` `AsrManager`s on the runtime, transcribed inline on the `STTRuntime` actor | `STTRuntime.swift:83-84`; inline `manager.transcribe(...)` at the pad/URL/preview paths `:504, :554, :687` (each wrapped by `inferenceGate.withExclusiveAccess` at `:503, :553, :686`) |

Engine-discriminating dispatch sites (the friction) — verified labels:

| Concern | Site |
|---------|------|
| Batch `transcribe` routing (`switch engine`) | `STTRuntime.swift:203-216` → `transcribeWith{Parakeet,Nemotron,Whisper,Cohere}` (`:455,:352,:379,:392`) |
| Preview support (nemotron/cohere **throw** unsupported) | `:236-243` |
| Live-dictation engine selection (parakeet-non-unified/whisper/cohere throw) | `:255-288` |
| Warm-up | `:722-736` |
| Readiness (`isReady`, an `if`/equality chain, **not** a switch) | `:855+` |
| Engine-switch prepare (within `performSpeechEngineSwitch`) | `:1002-1026` |
| Engine-switch teardown | `:1040-1050` |
| Telemetry model kind (`switch engine`) | `:1784-1795` |
| Telemetry engine variant (`switch engine`) | `:1797-1815` |
| Default language (`switch engine`) | `:1817+` |
| `currentParakeetVariant.usesUnifiedEngine` branches (6) | `:258, :462, :663, :870, :1107, :1651` (last is in `ensureInitialized` — the hot TDT-vs-Unified init branch) |
| `nemotronModelVariant.isEnglishOnly` branches (9) | `:271, :361, :724, :857, :1006, :1236, :1285, :1390, :1493` |

Not engine dispatch (do **not** move these into adapters): `route(for:)` `:1775`
and `manager(for:)` `:1766` switch on **job/lane**, not engine.

### Why it's friction (deletion test, leverage)

Run the **deletion test** on the *dispatch layer*, not on an engine: delete the
engine-`switch` dispatch and each engine's capability knowledge (Cohere
batch-only/no-preview/no-timestamps; Nemotron's dual-build variant; Parakeet's
`.unified` vs TDT split) reappears scattered across every caller that needs it.
That is the seam earning its keep — but today the runtime, not the engine, holds
that knowledge. Low **leverage**: "does engine X support live dictation?" has no
single answer to read; you must scan `:255-288`. Adding an engine costs edits in
batch routing, preview, live, warm-up, readiness, switch, telemetry, and default
language.

### Deepening direction (not a final interface — design it in the grilling loop)

Extend the existing engine-actor + protocol pattern so each engine is an
**adapter** that declares its capabilities (e.g. `supportsLivePreview`,
`supportsNativeLiveDictation`) and owns its warm-up / readiness / transcribe
lifecycle; the runtime collapses toward a **registry + dispatcher**. Open design
questions to resolve in grilling (not assume away):

- **Variant axes don't collapse flat.** Parakeet `v2/v3/unified` and Nemotron
  `ml/en` each select *different engine actors*, not just a parameter. A capability
  table keyed by `(engine, variant)` may fit *variant dispatch* even if the
  lifecycle uses adapters — the variant axis is already centralized in user
  settings, so centralized variant dispatch is defensible there.
- **Telemetry identity** (`telemetryModelKind`/`telemetryEngineVariant`): decide
  whether it moves into the adapter or stays a runtime concern.
- Keep the capability set small and **test it** so a wrong flag fails loudly
  (recovering the safety the exhaustive `switch` gave for free).

### Constraints / non-goals — read before touching this

- **ADR-016 decision unchanged, but its prose will need a touch.** One runtime +
  one scheduler per process stays. However the ADR's *implementation-direction*
  prose assigns "slot-scoped Parakeet v2/v3 `AsrManager` instances" and "engine
  dispatch" to the runtime; relocating those into runtime-held adapters means
  updating that prose. And capability knowledge **straddles the runtime↔scheduler
  seam**: Cohere's batch-only nature drives its scheduler-level single-flight
  admission, and variant swaps are scheduler-gated (rejected while jobs run or a
  meeting lease is held). Those stay in `STTScheduler` — so the refactor deepens
  only the runtime half and the capability model spans both. Do **not** move
  leases, slot logic, or Cohere single-flight.
- **The ANE inference gate must stay correct.** Every `AsrManager.transcribe`
  inlines `inferenceGate.withExclusiveAccess` to serialize Neural Engine work on
  macOS 14 (SIGBUS, FluidAudio #661); Swift 6 forces it inline because the closure
  captures the non-Sendable `AsrManager` (`STTRuntime.swift:164-176`). If TDT is
  wrapped, the `let inferenceGate` (`:81`, `Sendable`) must be **injected into the
  adapter**, which keeps the gate inline within its own isolation. `NativeLiveDictating`
  already proves this works. All engines must keep contending on the **one shared**
  process gate.
- **Wrapping TDT adds a cross-actor hop on the hot default path.** TDT transcribe
  is currently inline on the `STTRuntime` actor (`:504, :554, :687`); an adapter actor
  introduces a new `await` boundary on every dictation/file transcription.
  **Microbenchmark before merge** — don't merge on a "must not regress" note.
- **The TDT init-serialization guard must migrate.** `ensureInitialized`
  (`:1647`) + `initializationTask`/generation serialize the heavy TDT
  `downloadAndLoad`. Wrapping TDT means that guard moves into the adapter and must
  stay visible to the runtime's warm-up orchestration, so two adapters can't load
  large models simultaneously (peak memory matters: 16 GB machine + Cohere ~11 GB).
- Don't undo the dictation trailing-silence pad (#562) or per-job routing — they
  move *into* the relevant adapter, they don't disappear.

### Lower-risk alternative (consider before wrapping everything)

Wrap **only the optional engines** (Nemotron ml/en, Whisper, Cohere) — they
already have `ensure*` helpers and their own actors, and carry no ANE-gate
inline-capture complication — and keep **Parakeet TDT a named special case**
until the adapter+gate pattern is proven on a non-hot path. This captures most of
the multi-engine dispatch win without putting an actor hop on the default path.

### Why now (honestly)

Not "a flood of engines." The concrete near-term demand is **one** MLX local
engine (`plans/active/2026-06-27-on-device-local-llm.md`), which the exhaustive
`switch` would handle mechanically. The real argument is the maintainability and
**testability of the existing five-engine matrix**, plus doing the seam before
the sixth engine rather than after.

### Suggested verification

`swift test --filter STT` (scheduler, runtime, slot ordering, backpressure,
routing, lease semantics) must stay green; the README's CLI engine-routing smoke
(`transcribe --engine nemotron|whisper|cohere`) must still pick the requested
engine; add adapter-level capability tests that need no model loaded; microbench
the TDT transcribe path before/after if TDT is wrapped.

---

## How to pick this up

1. Re-run the grilling step of `/improve-codebase-architecture` on the chosen
   finding to design the actual interface (the skill spawns parallel
   interface-design agents — minimal vs flexible vs common-case). For Finding 1,
   decide one-shot signal vs full transition stream first; for Finding 3, decide
   wrap-all vs wrap-optional-only and the variant-dispatch model first.
2. Keep the pure cores (state machine / engine protocols) intact; both fixes live
   at the wiring/dispatch seam, not in the transition or inference logic.
3. Both are sizeable; branch from `origin/main`, add tests proportional to risk
   (capture-failure path for #1; capability matrix + ANE-gating + TDT microbench
   for #3), and run the full `swift test` before declaring done.
