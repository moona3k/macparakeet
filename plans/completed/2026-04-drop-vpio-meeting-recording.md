# Drop VPIO from meeting recording to restore concurrent dictation + meeting

> Status: **COMPLETED**
> Date: 2026-04-11
> Revision: 2026-04-11 (post-review: test strategy simplified, MeetingRecordingService default added, audit scope narrowed based on code read, spec diagram update added, watchdog implementation specified)
> Implemented in: `e815396f`
> Note: This document is preserved as a historical plan snapshot; checklist items and future-tense instructions below reflect the pre-implementation execution plan.
> Related research: `docs/research/vpio-process-tap-conflict.md` (authoritative — read this first)
> Related ADRs: `spec/adr/014-meeting-recording.md`, `spec/adr/015-concurrent-dictation-meeting.md`
> Related spec: `spec/05-audio-pipeline.md`
> Regression commit being reverted: `97134e9b` ("Refactor meeting recording to VPIO-first pipeline", 2026-04-10)
> Related files (will be edited):
> - `Sources/MacParakeetCore/Services/MeetingRecordingService.swift` (1 default flip; no audit-driven rewire needed — verified intact)
> - `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` (3 default flips + remove stale comment; no reorder — mic already starts before tap on main)
> - `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift` (1 default flip + diagnostic logging)
> - `Sources/MacParakeetCore/Audio/SystemAudioTap.swift` (diagnostic logging + `lastPinnedOutputUID` ivar)
> - `Tests/MacParakeetTests/Services/MeetingRecordingServiceTests.swift` (only if tests fail after default flip; reviewed reads suggest likely no changes)
> - `Tests/MacParakeetTests/Audio/MeetingAudioCaptureServiceTests.swift` (verified by reading file: NO changes needed — existing VPIO tests use explicit args and test the dead-code fallback path, which we are keeping)
> - `spec/05-audio-pipeline.md` (bullets around 157–161, ASCII diagram at 130–155)

## Problem

Commit `97134e9b` flipped meeting mic capture to `.vpioPreferred`, enabling `AVAudioInputNode.setVoiceProcessingEnabled(true)`. Motivation was to get Apple's hardware AEC on the meeting mic stream so speakers-to-mic echo bleed would not produce duplicated far-end content in the mic transcript.

That refactor broke the meeting recording feature and also broke dictation under certain orderings. Empirical failure modes observed on macOS 15, Apple Silicon, dev build (full details in `docs/research/vpio-process-tap-conflict.md` section "Empirical observations"):

- **Meeting alone with speakers**: mic stream captures, `system.m4a` is 557-byte header-only (Core Audio process tap IO proc never fires, no OSStatus errors, no warning logs).
- **Dictation → meeting**: meeting mic AND system tap both silent.
- **Meeting → dictation**: dictation after a meeting run captures silence (picks up stale `CADefaultDeviceAggregate-<PID>-N` virtual device as its input).

## Root cause (summary — full analysis in research doc)

`setVoiceProcessingEnabled(true)` is a duplex audio unit (`kAudioUnitSubType_VoiceProcessingIO`) and its activation introduces process-scoped aggregate-device state that alters HAL device topology or selection behavior in ways that cause Core Audio process taps — whose aggregate devices depend on "current default-output identity at creation time" — to bind to the wrong or unstable device chain. Observable effect: silent buffers from the tap, and stale aggregate devices that outlive the AVAudioEngine long enough to break subsequent engine instantiations.

No public API workaround exists. Both AudioCap (canonical sample) and Recap (production meeting recorder) avoid VPIO entirely and rely on raw mic + software or transcript-layer echo handling. Independent review by Codex/GPT confirmed this is the industry-standard approach for local-transcription apps on macOS 14.2+.

## Objective

Restore concurrent dictation + active meeting recording (ADR-015) by removing VPIO from the meeting mic path. Echo mitigation moves entirely to:
1. `MeetingSoftwareAEC` (NLMS adaptive filter, already exists from commit `118d7e6f`) applied to the mic stream against the system stream as reference.
2. `MeetingRecordingService.shouldSuppressMicrophoneChunkTranscription` (already exists) dropping mic transcription chunks when system-audio RMS dominates over the same window.
3. "Headphones recommended" copy in the meeting panel UI (out of scope for this plan — tracked separately).

## Scope

### In scope

