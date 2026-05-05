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
        +--> warning and diagnostic line are logged
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
- Should final metadata explicitly record source interruptions so Library export
  and debugging can explain partial system audio?

## Follow-Up UX

The live UI should use a subtle warning, not a modal alert:

```text
System audio stopped. Microphone recording continues.

[Send Diagnostic Report]

Sends a redacted audio diagnostic log.
No audio or transcript is included.
```

The report button should reuse the existing feedback path:

```text
Interruption UI
        |
        v
FeedbackService /api/feedback
        |
        v
Server creates GitHub issue with bot account
```

The client should send structured diagnostics to the backend rather than open
GitHub directly. That keeps the user action to one click, avoids exposing logs
in a public issue form, and lets the server decide how to file or route the
report.

Prefer a generous capped log payload over a narrow snippet. The audio
diagnostic log is already designed to be shared: paths and URLs are sanitized,
individual error details are capped, and microphone IDs, UIDs, and names are
omitted. If the payload fits the backend limit, send the current
`dictation-audio.log`; otherwise send a capped recent tail with enough lead-up
context to diagnose display/audio state changes. Include structured context
such as capture mode, interrupted source, ScreenCaptureKit error code, app
version, macOS version, and timestamp. Do not include audio or transcript
content.

## PR Scope

This PR implements the first safety fix: system-audio failure during
`Microphone + System Audio` becomes source-specific, so the microphone keeps
recording. A later PR can decide whether to restart ScreenCaptureKit after
display topology changes.

Coverage should verify:

- system-audio failure during `Microphone + System Audio` keeps mic recording
  alive
- system-audio failure during `System Audio Only` still stops/fails
- final output preserves any source audio already captured before interruption
