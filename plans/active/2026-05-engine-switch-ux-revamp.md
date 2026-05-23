# Engine Switch UX Revamp

> Status: **ACTIVE PLAN**
> Drafted: 2026-05-23
> ADR: `spec/adr/021-whisperkit-multilingual-stt.md`, `spec/adr/016-centralized-stt-runtime-scheduler.md`
> Scope: Settings → Engine switching UX (Parakeet ↔ Whisper). No change to STT accuracy, scheduler slot topology, or meeting engine-pinning semantics.

## 1. Problem

Switching to Whisper in Settings (`Engine` tab) freezes all voice features for minutes on first use, with only an indeterminate spinner and no way out. Three concrete gaps:

1. **No escape.** Once the switch starts, both engine cards disable and there is no cancel — the only exit is force-quit (`SettingsView.swift` engine section; switch Task is fire-and-forget at `SettingsViewModel.swift:1253`).
2. **Lying status copy.** The Whisper tile shows *"Downloaded · May optimize on first load"* for **both** the cold (slow, never-compiled) and warm (fast, already-compiled) cases — they map to the same `LocalModelStatus.notLoaded` (`EngineOptionTile.swift:158-163`). Users can't tell whether the next switch will take seconds or minutes.
3. **Vague blocked state.** Tapping an engine while a meeting/job is active fails with the generic *"Speech engine is busy. Try again after the current transcription finishes."* (`STTClientProtocol.swift:103`) — it never names the meeting. `handleWhisperTileTap` only pre-checks model-download status, not active leases/jobs (`SettingsView.swift:1779-1794`).

## 2. The slow part (ground truth)

The 632 MB download is **not** the slow part for the common case; the model is already on disk. The cost is the **one-time CoreML compile + Neural Engine specialization** inside WhisperKit's loader (`WhisperEngine.swift:295`, `WhisperKitConfig(load: true, download: false)`). Compiled `.mlmodelc`/specialization artifacts are cached, so second+ loads are fast. This is what the "May optimize on first load" copy refers to.

## 3. The finding that reshapes the cancel

A cancel button on the **current blocking flow cannot give the minutes back.** Cancellation propagates (`STTScheduler.swift:201-207`), but the CoreML compile is one long uninterruptible `await` we don't control: there are no suspension checkpoints inside it (`WhisperEngine.swift:265` is the only `checkCancellation`, and it runs *before* the heavy work). A cancel issued mid-compile cannot return control until the compile finishes — and without a post-compile `checkCancellation` the switch would even complete anyway.

**Conclusion:** the way to make cancel meaningful is to stop blocking. Run the one-time optimize as a **background preparation** while Parakeet stays active and usable; flip to Whisper when ready. Then "cancel" = "keep Parakeet" and it is *instant*, because the user was never frozen.

The runtime already has the scaffolding: a generation-guarded background warm-up with an observer stream and state machine (`STTRuntime.swift:267-314`) — today it warms Parakeet only. And the switch is already **load-new-before-unload-old** (`STTRuntime.swift:425-453`), so the previous engine stays resident until the new one is ready — rollback is inherently clean, no engineless window.

## 4. Target experience

Cold first switch to Whisper:

1. Tap Whisper (downloaded, never optimized on this Mac).
2. **No app-wide freeze.** Parakeet stays active; dictation/meetings keep working. The Whisper card shows *"Optimizing for this Mac…"* with the existing escalating watchdog copy (`WhisperEngine.swift:496-520`) and a **Cancel** = "keep Parakeet".
3. On completion, flip to Whisper automatically (their stated intent) with a brief confirmation. Subsequent switches are instant.
4. On cancel: stay on Parakeet, zero wait. Compile cache is warm, so the next attempt is fast; mark the variant "optimized".

### Card states + copy