- Flip all `MeetingMicProcessingMode = .vpioPreferred` defaults to `.raw` in production code.
- Revert the tap-before-mic reorder in `MeetingAudioCaptureService.start(handler:)` that was introduced during investigation on 2026-04-11.
- Update test assertions that expect `.vpioPreferred`.
- Audit `MeetingRecordingService` to confirm `shouldSuppressMicrophoneChunkTranscription`, `shouldTranscribeChunk`, and `configureMicConditioner` still run on the raw-mode path, and wire them back in if the VPIO refactor bypassed them.
- Add lightweight start/first-buffer diagnostic logging to `SystemAudioTap` and `MicrophoneCapture` so future "silent tap, no errors" bugs are diagnosable from logs alone.
- Update `spec/05-audio-pipeline.md:158-159` to document the new default and link to the research doc.
- Manual verification of all five test scenarios below.

### Out of scope (tracked as follow-ups in the research doc)

- Ripping out the `MeetingMicProcessingMode` enum / `VPIOConditioner` / VPIO code paths. Leave as dead code for reversibility.
- Route-change handling (`kAudioHardwarePropertyDefaultOutputDevice` listener).
- Self-capture exclusion (excluding MacParakeet's own bundle ID from the process tap).
- Bluetooth HFP downgrade testing.
- Clock / sample-rate drift handling in `MeetingAudioPairJoiner`.
- WebRTC AEC3 integration.
- Tuning `shouldSuppressMicrophoneChunkTranscription` dominance thresholds (only if step 8 manual tests show they are too loose).
- "Headphones recommended" UI copy.
- ScreenCaptureKit migration.

### Invariants (must not change)

- Dictation capture path (`AudioRecorder.swift`) stays exactly as-is. It never used VPIO and does not need to.
- `SystemAudioTap` creation, aggregate device setup, and IO proc wiring stay exactly as-is. The tap is correct; VPIO was poisoning its clock source.
- `MeetingAudioPairJoiner` behavior, `CaptureOrchestrator` pair processing, and live chunk transcription stay exactly as-is unless the audit in step 4 reveals a bypass.
- Test fixtures and mocks for `MeetingMicrophoneCapturing` / `MeetingSystemAudioTapping` stay compatible with the existing protocol.

## Implementation steps

Execute in order. After each step, either run `swift build` or `swift test` to catch breakage early.

### Step 1 — Flip VPIO defaults to raw (production code)

There are **5 defaults** to flip (grep-verified on 2026-04-11). All of them must be updated for the flip to be consistent across constructors, otherwise a caller hitting a different constructor can re-enable VPIO.

Edit `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`:
- Line 83 (`public init(micProcessingMode:audioCaptureService:audioConverter:sttTranscriber:fileManager:)`) — change default `.vpioPreferred` → `.raw`.

Edit `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift`:
- Line 59 (`public init(micProcessingMode:)`) — change default `.vpioPreferred` → `.raw`.
- Line 73 (`init(microphoneCaptureFactory:systemAudioTapFactory:micProcessingMode:)`) — change default `.vpioPreferred` → `.raw`.
- Line 83 (`init(microphoneCapture:systemAudioTapFactory:micProcessingMode:)`) — change default `.vpioPreferred` → `.raw`.

Edit `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`:
- Line 46 (`public func start(processingMode:handler:)`) — change default `.vpioPreferred` → `.raw`.

**Sanity grep after edits:**

```shell
grep -rn "= \.vpioPreferred" Sources/
```

Should return **zero matches**. Any remaining match is a missed default.

```shell
grep -rn "\.vpioPreferred" Sources/
```

Should return only the enum declaration in `MeetingMicProcessingMode.swift` and the `case .vpioPreferred:` switch arm in `MicrophoneCapture.swift:189`. Everything else is a missed flip.

Run `swift build` after this step. Should compile (no API surface change, only default-value change).

### Step 2 — Verify start order (likely a no-op)

**Status as of this plan revision**: the tap-before-mic reorder that was introduced during investigation on 2026-04-11 has been **reverted in the working copy** before this plan was committed. The branch that carries this plan already shows the correct order (mic first, then tap) on main.

**Action**: verify `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift` `start(handler:)` (around lines 114–175) calls `microphoneCapture.start(...)` BEFORE `tap.start(...)`. If not, restore the original order:

```swift
do {
    microphoneStartReport = try microphoneCapture.start(processingMode: micProcessingMode) { [weak self] buffer, time in
        // ... microphone buffer handler
    }

    try tap.start { [weak self] buffer, time in
        // ... system buffer handler
    }
} catch { ... }
```

Also verify there is no lingering multi-line comment block about "Start the system audio tap BEFORE enabling VPIO on the mic..." — if present, remove it. That comment belongs to the reverted investigation and is stale.

Without VPIO, start order is immaterial, but mic-first is the historical convention in this file and matches `118d7e6f` (the last known-working architecture).

Run `swift build`. Should compile.

### Step 3 — Run tests and update only what breaks

**Important clarification from plan review on 2026-04-11**: The original draft of this step prescribed bulk-replacing `.vpioPreferred` → `.raw` in the test suite. That is WRONG. After reading `MeetingAudioCaptureServiceTests.swift` in full:

- Tests `testStartReturnsVPIOSuccessReportWhenAvailable` (lines 119–141), `testStartReturnsRawFallbackReportForVPIOPreferredFailure` (lines 143–164), and `testStartThrowsWhenVPIOIsRequiredAndUnavailable` (lines 166–194) **explicitly test the `.vpioPreferred`/`.vpioRequired` fallback code paths**, which we are intentionally keeping as dead code for reversibility. These tests must **stay as-is**. Replacing them with `.raw` would make them test trivial "raw mode returns raw report" behavior and would delete coverage of the fallback logic.
- Tests 20–117 and 196–221 use the service default init (no `micProcessingMode` arg). After the default flips to `.raw`, the mock now receives `.raw` on `start`. None of these tests assert on the mode, so they should continue to pass.
- The `MockMeetingMicrophoneCapture` default `startHandler` at line 283 returns `(.vpioPreferred, .vpio)` as an arbitrary placeholder when the test doesn't care about the mode. This is safe to leave — it creates a harmless request/report inconsistency in mock land but no test assertion depends on consistency.

**Predicted outcome**: **Zero changes needed in `MeetingAudioCaptureServiceTests.swift`.** But do not assume — run the tests and only update what actually breaks.

For `Tests/MacParakeetTests/Services/MeetingRecordingServiceTests.swift:480` — the plan author did not read this file, so the correct treatment of the `.vpioPreferred` reference there is unknown in advance. It could be a VPIO-specific test (leave as-is) or a default-assumed test (update). **Read the test before deciding.**

**Execution protocol:**

1. Run `swift test --filter MeetingAudioCaptureServiceTests`. Expected: passes without any test-file changes. If anything fails, read the failure, make the minimum-viable change, and document which test and why in the commit message.
2. Run `swift test --filter MeetingRecordingServiceTests`. If a test fails:
   - Read the failing test.
   - If it is explicitly testing a VPIO code path (mocking VPIO success/failure/fallback), the test may need to stop relying on the `micProcessingMode` default and pass `.vpioPreferred` explicitly. Fix at the call site, not by changing the assertion.
   - If it is a default-driven test, update the expected mode to `.raw`.
3. Run `swift test` (full suite) and verify no unrelated regressions.

**Grep sanity check** at the end of step 3:

```shell
grep -rn "\.vpioPreferred" Sources/ Tests/
```

Expected remaining references:
- `Sources/MacParakeetCore/Audio/MeetingMicProcessingMode.swift` — enum declaration (`case vpioPreferred`).
- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift:189` — the `case .vpioPreferred:` switch arm in `configureInputProcessing`.
- Logging strings in `MicrophoneCapture.swift` lines 192, 196 — the info/warning log formats that mention `requested=vpioPreferred`. Keep as-is; they will simply not fire after the flip.
- Tests explicitly testing VPIO fallback (lines 119–194 of `MeetingAudioCaptureServiceTests.swift`) — VPIO-specific test coverage that stays.
- Possibly the `MockMeetingMicrophoneCapture` default at line 283 — harmless placeholder.

No production `= .vpioPreferred` defaults should remain (already verified in step 1).

### Step 4 — Verify transcript-layer suppression is intact

**Audit already performed on 2026-04-11** by reading `MeetingRecordingService.swift` in full. The VPIO refactor of 2026-04-10 did NOT bypass the suppression logic. Summary of what is already in place on main:

1. **`configureMicConditioner` (line 414)** — switches based on effective mode:
   ```swift
   switch report.effectiveMode {
   case .vpio:
       micConditioner = VPIOConditioner()
   case .raw:
       micConditioner = SoftwareAECConditioner()
   }
   ```
   When the default flips to `.raw`, the capture returns `effectiveMode == .raw`, and this automatically selects `SoftwareAECConditioner`. No rewire needed.

2. **`shouldSuppressMicrophoneChunkTranscription` (line 487)** — runtime gate, not VPIO-conditional:
   ```swift
   private func shouldSuppressMicrophoneChunkTranscription() -> Bool {
       guard recentSystemRms > Self.systemActiveFloor else { return false }
       guard let latestSystemSignalAt else { return false }
       guard latestSystemSignalAt.duration(to: clock.now) <= Self.systemSignalFreshnessWindow else { return false }
       let ratio = recentSystemRms / max(recentProcessedMicRms, Self.rmsEpsilon)
       return ratio >= Self.systemDominanceRatio
   }
   ```
   Thresholds: `systemActiveFloor = 0.02`, `systemDominanceRatio = 10.0`, `systemSignalFreshnessWindow = 750ms`. Runs on every mic chunk regardless of processing mode.

3. **Call site (line 355, inside `handleCaptureOrchestratorOutput`)** — invokes `shouldSuppressMicrophoneChunkTranscription()` before enqueuing mic chunks for live STT:
   ```swift
   case .microphone:
       if !shouldTranscribeChunk(chunk.chunk) {
           // ... low-signal skip
       } else if shouldSuppressMicrophoneChunkTranscription() {
           // ... suppressed due to dominant system
       } else {
           await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .microphone)
       }
   ```
   The suppression branch is independent of VPIO state.

4. **`shouldTranscribeChunk` (line 544)** — RMS floor check (`chunkSignalFloor = 0.00025`), runs for both mic and system chunks. Intact.

5. **`handleCaptureEvent` (line 277)** — receives `.microphoneBuffer` / `.systemBuffer` / `.error` events and forwards to `ingestResampledSamples` → `captureOrchestrator.ingest` → `CaptureOrchestrator.processPairs`, which calls `micConditioner.condition(microphone:, speaker:)` on every pair where `hasMicrophoneSignal == true`. So both the pair-level software AEC and the chunk-level transcript suppression run on every mic chunk in raw mode.

**Action**: open `MeetingRecordingService.swift` and spot-check that lines 414, 487, 355, 544, and 277 still look like the above. If the file has been touched between this plan being written and the agent executing, re-verify. Otherwise, no changes needed — document "transcript-layer suppression audit confirmed intact" in the commit message.

**One tiny latent concern** (not blocking this fix, just noted): `startRecording` on line 163 initializes `micConditioner = VPIOConditioner()` before the capture start completes. Any buffer that somehow arrives before `configureMicConditioner` runs (line 191) would go through the pass-through `VPIOConditioner`. In practice this is impossible — `audioCaptureService.start()` is an async call that completes before any buffer events reach the event loop — but a future hardening could initialize to `SoftwareAECConditioner()` instead. Leave for a follow-up.

### Step 5 — Add diagnostic logging

Add lightweight start-time + first-buffer + silent-watchdog logging to `SystemAudioTap` and `MicrophoneCapture`. Addresses Codex's recommendation that "557-byte file" class bugs must be diagnosable from field logs without requiring a live repro.

Design:
- Log a `_started` line at start with device identity, format, and (for tap) aggregate + pinned output UID.
- Schedule a 2-second watchdog that logs a warning if no buffer has arrived. Cancel on first buffer and on teardown.
- Log `_first_buffer` on first buffer received (low volume, once per capture session).

**`Sources/MacParakeetCore/Audio/SystemAudioTap.swift`:**

Add a new stored property to the class (near the other `tapID`/`aggregateDeviceID` ivars):

```swift
private var lastPinnedOutputUID: String?
private let watchdogLock = NSLock()
private var firstBufferReceived = false
private var watchdogWorkItem: DispatchWorkItem?
```

In `createAggregateDevice()` (around line 123), AFTER `outputUID` is resolved:

```swift
lastPinnedOutputUID = outputUID
```

In `startDeviceIO()`'s `ioBlock` (around line 166), at the very start of the block (before the `guard let self, let callback = ...`):

```swift
self?.markFirstBufferReceived()
```

Add the helper method:

```swift
private func markFirstBufferReceived() {
    watchdogLock.lock()
    if !firstBufferReceived {
        firstBufferReceived = true
        let item = watchdogWorkItem
        watchdogWorkItem = nil
        watchdogLock.unlock()
        item?.cancel()
        logger.info("tap_first_buffer_received")
    } else {
        watchdogLock.unlock()
    }
}
```

At the end of `start(handler:)` (inside the `if didStart` block, replacing or joining the existing `logger.info("System audio tap started")`):

```swift
if didStart {
    let rate = tapStreamDescription?.mSampleRate ?? 0
    let channels = tapStreamDescription?.mChannelsPerFrame ?? 0
    let uid = lastPinnedOutputUID ?? "unknown"
    logger.info("tap_started aggregate_id=\(self.aggregateDeviceID) main_sub_uid=\(uid, privacy: .public) sample_rate=\(rate) channels=\(channels)")
    scheduleWatchdog()
}
```

Watchdog helper (on the class):

```swift
private func scheduleWatchdog() {
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.watchdogLock.lock()
        let fired = self.firstBufferReceived
        self.watchdogLock.unlock()
        if !fired {
            self.logger.warning("tap_no_buffers_2s — aggregate IO proc has not delivered any buffers. Possible VPIO contamination, stale aggregate, or clock binding to virtual device.")
        }
    }
    watchdogLock.lock()
    watchdogWorkItem = item
    watchdogLock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: item)
}
```

In `tearDownResources` (around line 81), at the top:

```swift
watchdogLock.lock()
watchdogWorkItem?.cancel()
watchdogWorkItem = nil
firstBufferReceived = false
lastPinnedOutputUID = nil
watchdogLock.unlock()
```

**`Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`:**

Add parallel stored properties:

```swift
private let watchdogLock = NSLock()
private var firstBufferReceived = false
private var watchdogWorkItem: DispatchWorkItem?
```

In `installTapAndStartEngine` (around line 120–173), inside the `installTap` closure body, before invoking `callback(buffer, time)`:

```swift
self?.markFirstBufferReceived()
```

Add the `markFirstBufferReceived()` helper (parallel structure to SystemAudioTap's implementation).

After `audioEngine.start()` succeeds (line 161), but before returning the start report:

```swift
let deviceID = AudioDeviceManager.currentInputDevice(of: audioEngine) ?? 0
let deviceName = AudioDeviceManager.deviceName(deviceID) ?? "unknown"
let transport = AudioDeviceManager.InputDevice.label(for: AudioDeviceManager.transportType(deviceID))
logger.info("mic_started device_id=\(deviceID) device_name=\(deviceName, privacy: .public) transport=\(transport, privacy: .public) effective=\(effectiveMode.rawValue, privacy: .public) rate=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved)")
scheduleWatchdog()
```

Note: `AudioDeviceManager.InputDevice.label(for:)` is an internal static helper — if it is `internal` rather than `public`, either elevate its visibility (one-line change) or inline the switch locally in `MicrophoneCapture`. Inlining is lower-risk for this PR.

Watchdog helper (parallel to SystemAudioTap's, with different log message):

```swift
private func scheduleWatchdog() {
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.watchdogLock.lock()
        let fired = self.firstBufferReceived
        self.watchdogLock.unlock()
        if !fired {
            self.logger.warning("mic_no_buffers_2s — AVAudioEngine input tap has not delivered any buffers. Possible stale aggregate device picked up as input, or mic device in unexpected state.")
        }
    }
    watchdogLock.lock()
    watchdogWorkItem = item
    watchdogLock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: item)
}
```

In `stop()` (around line 97), inside the lifecycle queue block, cancel the watchdog:

```swift
watchdogLock.lock()
watchdogWorkItem?.cancel()
watchdogWorkItem = nil
firstBufferReceived = false
watchdogLock.unlock()
```

**Constraints for the logging implementation:**

- Do not introduce dependencies on queues owned by the classes (`lifecycleQueue`, the tap's `queue`). Use `DispatchQueue.global(qos: .utility)` for the watchdog timer to avoid blocking state machines.
- Do not use `os_unfair_lock` — the classes already use `NSLock` elsewhere. Stay consistent.
- Do not introduce new actors or async boundaries. This is purely synchronous logging.
- Do not refactor the existing start/stop flow beyond adding these calls.
- Keep each log line under ~200 characters.

Run `swift build`. Should compile. Lint-check that there are no missing imports or signature mismatches.

### Step 6 — Update the audio pipeline spec

Edit `spec/05-audio-pipeline.md`. Three locations need updates:

**Location 1: the ASCII diagram (lines 130–155).**

Change `Mic Input → AVAudioEngine (VPIO preferred) → Input Node Tap` to `Mic Input → AVAudioEngine (raw) → Input Node Tap`.

Change the `MicConditioner:` block:

```
                                   MicConditioner:
                                   - VPIOConditioner (default when VPIO active)
                                   - SoftwareAECConditioner (fallback when VPIO unavailable/disabled)
