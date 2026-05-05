# Issue 224: Meeting Recording Stops After ScreenCaptureKit Loses Capture Source

GitHub issue: https://github.com/moona3k/macparakeet/issues/224

## What We Know

The reporter confirmed that the app did not crash. The meeting recording UI
closed, and the orange recording indicator stopped.

Their `dictation-audio.log` shows repeated mid-recording failures from
ScreenCaptureKit:

```text
system_audio_stream_stopped_with_error
error_type=com.apple.ScreenCaptureKit.SCStreamErrorDomain.-3815
error_detail="Failed to find any displays or windows to capture"
```

In the macOS SDK, `-3815` is `SCStreamErrorNoCaptureSource`: ScreenCaptureKit
could not find a display or window to capture. This happened after recording
had already started and system audio buffers had already arrived.

## Current Behavior

Any system-audio stream failure is treated as a whole-recording failure.

```text
ScreenCaptureKit system audio stops
        |
        v
SystemAudioStream emits runtime error
        |
        v
MeetingAudioCaptureService forwards .error
        |
        v
MeetingRecordingService marks capture failed
        |
        v
Mic + system capture stop
        |
        v
UI closes and saved audio is finalized
```

That explains the user-visible behavior: no app crash, but the live recording
session ends.

## Likely Triggers

The log does not prove the external trigger. Plausible triggers include:

- display sleep or screen lock
- external display disconnect/reconnect
- KVM or dock display switching
- Sidecar, AirPlay, DisplayLink, or virtual displays
- moving the meeting app across Spaces or full-screen display contexts
- a macOS 26.4.1 ScreenCaptureKit regression

The important product point: losing system audio should not necessarily end a
meeting if the microphone is still recording.

## Preferred Handling

For `Microphone + System Audio`, a system-audio interruption should degrade the
session to mic-only instead of ending the meeting.

```text
ScreenCaptureKit system audio stops
        |
        v
System source marked unavailable
        |
        +--> system level goes to 0
        +--> warning is logged / telemetry is sent
        +--> mic capture continues
        |
        v
Final meeting contains mic audio plus any system audio captured before failure
```

For `System Audio Only`, the current stop/fail behavior is still reasonable
because no recording source remains.

## Open Decisions

- Should the first fix only preserve mic recording, or also try to restart
  ScreenCaptureKit after display topology changes?
- How should the UI communicate "system audio stopped, mic recording continues"
  without alarming the user mid-meeting?
- Should final metadata explicitly record source interruptions so Library export
  and debugging can explain partial system audio?

## Draft PR Scope

This draft PR is an investigation and decision point, not a finished runtime
fix. A proper implementation PR should add tests for:

- system-audio failure during `Microphone + System Audio` keeps mic recording
  alive
- system-audio failure during `System Audio Only` still stops/fails
- final output preserves any source audio already captured before interruption
