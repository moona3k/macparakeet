# Engine Switch — Stage B: Background Optimize + Real Cancel

> Status: **ACTIVE PLAN**
> Drafted: 2026-05-23
> Parent: `plans/active/2026-05-engine-switch-ux-revamp.md` (Stage A shipped in PR #335)
> ADRs: `spec/adr/021-whisperkit-multilingual-stt.md`, `spec/adr/016-centralized-stt-runtime-scheduler.md`
> Scope: make switching to Whisper non-blocking (optimize in the background while Parakeet stays usable) with a meaningful cancel, plus disable-with-reason on the engine cards (A3). No change to STT accuracy or transcript output.
> **Status (2026-05-23): full reactive flow ON HOLD pending telemetry; A3 + cold-switch instrumentation proposed first. See "Validation findings" below before building §3–§5.**

## 0. Validation findings + status (2026-05-23)

> This section reflects empirical testing + a reframe done after the rest of the doc was drafted. The full reactive background-optimize flow (§3–§5) remains documented and viable, but is **not greenlit**. Read this first.

### Validated empirically (CLI spike, M4 Pro)

Ran the real engines via `macparakeet-cli` (isolated `--database`, `--no-history`, `MACPARAKEET_TELEMETRY=0`) to test whether the ANE **serializes** or **parallelizes** the two engines.

- **Warm-inference contention is benign.** While Whisper saturated the ANE transcribing a 206 s clip (**12.6 s** wall, ~16× realtime), Parakeet on a 5 s clip stayed **sub-0.6 s on every run** — baseline median **~0.29 s** vs under-load median **~0.38 s** (worst **0.59 s**). The pattern is fine-grained time-slicing, **not** serialization. The catastrophic failure mode for Stage B — background Whisper *freezing* dictation — is **ruled out for the inference case.**
- **Why the CLI proxy is valid:** ANE contention is system-wide, so the cross-process CLI test faithfully reproduces the hardware contention an in-process build would see. Caveats: process-per-call over-weights model load (real warm dictation is faster than these absolute numbers); small N; single run.

### NOT established (do not claim these)

- **Cold-compile contention is unmeasured.** The one-time CoreML/ANE specialization (the real multi-minute "first switch") could not be reproduced on this machine: moving `~/Library/Caches/com.apple.e5rt.e5bundlecache` aside had no effect (it was **empty, 0 B**), and a forced "cold" Whisper load returned **11.3 s — no slower than warm (12.6 s)**. The warm specialization is evidently baked into the model directory, not that cache. A true cold compile would need `models clear` + a ~616 MB re-download (deferred — low ROI vs instrumented rollout).
- **Hypothesis, not a result:** the specialization cache being empty yet Whisper loading fast suggests the one-time cost is largely CPU/disk-bound (compilation + the original download), which would *not* monopolize the ANE Parakeet uses — so Parakeet would likely stay responsive during it too. Confirm with telemetry; do not treat as measured.
- **Hardware:** all numbers are M4 Pro (best case). Slower Macs unverified.

### Reframe that narrows the problem

Onboarding auto-detects CJK languages (`ko/ja/zh/yue` from `Locale.preferredLanguages`) and prepares Whisper during the dedicated "Prepare Speech Model" step (verified: `OnboardingViewModel.recommendedWhisperLanguage`). So for the target users, the cold compile happens **in onboarding, behind a progress UI** — not as a surprise mid-session freeze. The brutal "freeze with no exit" only hits a narrower group: someone who starts on Parakeet and *later* switches to Whisper manually for the first time. **Frequency of that path is unknown.**

### Proposed direction (pending owner decision)

Main failure mode ruled out + painful path narrower than assumed + frequency unmeasured ⇒ the disciplined sequence is:

1. **Ship A3** (disable engine cards + named blocker while a meeting/job is active). Cheap, independent of all concurrency work. (§3.5)
2. **Instrument first:** add `was_cold` + duration to the existing `speechEngineSwitchOperation` event to measure how often / how long cold *mid-session* switches actually occur in the wild. (§7)
3. **Decide the full Stage B from that data.** If cold mid-session switches are rare → Stage A's honest label may suffice; don't build the complex flow. If common/painful → build it, and **prefer the simpler opportunistic pre-warm** (reuse `prepareWhisperInBackground()` triggered after download / at idle, so the switch is just the fast path) over the full reactive flip-retry-cancel flow (§3.2–§3.4).

**Status: A3 = ready to build · cold-switch telemetry = ready to build · full reactive Stage B = on hold pending telemetry.**

## 1. Goal

Today, switching to Whisper for the first time is **exclusive and blocking**: the scheduler sets `acceptsNewJobs = false` for the whole multi-minute CoreML compile, so dictation / file / meetings all pause, and there is no way out (`STTScheduler.setSpeechEngine`, `STTScheduler.swift:181-208`).

Stage B turns that into: **tap Whisper → Parakeet keeps working → Whisper optimizes in the background → flip when ready**, with a cancel that means "keep Parakeet" and is instant.

```
   STAGE A (today)                       STAGE B (this plan)
   ──────────────                        ───────────────────
   tap Whisper                           tap Whisper (cold)
        │                                     │
   ❄️ all STT frozen               Parakeet stays active + usable
   indeterminate spinner            Whisper compiles in background
   no exit                          tile: "Optimizing…  [Cancel]"
        │                                     │
   minutes later: on Whisper        ready → auto-flip to Whisper (fast)
                                    cancel → stay on Parakeet (instant)
```

## 2. Confirmed facts this plan rests on

### WhisperKit (argmax-oss-swift `0.18.0`, rev `e2adabbe`; verified in local `.build/checkouts` **and** public GitHub)

- `open class WhisperKit` — **not** an actor / not `Sendable`. Concurrent access to one instance is a data race. We are safe because WhisperKit is owned by our `WhisperEngine` **actor**, whose `AsyncPermit` (`transcriptionPermit`) serializes `prepare`/`transcribe`/`unload`.
- `open func loadModels(prewarmMode:)` and `open func prewarmModels()` are public and separable from `init`. We **do not need** the lazy pattern: `WhisperEngine.prepare()` already performs the full load via `WhisperKit(WhisperKitConfig(load: true, download: false))`, is idempotent (early-returns when `isLoaded`), and (since Stage A) calls `markWhisperOptimized` on success.
- **The load/compile is not cancellable** — `loadModels()` has no `Task.checkCancellation()`; each `MLModel.load` is a single uninterruptible `await`. ⇒ Stage B cancel = "stop waiting / don't flip," not "interrupt the compile." That is acceptable here precisely because the compile runs in the background where nothing is waiting on it.
- `open func unloadModels()` frees the resident models. We expose this via `WhisperEngine.unload()` → `STTRuntime.unloadWhisper()`.

### Codebase control plane (file:line)

- `STTRuntime.warmUp(onProgress:)` prepares the **current** `speechEngine` only — it reads `speechEngine` and switches on it (`STTRuntime.swift:201-212`). `backgroundWarmUp()` + `backgroundWarmUpState` + `observeWarmUpProgress()` are a **single shared channel for the active engine's readiness** (`STTRuntime.swift:267-326`), consumed by `OnboardingViewModel.startEngineWarmUp()` and the meeting panel. **Do not** reuse this channel to prep the inactive Whisper engine — it would corrupt active-engine readiness UI.
- Scheduler switch guard throws `STTError.engineBusy` unless `acceptsNewJobs && activeSpeechEngineSessionIDs.isEmpty && !hasQueuedOrRunningJobs && speechEngineSwitchTask == nil` (`STTScheduler.swift:185-190`). These are **private**.
- Job engine resolution: a job with `speechEngine: nil` runs on the runtime's current `speechEngine`; an explicit `SpeechEngineSelection` routes per-job (`STTScheduler.swift:305-316`, `STTRuntime.transcribe` overloads `:78-109`). ⇒ while the active engine stays `.parakeet`, all dictation/meeting/file jobs keep using Parakeet automatically.
- Meeting holds a `SpeechEngineLease` from start through transcription (`MeetingRecordingService.swift:330-332`, retain `:589/732-736`, release `:618-620/738-741`), which keeps `activeSpeechEngineSessionIDs` non-empty ⇒ the flip is already blocked while a meeting is live.
- Singletons created in `AppEnvironment` (`sttRuntime`, `sttScheduler`); `SettingsViewModel` receives the scheduler as both `sttClient` and `speechEngineSwitcher` (`AppEnvironmentConfigurer.swift:118-119`). The VM cannot reach the runtime directly — new entry points must be added to the scheduler + the protocol the VM holds.
- No public way for the VM to know a meeting/job is active (needed for A3). `MeetingRecordingService.isRecording` exists; scheduler availability is private.
- Feature flags: plain static `Bool` on `AppFeatures` (`AppFeatures.swift`).

## 3. Architecture

### 3.1 A dedicated background-prep channel (do not overload active warm-up)

Add to `STTRuntime` a **second, independent** mini state machine for "prepare the *inactive* Whisper engine," mirroring the existing warm-up pattern (generation guard + observer stream + `STTWarmUpState`) but never touching `speechEngine`, the active managers, or `backgroundWarmUpState`:

```
STTRuntime
  + whisperPrepareState: STTWarmUpState        // idle/working/ready/failed (reuse enum)
  + whisperPrepareTask: Task<Void, Never>?
  + whisperPrepareGeneration: UInt64
  + whisperPrepareObservers: [UUID: AsyncStream<STTWarmUpState>.Continuation]

  func prepareWhisperInBackground()             // generation-guarded; runs whisperEngine.prepare() at .utility
  func observeWhisperPrepare() -> (UUID, AsyncStream<STTWarmUpState>)
  func cancelWhisperPrepare()                   // cancels task + reclaims memory (see 3.4)
```

`prepareWhisperInBackground()`:
1. If Whisper already `isReady()` → set `.ready`, return.
2. Construct `whisperEngine` if nil (cheap), generation-guard a `Task(priority: .utility)` that calls `whisperEngine.prepare(onProgress:)`.
3. **Never** sets `speechEngine = .whisper`. The active engine stays Parakeet; all jobs keep routing to Parakeet (see §2). `prepare()`'s own `AsyncPermit` serializes against any Whisper transcribe.
4. On success: `markWhisperOptimized` already fired inside `prepare()`; set `.ready`. On failure: `.failed`. On cancel: leave state, then reclaim (3.4).

This runs concurrently with Parakeet jobs (FluidAudio managers — a different object graph), so there is **no data race**; the only shared resource is the ANE/CPU. Run prep at `.utility`/`.background` priority to keep dictation responsive (accept mild slowdown of an in-flight dictation during the compile).

### 3.2 The flip (warm → active)

When `whisperPrepareState == .ready`, the VM calls the existing `setSpeechEngine(.whisper)`. Because Whisper is already resident, `performSpeechEngineSwitch` runs `engine.prepare()` as a no-op, commits `speechEngine = .whisper`, and unloads Parakeet (`STTRuntime.swift:425-453`) — a **fast** operation. It still goes through the scheduler's exclusive guard, so if a job/meeting is in flight the flip must wait (3.3).

### 3.3 Deferring the flip under load

The flip needs the scheduler idle (no jobs, no lease). Two parts:

- **Expose availability** (also required by A3): add `func engineSwitchAvailability() async -> EngineSwitchAvailability` to the scheduler, derived from the existing private guards:
  ```
  enum EngineSwitchAvailability: Equatable, Sendable {
      case available
      case meetingActive        // activeSpeechEngineSessionIDs non-empty
      case transcribing         // hasQueuedOrRunningJobs
      case switchInProgress     // speechEngineSwitchTask != nil
  }
  ```
- **VM flips when available.** On `.ready`, the VM calls `setSpeechEngine(.whisper)`; if it throws `engineBusy`, it waits for availability to become `.available` (observe/poll) and retries, bounded. (We deliberately keep the queue-the-switch logic out of the scheduler for v1 to avoid changing its exclusivity contract.)

### 3.4 Cancel semantics (the whole point)

"Cancel" = **Keep Parakeet**, instant from the user's view:

1. `cancelWhisperPrepare()` cancels `whisperPrepareTask` → the VM stops observing → tile returns to Parakeet immediately. Parakeet was never unloaded, so nothing to restore.
2. The native compile **cannot be interrupted** (confirmed), so it finishes in the background. That is *useful*: it populates the on-disk/OS CoreML specialization cache and (via `prepare()` success) sets the optimized flag, so the **next** switch is fast.
3. **Memory reclaim:** after the in-flight compile completes, if the active engine is still not Whisper (user stayed on Parakeet), `unloadWhisper()` so we don't hold ~632 MB the user isn't using. The next switch reloads from the warm cache in seconds.
   - *Alternative (simpler, more memory):* keep Whisper resident for an instant next switch. Recommendation: **unload** — respects the local-first/lightweight ethos; warm-cache reload is already fast.

### 3.5 A3 — disable engine cards with a reason

Surface `engineSwitchAvailability()` to `SettingsViewModel`; gate the tiles:
- `.meetingActive` → cards disabled, copy "Stop the meeting recording to switch engines."
- `.transcribing` → "Finishing transcription — switch when it completes."
- `.switchInProgress` / optimizing → handled by the optimize UI.
Replaces today's tap-then-generic-`engineBusy`-error.

## 4. Sequence (cold first switch, happy path)

```mermaid
sequenceDiagram
  participant U as User
  participant VM as SettingsViewModel
  participant Sch as STTScheduler
  participant RT as STTRuntime
  participant WE as WhisperEngine

  U->>VM: tap Whisper (cold)
  VM->>Sch: prepareWhisperInBackground()
  Sch->>RT: prepareWhisperInBackground()
  RT->>WE: prepare()  (Task .utility, active engine stays .parakeet)
  Note over VM: tile shows "Optimizing… [Cancel]"; dictation still works on Parakeet
  WE-->>RT: success (markWhisperOptimized fired)
  RT-->>VM: whisperPrepareState = .ready (via observer)
  VM->>Sch: engineSwitchAvailability()
  Sch-->>VM: .available
  VM->>Sch: setSpeechEngine(.whisper)   (fast: already resident → unload Parakeet)
  Sch-->>VM: success → tile shows "Active"
```

Cancel path: `U->>VM: Cancel` → `VM->>Sch: cancelWhisperPrepare()` → stay on Parakeet; compile finishes in bg → `unloadWhisper()`.

## 5. File-by-file changes

| File | Change |
|---|---|
| `Sources/MacParakeetCore/STT/STTRuntime.swift` | New `whisperPrepareState` machine: `prepareWhisperInBackground()`, `observeWhisperPrepare()`, `cancelWhisperPrepare()`, generation guard, memory-reclaim on cancel. Independent of `backgroundWarmUp`. |
| `Sources/MacParakeetCore/STT/STTScheduler.swift` | Forward the three prep methods to the runtime; add `engineSwitchAvailability()` derived from existing private guards. |
| `Sources/MacParakeetCore/STT/STTClientProtocol.swift` | New protocol(s) for what the VM holds: `WhisperBackgroundPreparing` (prepare/observe/cancel) + `EngineSwitchAvailabilityProviding`. `STTScheduler` conforms. |
| `Sources/MacParakeetCore/AppFeatures.swift` | `static let backgroundWhisperOptimizeEnabled: Bool` (default `false` until validated). |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | Cold-tap path: when flag on + Whisper cold → `prepareWhisperInBackground()` + observe; drive `whisperOptimizing`/progress; on `.ready` flip (retry under busy); `cancelWhisperOptimize()`. `engineSwitchBlockedReason` for A3. When flag off → existing blocking switch (unchanged). |
| `Sources/MacParakeet/Views/Settings/Components/EngineOptionTile.swift` | "Optimizing…" footer state + inline **Cancel**; disabled appearance + reason tooltip. |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Wire optimize state, Cancel action, and availability-driven disabling into the tiles; replace generic busy error with named reason. |
| Telemetry | Extend `speechEngineSwitchOperation` with `mode: foreground|background` + `was_cold`; add `whisperBackgroundOptimize` start/complete/cancel/fail with duration. Remember the two-repo allowlist (`functions/api/telemetry.ts`). |

## 6. Edge cases & invariants

- **Dictation during prep** → uses Parakeet (active unchanged); works. Mitigate ANE contention with `.utility` priority.
- **Meeting starts during prep** → prep continues; flip deferred until the meeting's lease releases (already enforced by the switch guard).
- **User taps Parakeet / Cancel during prep** → `cancelWhisperPrepare()`; stay Parakeet; bg compile finishes → unload Whisper.
- **Whisper already warm** (Stage A flag true) → skip background prep; switch immediately (fast).
- **Prep fails** → `.failed`; tile shows error + Retry; stay Parakeet; never mark optimized.
- **App quit during prep** → `shutdown()` invalidates prep task (mirror `invalidateBackgroundWarmUp`); flag only set on real success.
- **Re-entrancy** → generation guard prevents a stale prep completion from flipping after the user changed their mind.
- **Invariant:** active engine never changes to Whisper until prep is `.ready` AND the scheduler is idle. No engineless window (load-before-unload preserved by the existing flip path).

## 7. B4 — the one product decision

When prep completes, **auto-flip to Whisper** vs **notify "Whisper ready — switch now"**?
- **Recommendation: auto-flip.** The user explicitly tapped Whisper; auto-fulfilling the intent is least-surprising, and Stage A's status already set the expectation. Show a brief confirmation. (If a meeting is running, the flip simply waits — no prompt.)
- *Notify* only adds a second click for the same outcome; reserve it only if user testing shows surprise.

## 8. Feature flag & rollout

Gate the whole new path behind `AppFeatures.backgroundWhisperOptimizeEnabled` (default `false`). With it off, behavior is exactly Stage A + the blocking switch (zero risk). Flip to `true` after the test matrix passes and a manual cold-switch + cancel + meeting-overlap pass on device. A3 (disabled cards) can ship enabled independently (it only improves the blocked-state copy).

## 9. Test plan

- **Runtime** (mock WhisperEngine): `prepareWhisperInBackground` → `.ready` on success without changing `speechEngine`; `.failed` on error; generation guard ignores stale completion; cancel leaves active engine intact and reclaims.
- **Scheduler**: background prep does **not** set `acceptsNewJobs=false` and does **not** block a concurrent Parakeet job (assert a job runs to completion while prep "in progress"); `engineSwitchAvailability()` returns the right case for meeting-lease / running-job / idle.
- **VM**: cold tap → prep started + observed; on `.ready` → flip called; flip under `engineBusy` retries when available; cancel → stays Parakeet, no flip; A3 reason strings for each availability case.
- **Concurrency**: dictation + background prep overlap (integration with mocks) completes both.
- Run focused tests then full `swift test`.

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| ANE/CPU contention slows in-flight dictation during compile | `.utility`/`.background` priority for prep; document expected mild slowdown |
| Dual residency (Parakeet + 632 MB Whisper) during prep | bounded to the prep window; unload Whisper on cancel/non-flip |
| Scheduler exclusivity change introduces a switch race | availability is read-only derivation of existing guards; flip still goes through the unchanged `setSpeechEngine`; feature-flagged |
| Uninterruptible compile keeps burning CPU after cancel | accepted (unavoidable); reframed as warming the cache for next time |

## 11. Out of scope

- Interrupting the CoreML compile itself (not possible per WhisperKit).
- Letting two engines serve different jobs simultaneously (architecture keeps one active engine).
- Variant picker / multi-variant management.