```

to:

```
                                   MicConditioner:
                                   - SoftwareAECConditioner (NLMS, default in raw mode)
                                   - VPIOConditioner (dead code — retained as switch fallback)
```

**Location 2: the bullet list at lines 157–161.**

Replace:

```markdown
- **Mic audio** is captured via `AVAudioEngine` input node tap with a typed policy (`MeetingMicProcessingMode`): `vpioPreferred` (default), `vpioRequired`, or `raw`.
- `vpioPreferred` attempts `setVoiceProcessingEnabled(true)` and falls back to raw capture with warning telemetry/log context when unavailable; `vpioRequired` fails startup if VPIO cannot be enabled.
- Both streams are captured within the same meeting session and aligned by host time. `CaptureOrchestrator` owns join + offset + chunk boundaries via `MeetingAudioPairJoiner` + `AudioChunker`.
- Mic conditioning is policy-driven: `VPIOConditioner` is default when VPIO is active; `SoftwareAECConditioner` (NLMS) is retained strictly as fallback when VPIO is unavailable/disabled.
```

with:

```markdown
- **Mic audio** is captured via `AVAudioEngine` input node tap in **raw** mode (no VPIO). The `MeetingMicProcessingMode` enum still defines `vpioPreferred` / `vpioRequired` / `raw` cases for reversibility, but the default and only used mode is `.raw`.
- **VPIO is not used anywhere in this process.** `setVoiceProcessingEnabled(true)` introduces process-scoped aggregate-device state that breaks Core Audio process taps in the same process (silent tap IO proc, stale `CADefaultDeviceAggregate-<PID>-N` virtual devices that poison subsequent `AVAudioEngine` instances). This is architecturally incompatible with the meeting-recording feature. See `docs/research/vpio-process-tap-conflict.md` for the full analysis, alternatives considered, and independent review.
- Both streams are captured within the same meeting session and aligned by host time. `CaptureOrchestrator` owns join + offset + chunk boundaries via `MeetingAudioPairJoiner` + `AudioChunker`.
- Mic conditioning runs on the paired mic+system samples via `SoftwareAECConditioner` (NLMS adaptive filter, `MeetingSoftwareAEC`). `VPIOConditioner` is retained as a dead-code switch arm.
```

**Location 3: the suppression bullet at line 164.**

The existing copy is accurate and stays as-is:

```markdown
- Live chunk enqueue keeps a conservative guard: when recent system energy strongly dominates processed mic energy for a short freshness window, mic chunks are skipped for live transcription only. Mic audio is still written to disk and included in final mix/output.
```

Do not change this line. It correctly describes `shouldSuppressMicrophoneChunkTranscription`.

Keep all other surrounding context (section headers, unrelated bullets, Storage section, Flow diagram) intact.

### Step 7 — Build and run the test suite

```bash
swift build
swift test
```

Expected: everything passes. The core library and dictation/meeting test suites should all go green. If any unrelated test fails, that is an independent bug — do not try to fix it in this PR, leave a note in the commit message.

If `MeetingAudioCaptureServiceTests` or `MeetingRecordingServiceTests` fail, check that the test assertion updates in step 3 are correct and complete.

### Step 8 — Manual verification

This is the critical validation step. The unit tests cannot catch VPIO/HAL issues because they use mocks. Only real audio hardware can prove the fix.

**Precondition**: build and launch the dev app via `scripts/dev/run_app.sh`. Have Safari open with a video ready to play (any video with clear speech — a YouTube interview works well).

**Test 1 — Dictation alone (baseline sanity)**
1. Trigger dictation via fnfn hotkey.
2. Speak a short phrase: "This is a dictation test."
3. Release/stop dictation.
4. **Expected**: The phrase is transcribed and pasted into the focused app.
5. **Check logs**: `mic_started` line present; no `mic_no_buffers_2s` warning.

**Test 2 — Meeting alone (the primary failure mode)**
1. Start playing Safari video at normal volume on laptop speakers.
2. Open the meeting recording panel.
3. Start meeting recording.
4. Let it record for 30 seconds while the Safari video plays.
5. Stop meeting recording.
6. **Expected**:
   - Meeting is saved with a transcript.
   - Both mic and system streams produced real audio (check `~/Library/Application Support/MacParakeet/meeting-recordings/<uuid>/` for `microphone.m4a` and `system.m4a`, both should be much larger than 557 bytes — at least tens of KB each).
   - Transcript contains the Safari video's speech, attributed to the system source.
7. **Check logs**: `tap_started` and `mic_started` both present; neither `tap_no_buffers_2s` nor `mic_no_buffers_2s` warning.

**Test 3 — Meeting → dictation**
1. Immediately after stopping the meeting in test 2, trigger dictation via fnfn.
2. Speak: "Dictation after meeting."
3. Release.
4. **Expected**: Phrase transcribed and pasted. No stale-aggregate silence.
5. **Check logs**: `mic_started` line shows the real hardware input device UID, not a `CADefaultDeviceAggregate-*` UID.

**Test 4 — Dictation → meeting (reverse order)**
1. Trigger dictation, speak a phrase, release.
2. Start a new meeting recording.
3. Play Safari video for 30s.
4. Stop meeting.
5. **Expected**: Meeting captures both streams cleanly.

**Test 5 — Concurrent dictation during active meeting (the hard requirement from ADR-015)**
1. Start a new meeting recording.
2. Let it run for 30 seconds with Safari audio playing.
3. **While the meeting is still recording**, trigger dictation via fnfn.
4. Speak: "This is a dictation command during an active meeting."
5. Release dictation.
6. Let the meeting run for another 30 seconds with Safari still playing.
7. Stop the meeting.
8. **Expected**:
   - The meeting's `system.m4a` has unbroken audio for the full ~60+ seconds (no silent gap during the dictation segment).
   - The meeting's `microphone.m4a` has the user's voice throughout (including during the dictation moment — the mic was always live).
   - The dictation record is saved separately with its own transcribed text.
   - The meeting transcript shows the far-end speech correctly attributed to the system source.
   - The dictation text was pasted into the focused app.

**If all five tests pass**: proceed to step 9.

**If any test fails**:
- Check the diagnostic logs from step 5 for `*_no_buffers_2s` warnings and the actual device IDs/UIDs that were selected.
- If `tap_no_buffers_2s` fires, something is still poisoning the tap. Verify VPIO is actually off (grep logs for `meeting_mic_processing mode=vpio`) and that no other path is calling `setVoiceProcessingEnabled(true)`.
- If `mic_no_buffers_2s` fires, a stale aggregate is likely still being picked up. Investigate `CADefaultDeviceAggregate-*` presence with `AudioObjectID` enumeration.
- Report the failing test, the log output, and the file sizes back to the user. Do not attempt speculative fixes without context.

### Step 9 — Check for echo bleed in test 5's transcript

Open the meeting record from test 5 in the app's meeting panel. Inspect the transcript for far-end content attributed to "Me" (the mic source).

**Acceptance criteria:**
- Ideal: zero or near-zero far-end content attributed to Me. The existing `shouldSuppressMicrophoneChunkTranscription` logic successfully gated the mic during Safari playback.
- Acceptable: minor amounts of garbled partial words attributed to Me, but nothing sentence-length or semantically meaningful. This is tunable in a follow-up.
- Not acceptable: full far-end sentences attributed to Me. This means the suppression logic is either bypassed or its thresholds are too permissive. Report this back to the user with transcript samples; do NOT attempt to tune thresholds in this PR.

### Step 10 — Commit

Use the rich commit format from `docs/commit-guidelines.md`. Follow the commit guidelines precisely (what changed, root intent, prompt that would produce this diff, ADRs applied, files changed).

Key points to include in the commit message:
- What changed: VPIO defaults flipped to `.raw`, tap/mic start order restored, test assertions updated, diagnostic logging added, audio pipeline spec updated.
- Root intent: restore concurrent dictation + meeting recording (ADR-015) by removing VPIO-induced HAL contamination of Core Audio process taps.
- Link to `docs/research/vpio-process-tap-conflict.md`.
- List the five manual tests performed and their outcomes.
- Note the follow-ups that are explicitly out of scope (route changes, self-capture exclusion, BT HFP, clock drift, WebRTC AEC3, etc.) — they are tracked in the research doc's "Follow-up work" section.
- ADRs applied: ADR-014 (meeting recording), ADR-015 (concurrent dictation + meeting).

**Staging**: add the specific edited files by name. Do not `git add -A`. The staged set should be:
- `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift`
- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`
- `Sources/MacParakeetCore/Audio/SystemAudioTap.swift`
- `Sources/MacParakeetCore/Services/MeetingRecordingService.swift` (only if step 4 audit required changes)
- `Tests/MacParakeetTests/Audio/MeetingAudioCaptureServiceTests.swift`
- `Tests/MacParakeetTests/Services/MeetingRecordingServiceTests.swift`
- `spec/05-audio-pipeline.md`
- `docs/research/vpio-process-tap-conflict.md` (already written by the prior session)
- `plans/active/2026-04-drop-vpio-meeting-recording.md` (this plan)