| Situation | Dot | Label | Detail |
|---|---|---|---|
| Active + loaded | green | **Active** | Loaded in memory |
| Optimized before, not active (warm) | green | **Ready** | Switches in seconds |
| Downloaded, never optimized (cold) | amber | **Setup needed** | First switch optimizes — a minute or two |
| Downloading | amber | **Downloading** | NN% · 632 MB |
| Optimizing now | amber | **Optimizing…** | *(watchdog detail)* + **Cancel** |
| Failed | red | **Setup failed** | Retry below |
| Unavailable (meeting/job active) | dim | **Unavailable** | While a meeting is recording |

Copy guidance: avoid a hard minute count (slower Macs overrun it; the watchdog handles the long tail). Adjacent fix: onboarding states the Whisper download is *"~6 GB"* (`OnboardingFlowView.swift` ~line 1171) — it is 632 MB; ~6 GB is Parakeet's bundle.

## 5. Staged delivery

### Stage A — honest + safe (low risk, decision-independent, ship first)

- **A1 + A2 — shipped (PR #335).** `whisperOptimizedVariants` persistence (per variant) in `SpeechEnginePreference`, set on the first successful `prepare()`; the engine tile splits the downloaded-but-inactive footer into cold (amber "Setup needed · Optimizes on first switch") vs warm (green "Downloaded · Loads in seconds") via a `needsFirstOptimize` tile input. Static copy avoids a hard minute count (slower Macs overrun it); the in-switch watchdog handles time reassurance. The `LocalModelStatus` model is unchanged — the cold/warm split is a pure presentation concern, so no new enum case.
- **A3. Disabled cards + named blocker (follow-up).** Surface engine-switch availability from the scheduler (it already holds `activeSpeechEngineSessionIDs` + `hasQueuedOrRunningJobs`, `STTScheduler.swift:186-187`) to the VM; gate `handleWhisperTileTap`/`selectEngine` with meeting/job-specific copy. High-value case is meetings (already tracked app-wide).

### Stage B — background optimize (the real cancel)

- **B1. Engine-parameterized background prepare.** Extend the runtime warm-up so `whisperEngine.prepare()` can run in the background **without** `acceptsNewJobs = false` while Parakeet stays active.
- **B2. VM orchestration.** Cold Whisper tap → start background prepare → on completion call `setSpeechEngine(.whisper)` (now fast). Defer the flip if a meeting/job is running when prepare finishes (lease guard already enforces).
- **B3. Cancel = cancel the background prepare**, stay on Parakeet (instant). Mark optimized if the cache populated.
- **B4. Decision: auto-switch when ready vs notify "Whisper ready — switch now".** Recommendation: auto-switch (they tapped Whisper).

## 6. Edge cases / invariants

- Meeting starts mid-prepare → flip defers (`beginSpeechEngineSession` awaits the switch task, `STTScheduler.swift:211-216`).
- Cancel then immediate re-tap → generation guard prevents stale completion from flipping.
- Failed prepare → stay on Parakeet, surface Retry; never set optimized=true.
- "Repair" (re-download) is a no-op when files are intact and does not invalidate the compiled cache, so the optimized flag correctly persists. There is no Whisper delete path today; if one is added, it should clear the flag for that variant.
- Brief dual residency (Parakeet + 632 MB Whisper) during prepare — acceptable on Apple Silicon; already happens transiently on every switch via load-before-unload.

## 7. Telemetry

`speechEngineSwitchOperation` already carries `outcome` (incl. `.cancelled`) and `blockedReason`. Add: `was_cold` (first optimize) and `mode` (`foreground`/`background`) so we can measure real-world cold-optimize duration and whether cancels cluster on slow machines.

## 8. Tests

- `SpeechEnginePreference` optimized-variant round-trip + normalization + idempotency + per-variant tracking (done).
- VM cold/warm status mapping (done).
- VM blocked-by-meeting copy + card disable.
- Scheduler/runtime: background prepare does not block jobs; flip defers under active lease; cancel keeps previous engine.

## 9. Open decision

Stage A is shippable on its own. Stage B is the only thing that makes cancel honest and removes the freeze, but it touches the scheduler exclusivity model. Building A foundations first; confirm Stage B go-ahead before B1–B3.
