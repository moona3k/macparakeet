# Issue #1033: AirPods disconnect comparison

## Verdict

Potentially the same Bluetooth lifecycle problem area, but **not a demonstrated duplicate of #1032 and not proved fixed by the silence correction**. There is no diagnostic attachment on [#1033](https://github.com/moona3k/macparakeet/issues/1033) as inspected on 2026-09-14. The owner has acknowledged the report and plans physical AirPods testing. No reporter contact or issue mutation was performed by this investigation.

Both reports use v0.8.0 build `20260909173236`, commit `1cc48e726ad4`, `dist-xcodebuild-release`. #1033 is M1 Pro/macOS 26.4.1; #1032 is M2 Pro/macOS 26.6.2. Shared release provenance is useful, but does not establish a shared trigger. #1033 does not say whether capture was active, whether a named input or System Default was selected, which UI showed the failure, or whether a new recording/relaunch recovers.

## Code-grounded distinctions

| Situation | Existing behavior and remaining boundary |
|---|---|
| Named AirPods input disappears before a new start | `AppEnvironment` resolves persisted UIDs afresh; `meetingInputDeviceAttempts` skips a missing selected device and retains implicit System Default plus a distinct built-in fallback. A stale Settings list does not itself control this route resolution. |
| Disconnect stops the engine or stops/invalidates callbacks during capture | Shared-source bounded recovery rebuilds route/format and can use fallback input. The #1032 correction preserves this recovery. |
| Disconnect leaves a running graph producing valid zeros | Silence alone no longer triggers recovery. A default-input notification only refreshes policy and reschedules an already-pending retry; it does not independently prove the active endpoint vanished. There is no independent endpoint-disappearance recovery in this path. This is a conditional gap for hardware testing, not proof of the reporter's cause. |
| Recovery exhausts | Current subscriptions become interrupted and route listeners are retired. Device return does not revive those subscriptions automatically. A fresh subscription can start a new engine; no permanent app-wide microphone-disabled latch was found. |
| Disconnect while idle | Bluetooth prewarming is suppressed, and subsequent starts resolve the route again. A changed prepared route is discarded. This report does not establish stale prepared capture. |

Evidence locations at investigated base `d67cf93e` and the local #1032 patch:

- `Sources/MacParakeet/App/AppEnvironment.swift`: `attemptsBuilder`.
- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`: `meetingInputDeviceAttempts`.
- `Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift`: `prepare`, `recoverFromConfigurationChangeLocked`, `checkCallbackLivenessLocked`, `installRouteChangeObserversLocked`, `exhaustRecoveryLocked`.
- `Sources/MacParakeetCore/Audio/SharedMicrophoneStream.swift`: terminal platform-stop handling and fresh-subscription startup.
- `Sources/MacParakeetViewModels/SettingsViewModel.swift`: `refreshMicrophoneDevices`, `testSelectedMicrophone`.

The shipped-to-current changes include #1010's one fresh implicit Bluetooth startup retry and native lifecycle instrumentation. That retry applies only to an implicit attempt resolved as Bluetooth that times out. It is not a general AirPods-unplug fix, particularly after System Default has already changed to built-in.

## Next evidence to collect

Ask for an opt-in diagnostic captured from before disconnect through one failed recording and one attempted restart. No recording audio or transcript is needed. Record:

1. Active meeting, active dictation, or idle at disconnect; selected named input versus System Default.
2. Exact error and surface: missing dropdown device, Settings Test Input failure, failed dictation, or an interrupted meeting source.
3. Whether macOS Sound settings still show a working built-in mic at that moment.
4. Whether Stop/new capture, explicitly choosing built-in, or app relaunch restores capture.
5. AirPods model and disconnect action (case closure, Bluetooth disconnect, removal from ears, or out of range), with timestamps.

Existing route/start/recovery logs plus the new pre-filter counters can distinguish native setup failure, first-buffer timeout, callback cessation, empty/invalid input, and continuing valid silence. They cannot determine that the selected endpoint disappeared merely from PCM. If hardware reproduction reaches the running-zeros case, add a bounded off-render route-presence/default-route snapshot and base any recovery on verified route loss, not an amplitude timeout.

## Verification matrix

- Run an active mic-plus-system meeting and concurrent dictation subscriber; disconnect AirPods, verify continued built-in mic frame delivery and intact subscriptions when bounded recovery succeeds.
- Disconnect while idle, then start dictation immediately and after the route settles; repeat with System Default and named AirPods selection.
- Exhaust recovery, then restore a usable route: verify old capture stays explicitly interrupted and a fresh capture succeeds. Do not silently resurrect a user-stopped session.
- Include speaker/mic mute and prolonged quiet controls. They must not cause teardown.
- Distinguish native stopped graph, missing callbacks, empty buffers, and valid zeros. Synthetic route/state tests cannot prove physical AirPods handoff.

The current 112 focused audio tests cover route fallback, source recovery, Stop, shared subscriptions, and the #1032 silence policy. No physical AirPods disconnect was performed, and no new #1033-specific implementation is claimed.