**Do NOT commit**:
- Any unrelated files, even if they show up in `git status`.
- Hook-skipping flags (`--no-verify`, `--no-gpg-sign`).

### Step 11 — Archive the plan

Move `plans/active/2026-04-drop-vpio-meeting-recording.md` to `plans/completed/2026-04-drop-vpio-meeting-recording.md`. Update its header status from `ACTIVE` to `COMPLETED` and add an implementation commit SHA reference.

This plan archival should be a follow-up commit (the implementation commit from step 10 stays clean). Alternatively, squash the archive into the implementation commit if the project convention allows — check recent completed plans for the pattern. Looking at `plans/completed/2026-04-meeting-mic-aec.md`, the status/implementation commit references go in the front matter, so archival-with-references can be done in a single commit.

### Step 12 — Update traceability and documentation

- `spec/kernel/traceability.md` — if any requirement IDs changed (ADR-014 / ADR-015 acceptance criteria for concurrent dictation), update the mappings.
- `README.md` test count — unchanged (this PR does not add or remove tests, only updates assertions).
- `CLAUDE.md` test count — unchanged.

## Verification checklist (final)

- [ ] `swift build` succeeds
- [ ] `swift test` passes (no new failures)
- [ ] Grep `= \.vpioPreferred` in `Sources/` returns **zero matches** (all 5 production defaults flipped)
- [ ] Grep `\.vpioPreferred` in `Sources/` shows only the enum definition, the `case .vpioPreferred:` switch arm, and logging strings (dead-code fallback retained)
- [ ] Grep `setVoiceProcessingEnabled` in `Sources/` shows only the single call site in `MicrophoneCapture.setVoiceProcessing` — unchanged, now unreachable on the default path
- [ ] `MeetingAudioCaptureService.start(handler:)` starts mic before tap (no lingering reorder comment)
- [ ] `SystemAudioTap` logs `tap_started` at start and `tap_first_buffer_received` on first buffer; `tap_no_buffers_2s` never fires in any of the manual tests
- [ ] `MicrophoneCapture` logs `mic_started` at start and `mic_first_buffer_received` on first buffer; `mic_no_buffers_2s` never fires in any of the manual tests
- [ ] Manual test 1 (dictation alone) passes
- [ ] Manual test 2 (meeting alone) passes — both `microphone.m4a` and `system.m4a` contain real audio, each much larger than 557 bytes
- [ ] Manual test 3 (meeting → dictation) passes — dictation's `mic_started` line shows the real built-in microphone, not a `CADefaultDeviceAggregate-*` device
- [ ] Manual test 4 (dictation → meeting) passes
- [ ] Manual test 5 (concurrent dictation during active meeting) passes — the hard ADR-015 requirement. Meeting's `system.m4a` has unbroken audio across the full session, no silent gap during the dictation trigger, dictation captured separately
- [ ] Test 5 transcript has no or only minor mic-attributed far-end content (see step 9 acceptance criteria)
- [ ] Commit message follows `docs/commit-guidelines.md` format
- [ ] Plan archived to `plans/completed/` with implementation SHA referenced in header

