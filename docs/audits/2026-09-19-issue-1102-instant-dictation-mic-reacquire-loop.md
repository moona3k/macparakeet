# Issue 1102: Instant Dictation microphone re-acquisition loop (macOS 27)

Reviewed September 19, 2026. Root-cause review only; no product changes made in
this pass.

## Verdict

[#1102](https://github.com/moona3k/macparakeet/issues/1102) is a real,
reproducible **notification feedback loop** in the Instant Dictation warm-hold
path. With Instant Dictation enabled on macOS 27, the shared microphone engine
is torn down and rebuilt ~1.3 times per second while the app is idle, blinking
the mic privacy indicator continuously and re-acquiring the microphone at the
HAL level each cycle.

The defect is a **latent design flaw activated by an OS upgrade**, not a recent
code regression. The vulnerable wiring shipped 2026-07-11; macOS 27's changed
engine-start behavior is what turned it live. Root cause is confirmed with high
confidence from static analysis and matches every measurement in the report.
The fix is small and contained but wants on-device validation on macOS 27
before shipping (see [Fix](#fix-implemented) and [Open questions](#open-questions-settle-from-the-reporters-dictation-audiolog-before-shipping)).

## Symptom (as reported)

- MacParakeet 0.8.7 (`20260918190255`), macOS 27.0, Apple M5 Pro.
- `instantDictationEnabled = 1`, `speechRecognitionEngine = whisper`, built-in
  mic selected. App idle on the Transcribe tab.
- An `AVAudioEngine` teardown/rebuild cycle repeats at ~1.3 Hz (period
  ~750–800 ms), each cycle re-acquiring the mic (`setPlayState Started/Stopped
  Input {BuiltInMicrophoneDevice}`), throwing `-10877`
  (`kAudioUnitErr_InvalidElement`) four times, and issuing a TCC request.
- Per-cycle device churn on one AUHAL: `device 75` (BuiltInSpeaker, 0 input) →
  `device 130` (`CADefaultDeviceAggregate`, 0 input) → `device 70`
  (BuiltInMicrophone). The `-10877` throws occur while parked on the 0-input
  devices, before the mic device is selected.
- **Confirmed trigger:** turning Instant Dictation off stops the loop within a
  few seconds; a cold launch with the setting already off never opens the mic.

## Root cause

A self-reinforcing loop between the platform's `AVAudioEngineConfigurationChange`
observer and the Instant Dictation warm-capture refresh, paced by the 0.5 s
refresh debounce:

1. Instant Dictation armed → `AudioRecorder` holds a passive **warm**
   subscriber (`wantsVPIO: false`, `blocksVPIOPromotion: false`) keeping the
   shared mic engine running while idle. This is the intended settled state
   (`IOState [1, 0]`).
2. On macOS 27 the running engine emits `AVAudioEngineConfigurationChange` on
   each start (the `75 → 130 → 70` device churn, with the four `-10877`
   throws while parked on the 0-input aggregate).
3. The observer, for a **running (non-`prepared`) engine, posts
   `macParakeetMicrophoneSelectionDidChange` unconditionally** — with no check
   that the route/format actually changed
   (`Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift:1704-1709`).
4. `AppSettingsObserverCoordinator` observes it
   (`Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift:41`) →
   `AppDelegate.onMicrophoneSelectionChanged`
   (`Sources/MacParakeet/AppDelegate.swift:366`) →
   `applyInstantDictationPreference(refreshWarmCapture: true)` →
   `AudioRecorder.refreshInstantDictationWarmCapture()`.
5. After the 0.5 s trailing debounce
   (`Sources/MacParakeet/App/AppEnvironment.swift:220`), it does
   `stopWarmCapture()` + `restartPassiveSubscribers()` +
   `startWarmCaptureIfNeeded()`
   (`Sources/MacParakeetCore/Audio/AudioRecorder.swift:342-348`) → full
   teardown + fresh `AVAudioEngine()` + start.
6. The fresh start emits another config change → back to step 2.

**Cadence math:** 0.5 s debounce + ~0.25–0.3 s rebuild ≈ 0.75–0.8 s ≈ ~1.3 Hz,
matching the report. The #481 debounce only *paces* the loop; it cannot break
it because every rebuild re-arms the trigger.

### The core asymmetry (the actual bug)

The codebase already knows engines self-emit config changes on device
selection, and guards **only** the `prepared` path. `markPreparedLocked`
documents it explicitly and defers observer arming
(`MicrophoneEnginePlatform.swift:1454-1462`), and the observer's `prepared`
branch absorbs the benign echo via an `InputConfigurationSnapshot` equality
check plus `preparedConfigurationGeneration`
(`MicrophoneEnginePlatform.swift:1679-1698`). Once the engine **commits
running** (`prepared = false`), there is **no equivalent
`committedInputConfiguration` comparison**, so every self-induced config change
is re-broadcast as a route change. The full-configure path arms the observer
before start (`startConfiguredEngineLocked` → `beginStartupObservationLocked`,
`:1181`/`:1727`), so the warm engine is always observing when macOS 27 fires
its start-time change.

### Secondary symptoms explained by the same mechanism

- **2:1 stop:start ratio (report: ~646 stops / ~327 starts in 10 min).** Each
  rebuild issues an explicit `stopEngine` teardown (`stopWarmCapture`) plus an
  aborted device-attempt teardown inside `configureAndStartLocked`
  (`tearDownLocked` = `audioEngine.stop()` + fresh engine,
  `:1589-1597`), against one committed `start()`. The report's own
  `Engine@XXXX start → config changed → stop → Engine@YYYY start` sequence is
  exactly this aborted-then-committed attempt pair.
- **Four `-10877`/cycle.** The implicit System Default first resolves to
  `CADefaultDeviceAggregate` (device 130, 0 input streams) →
  `kAudioUnitErr_InvalidElement` → the attempt aborts and falls back to the
  built-in mic (device 70). This is the issue #1009 implicit-default→built-in
  fallback firing every cycle.
- **Not internal recovery.** `recoverFromConfigurationChangeLocked` is gated by
  `!engineBox.isEngineRunning()` (`:1790`), so it no-ops while the warm engine
  is running. The ~800 ms gap the reporter flagged as "long for a direct
  handler" is the debounce + rebuild round-trip, confirming the loop is the
  app-level notification path.

### Why exactly Instant Dictation

- **ON:** warm engine running → config changes keep arriving → keep being
  re-posted → loop.
- **Toggled OFF:** `refreshInstantDictationWarmCapture` early-returns
  (`guard instantDictationEnabled`); `onMicrophoneSelectionChanged` routes to
  `refreshIdlePrewarm()` instead. Loop stops within one debounce; the mic is
  left open (steady, not blinking) because the last engine is not torn down.
- **OFF cold:** no warm subscriber, engine never opened, nothing feeds the
  loop.

All three measured states match.

## When introduced / regression status

| Fact | Evidence |
| --- | --- |
| Vulnerable wiring landed | `79fd7cf3` "Harden Bluetooth microphone startup and recovery (#862)", **2026-07-22** — confirmed via `git log -L 1704,1709` as the commit that added the `macParakeetMicrophoneSelectionDidChange` post in the config-change observer's running/non-prepared path (above the `prepared` teardown check). Its intent was to re-evaluate warm-capture eligibility on Bluetooth transport/profile flips behind a stable device ID. |
| (Earlier false lead) | `990a080f` "Observe idle microphone route changes", 2026-07-11 — added the identical post inside the **HAL default-input/output listeners**, a different location. A `git log -S` match on the string alone misattributes the loop to this commit; `-L` on the observer lines corrects it to #862. |
| Warm-hold path origin | `be78bc96` "Add opt-in instant dictation pre-roll (#418)", 2026-06-07 |
| Debounce (#481) | `d6a6c7e0`, 2026-06-10 — paces but does not break the loop |
| Latent risk already documented | `AudioRecorder.swift:135` debounce comment notes each refresh restarts the warm engine "which itself can trigger the next notification" |
| Activation | macOS 27 (reporter installed 2026-09-03); its start-time device churn makes the running engine self-emit a config change per start |
| Not new in 0.8.7 | Reporter observed the same loop in the prior build; unified-log retention cannot reach a pre-27 session for comparison |

Conclusion: **latent design flaw + OS-behavior change**, not a code regression
in a specific release. It is an understandable oversight — the author guarded
the `prepared` path against self-induced config changes but did not add the
symmetric guard to the running path, which never bit on macOS ≤26.

## Fix (implemented)

The implemented fix is a **compound guard in the configuration-change observer**
(`MicrophoneEnginePlatform`). When a running, committed engine receives a
self-emitted configuration change whose input format **and** resolved route are
unchanged on a **positively non-Bluetooth** input, the observer absorbs it —
logging `shared_mic_engine_configuration_change_ignored reason=unchanged_running_route`
and returning **without** posting `macParakeetMicrophoneSelectionDidChange` and
without recovery. This mirrors the guard the `prepared` branch already has and
breaks the loop at its source: no post → no warm refresh → no rebuild → no new
configuration change. Because the benign refresh no longer fires, the pre-roll
is no longer cleared each cycle, so the first-word-clipping regression is fixed
as a consequence.

Mechanics:
- On commit-to-running, `recordCommittedConfigurationLocked(attempt:route:)`
  snapshots the input sample rate + channel count (the **immutable format of the
  buffer that won startup readiness** — `firstUsableBufferFormat()`, captured
  once in the tap so a post-commit callback cannot race the baseline; no extra
  HAL query, so the hot start path is unaffected), the resolved route (the
  already-computed `currentRouteSnapshot`, not a fresh `deviceAttemptsBuilder()`
  call), and the committed **attempt**. Cleared on every engine
  teardown/replacement.
- The observer absorbs only when: `!prepared && running && engineIsRunning`
  (the engine truly stayed up — the stopped/recovery case still posts), the
  committed sample rate/channel count match the freshly read format, the route
  matches, and `preparedAttemptIsSafe(committedAttempt, …)` evaluated **live**
  (not cached) reports the input is positively non-Bluetooth.
- A deterministic `engineRunningProbe` seam (default = real
  `AVAudioEngine.isRunning`) makes the running-engine branch unit-testable
  without hardware, and is used by both the observer and the recovery gate for
  coherence.

**Why the Bluetooth check is live:** it mirrors the `prepared` branch, which
re-evaluates `preparedAttemptIsSafe` at observation time. A Bluetooth headset is
never absorbed (its attempt reports unsafe), and a route that *becomes* Bluetooth
after commit (a transport flip behind a stable device ID/format — the case #862
added the post for) is caught by the live check rather than a stale cached flag.
Any genuine format change fails the format comparison and posts. This preserves
#481/#796/#862.

**Regression tests** (in `MicrophoneEnginePlatformConfigChangeRecoveryTests`):
(a) running engine + unchanged route/format → **no** post and no rebuild;
(b) changed route → post; (c) changed format → post; (d) Bluetooth route → post;
(e) a route that becomes Bluetooth after commit → post (live-check regression).
All 30 tests in the suite pass, plus the focused
`MicrophoneEngineRealPlatformTests`, `SharedMicrophoneStreamTests`,
`AudioRecorderFormatChangeTests`, and `MicrophoneCaptureTests`.

### Why not a recorder-level compare-before-rebuild (the review's first choice)

The independent review recommended a recorder-level compare-before-rebuild in
`refreshInstantDictationWarmCapture` as the primary fix. Implementation revealed
it is **unsafe**: a warm refresh also rebuilds to **drop VPIO** after a meeting
VPIO session leaves (`SharedMicrophoneStream.restartPassiveSubscribers` /
`decidePassiveRestartAction`), which is unrelated to the input format. A
format-based skip in the recorder would suppress that legitimate VPIO-state
rebuild, and the recorder does not hold the VPIO state needed to distinguish the
two cases. It also conflicted with the existing
`testInstantDictationRefreshClearsStaleWarmPreRoll` contract. The
platform-observer guard is the correct layer: it targets only the specific
self-emitted config-change → notification path and leaves every other refresh
trigger (VPIO drop, real route change, HAL default-input change, user
selection) intact.

**Follow-up not implemented (needs macOS 27 hardware):** order device selection
before input-node format/tap setup (or skip the known-0-input aggregate) to
remove the `-10877` churn.

## Severity / urgency

**High priority, not a P0 hotfix.**

- No crash and no data loss (hence not P0).
- **Trust-damaging and user-visible:** for a privacy-focused local-first voice
  app, a mic privacy indicator blinking ~once/second while idle reads as "this
  app is secretly always listening" — disproportionate reputational damage for
  a resource bug, and the kind that generates "is this spyware?" reviews.
- **Real resource cost:** engine teardown/rebuild at 1.3 Hz, four CoreAudio
  throws + a TCC IPC per cycle, ~1,900+ mic re-acquisitions per 10 min —
  battery/CPU/thermals on laptops.
- **Likely functional regression, not just cosmetic:** each rebuild clears the
  pre-roll ring buffer (`preRollBuffer.clear()` in
  `refreshInstantDictationWarmCapture`), so the ~0.45 s pre-roll is wiped
  ~1.3×/s. That plausibly re-introduces first-word clipping for exactly the
  users who enabled Instant Dictation to avoid it — worth confirming as part of
  the fix.
- **Growing blast radius:** every user running Instant Dictation (a marquee
  feature) on macOS 27; adoption is early but climbing. Likely correlates with
  any recent "battery drain" / "mic always on" reports.

Recommendation: land the running-path guard in the next patch, expedited
because it is the newest OS; validate the `-10877`/ordering cleanup on a
macOS 27 machine before including it.

## Open questions (settle from the reporter's `dictation-audio.log` before shipping)

Both reviews agreed the app's own diagnostics can settle the remaining
ambiguity without a macOS 27 machine. Request the reporter's diagnostics export
and check:

- **Which observer state fires.** The `shared_mic_engine_configuration_changed`
  line's `isRunning` / `engine_is_running` fields per cycle. If
  `engine_is_running=false` on each fire, `recoverFromConfigurationChangeLocked`
  can restart the engine on its own — the loop may exist even without the
  AppDelegate hop, so a consumer-side guard alone would not fully break it
  (reinforcing the both-ends fix).
- **Rule out a real device flap.** The default-input summary on consecutive
  lines and whether `audio_default_input_changed` appears per cycle. A genuine
  macOS 27 device flap (Continuity mic, aggregate device) looks identical from
  the observer's side and would need a different fix; if those lines are present
  each cycle, the HAL listener (`:2185`) is the feeder and the config-observer
  guard closes nothing.
- **Mid-startup variant — resolved by construction.** `configureAndStart` runs
  inside `queue.sync` and the observer body is `queue.async` on the same serial
  queue, so a change emitted during start is handled only after start returns:
  either the engine committed (`running == true`, the new guard applies) or the
  attempt failed and `replaceEngineAfterFailureLocked` swapped the engine, so
  `engineBox.wraps` drops the stale notification. The handler never observes
  `!prepared && !running` on the current engine. A change landing between the
  first usable buffer and commit fails `commitRunningIfStartupStayedCurrent`
  (`inputRouteChangedDuringStartup`), which is the existing, intended behavior.
- **On-device (macOS 27) only:** confirm the per-start config change is
  idempotent so the equality guard fully absorbs it (vs. the negotiated format
  legitimately differing each start).

## Independent second opinion (Fable 5.1)

Two independent reviews were requested via `claude -p --model fable` (low and
medium effort) as a cross-check. Fable independently verified the causal chain
against the code and confirmed the mechanism, then surfaced four material
corrections/additions that have been folded into the sections above:

1. **Attribution corrected (high value).** Fable identified that the
   running-branch post was introduced by **#862 (`79fd7cf3`, 2026-07-22)**, not
   `990a080f` — `990a080f` only added the post inside the HAL listeners.
   Verified with `git log -L` and corrected in
   [When introduced](#when-introduced--regression-status).
2. **Third observer state (hole in the original fix).** The observer posts in
   `prepared`, running-committed, **and start-in-progress**
   (`prepared == false && running == false`) states. A guard on the
   running-committed state alone misses the mid-startup variant, where commit
   fails, the warm start throws with no retry, and the already-posted
   notification still drives the loop. This motivated the both-ends fix in
   [Fix](#fix-implemented).
3. **False-negative risk in the naive guard.** Format-equality alone is too
   loose: a Bluetooth transport/profile flip keeps the same device ID and often
   the same format — exactly the case #862 added the post for. The guard must be
   the compound route + format + `bluetoothInputState` condition the `prepared`
   branch already uses, or it reintroduces the #481 HFP pin.
4. **Better primary fix + a missed impact.** Fable recommended the recorder-level
   compare-before-rebuild as the robust primary (idempotent against all three
   observer states and the HAL feeder), keeping the platform guard as defense in
   depth, and noted coalescing posts is insufficient. The low-effort pass also
   flagged the **pre-roll clearing** functional regression now in
   [Severity](#severity--urgency), and that `AudioRecorder.swift:135` already
   documents the loop as a known latent risk. During implementation the
   recorder-level guard was found unsafe (it would suppress the VPIO-drop
   refresh); see [Why not a recorder-level guard](#why-not-a-recorder-level-compare-before-rebuild-the-reviews-first-choice).

### Diff review (Fable 5.1, medium effort)

A third Fable pass reviewed the committed implementation. Verdict: sound and
conservative — it absorbs strictly less than before (only the same-route,
same-format, non-Bluetooth, still-running case), recovery is untouched, and
#796/#862/#481 are preserved. Concurrency/lifecycle: no holes (committed state is
recorded at every running commit, cleared on every teardown/replace, and the
`engineBox.wraps` identity check plus per-engine observer prevents a stale
notification from reading a new engine's committed state). It added one negative
test — same route, changed format, must still post — now implemented
(`testRunningConfigurationChangeWithChangedFormatNotifies`).

**The one merge gate it raised** matches [Open questions](#open-questions-settle-from-the-reporters-dictation-audiolog-before-shipping):
the guard only fires if macOS 27's self-emitted change arrives while
`AVAudioEngine.isRunning == true`. Apple's documented contract is that the engine
stops itself *before* posting the notification. The report's per-cycle sequence
(`configuration changed` → later `stop, was running 1`) is consistent with the
engine still running at notification time, but this must be confirmed from the
reporter's `shared_mic_engine_configuration_changed` log line's `engine_is_running=`
field before merge. **Contingency:** if `engine_is_running=false`, this guard will
not close the issue, and the same committed-state comparison must instead gate the
post in the stopped-engine branch (dropping the `engineIsRunning` requirement).

Both passes independently rated severity **High, not P0**, and both recommend
pulling the reporter's `dictation-audio.log` to confirm which feeder/observer
state fires before finalizing the fix (see
[Open questions](#open-questions-settle-from-the-reporters-dictation-audiolog-before-shipping)).


## Key references

- `Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift` — config-change
  observer (`:1643-1722`), running-branch post (`:1704-1709`), `prepared`
  absorb guard (`:1679-1698`), `markPreparedLocked` (`:1440-1465`),
  `tearDownLocked` (`:1563-1600`), route-change listener post (`:2185`).
- `Sources/MacParakeetCore/Audio/AudioRecorder.swift` —
  `refreshInstantDictationWarmCapture` (`:303-349`), warm start/stop
  (`:1032-1134`).
- `Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift:41`,
  `Sources/MacParakeet/AppDelegate.swift:366` / `:898-922`,
  `Sources/MacParakeet/App/AppEnvironment.swift:201,220`.
- `Sources/MacParakeetCore/Audio/README.md` — "Warm-capture refreshes are
  debounced (issue #481)"; the shared-source self-heal contract.