## Rollback

If any step causes unresolvable problems:

- Steps 1–3 (default flips + test updates): `git checkout` the four source files and two test files. System returns to the broken-but-known VPIO-first state. No HAL mutations to clean up (code changes only).
- Step 4 (audit): read-only unless a bypass is found. If a rewire turned out to be wrong, `git checkout MeetingRecordingService.swift`.
- Step 5 (diagnostic logging): additive-only. Can be kept even if other steps are reverted.
- Step 6 (spec update): `git checkout spec/05-audio-pipeline.md`.

There is no runtime state to clean up — this PR is purely source-code changes. The only "rollback" that requires user action is quitting the app to clear any stale HAL aggregate devices from prior VPIO-enabled sessions.

## Notes for the implementing agent

- **Read `docs/research/vpio-process-tap-conflict.md` first.** It has the full mechanism explanation, citations, alternatives considered, and Codex's independent review. This plan is the execution script; the research doc is the reasoning.
- **Do not re-investigate VPIO feasibility.** The research already concluded VPIO is architecturally incompatible with in-process Core Audio taps. Any new research instinct should be redirected to the follow-up items in the research doc's "Follow-up work" section.
- **Do not rip out the `MeetingMicProcessingMode` enum or VPIO code paths.** Leaving them as dead code is intentional for reversibility and to keep this PR small.
- **Do not add features.** No thresholds tuning, no new UI, no new telemetry events beyond the diagnostic logging specified in step 5. A bug fix does not need surrounding cleanup.
- **Do not skip the manual tests.** Unit tests cannot catch VPIO/HAL issues because they use mocks. The entire point of this plan is validated by step 8.
- **Do not claim success without running the manual tests.** If the manual tests cannot be run (e.g., no dev machine available), stop at step 7 and report back.
- **If step 4's audit reveals the suppression logic is bypassed**, keep the rewire minimal. Match the call-site pattern from commit `118d7e6f` (the last known-working architecture). Do not refactor `MeetingRecordingService` beyond what is necessary to make the suppression path run on raw-mode chunks.
- **Line numbers in this plan are approximate** and based on grep output from 2026-04-11. If the files have been touched since, use grep to re-locate the exact lines.
