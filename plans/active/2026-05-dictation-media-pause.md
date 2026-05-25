# Dictation Media Pause

Status: **ACTIVE**
Owner: Core app team
Updated: 2026-05-24
Related: [GitHub issue #351](https://github.com/moona3k/macparakeet/issues/351)

## Decision

MacParakeet should support an opt-in dictation setting:

```text
Pause media while dictating
```

When enabled, MacParakeet pauses currently playing media as dictation capture
starts, then resumes only the media session it paused after dictation exits
capture. This should ship as a state-aware media-control feature, not as a
blind play/pause toggle.

## Product Rule

1. Apply only to dictation capture: push-to-talk, hands-free, and idle-pill
   dictation starts.
2. Do not apply to meeting recording, file transcription, YouTube
   transcription, Transforms, or in-app transcript playback.
3. If meeting recording is already active, skip media pause for dictation so a
   user does not accidentally pause the meeting source.
4. Pause only when a playable media session is actually playing.
5. Resume only when MacParakeet successfully paused that session.
6. Never send a "play" command if no media was paused by MacParakeet.
7. Failure must be silent and non-blocking: dictation should continue even if
   media state cannot be detected or controlled.

## Rationale

Issue #351 is high-signal feedback from a sponsor and heavy dictation user. The
request is simple from the user's perspective: background audio competes with
their voice, especially during push-to-talk dictation. Superwhisper exposes
both "Mute Audio While Recording" and "Pause Media While Recording", and its
changelog shows media pause has been treated as a default-quality dictation
behavior.

The risk is macOS implementation shape. A raw global play/pause media-key event
is unsafe because it can start playback when nothing was playing, or resume
something the user paused manually. The feature is only worth shipping if
MacParakeet can track whether it actually paused media and resume only that
state.

## Architecture Shape

Add a small app/system adapter and keep dictation flow ownership in
`DictationFlowCoordinator`.

```text
SettingsViewModel
    |
    v
DictationFlowCoordinator
    |
    v
DictationMediaPauseCoordinator
    |
    v
SystemMediaController
```

`SystemMediaController` is the platform boundary. It should expose a narrow
protocol such as:

```swift
protocol SystemMediaControlling: Sendable {
    func pauseIfPlaying() async -> MediaPauseToken?
    func resume(_ token: MediaPauseToken) async
}
```

The returned token is the guardrail: no token means no resume. The token should
represent the specific session MacParakeet paused, not just "we sent a pause
key once".

## Spike Gate

Before wiring UI, do a short implementation spike that answers one question:

Can the app reliably determine a global media session is playing and issue
separate pause/resume commands without private, brittle, or toggle-only
behavior?

Acceptable outcomes:

- **Green:** state-aware pause/resume works for common Now Playing sources
  such as Safari/YouTube, Music, Spotify, and Podcasts without starting stopped
  media.
- **Yellow:** state-aware pause/resume works only through private MediaRemote or
  equivalent dynamic lookup. Keep the feature opt-in, isolate the adapter, and
  document the risk before shipping.
- **Red:** only a toggle media-key path works. Do not ship; leave the plan open
  and consider "lower system volume while dictating" as a separate feature.

### Spike Result: 2026-05-24

Result: **Yellow**.

Local dynamic lookup succeeded for the MediaRemote symbols needed by the
state-aware path:

- `MRMediaRemoteGetNowPlayingApplicationIsPlaying`
- `MRMediaRemoteGetNowPlayingApplicationPID`
- `MRMediaRemoteSendCommand`

The initial no-media probe returned `playing=false`, so the app can avoid the
unsafe "always toggle play/pause" behavior. The implementation therefore uses a
private MediaRemote adapter behind `SystemMediaControlling`, with the setting
off by default, private symbols loaded lazily on first actual media-control
attempt, and all failures treated as silent no-ops.

Public Apple APIs were not sufficient for this exact feature:

- `MPNowPlayingInfoCenter` is for setting Now Playing information for media the
  current app plays.
- `MPRemoteCommandCenter` is for registering the current app's handlers for
  system/external playback commands.
- `CGEvent`/media-key synthesis can produce input events, but cannot safely
  prove whether a global media session was playing or whether MacParakeet owns
  the resume.

Open-source macOS tools converge on the same private MediaRemote boundary:

- `nowplaying-cli` uses MediaRemote for now-playing metadata and media commands
  and explicitly warns that private frameworks may break across macOS updates.
- `fastfetch` uses MediaRemote for macOS media detection and carries special
  handling around macOS 15.4+ now-playing behavior.
- Reversed MediaRemote headers define `kMRPlay = 0`, `kMRPause = 1`,
  `MRMediaRemoteSendCommand`, `MRMediaRemoteGetNowPlayingApplicationPID`, and
  `MRMediaRemoteGetNowPlayingApplicationIsPlaying`; MacParakeet hard-codes only
  the minimal command constants behind the adapter.

## Implementation Plan

### Phase 1: Preference and UI

- Add `pauseMediaDuringDictationKey` to `UserDefaultsAppRuntimePreferences`.
- Add `pauseMediaDuringDictation` to `AppRuntimePreferencesProtocol` and
  `SettingsViewModel`.
- Add a toggle in the Dictation settings card near "Auto-stop after silence".
- Add a telemetry-safe `TelemetrySettingName.pauseMediaDuringDictation` setting
  changed event. Do not log app names, track names, URLs, titles, or media
  source identifiers.

### Phase 2: Media Adapter

- Add `SystemMediaControlling` and `MediaPauseToken`.
- Prefer a state-aware controller that can distinguish `playing`, `paused`,
  `stopped`, and `unknown`.
- Dynamically load any non-SDK/private symbols if the spike proves they are
  required, and keep that code behind the protocol boundary.
- Add structured OSLog lines for local debugging:
  - `media_pause_skipped reason=disabled`
  - `media_pause_skipped reason=meeting_active`
  - `media_pause_skipped reason=no_playing_session`
  - `media_pause_skipped reason=session_identity_unavailable`
  - `media_pause_sent source=now_playing`
  - `media_resume_sent source=now_playing`
  - `media_pause_failed bucket=...`
  - `media_resume_failed bucket=...`

### Phase 3: Dictation Flow Wiring

- Inject a `DictationMediaPauseCoordinating` dependency into
  `DictationFlowCoordinator`.
- Arm media pause only after entitlements pass and immediately before dictation
  capture starts.
- Release/resume media when the flow leaves capture:
  - normal stop into processing
  - no-speech/error completion
  - cancel countdown
  - discard
  - start failure after a pause was already sent
  - rapid restart
  - app quit while capture is active
- Keep resume idempotent. Multiple terminal paths may race; only the first
  valid token should resume.

### Phase 4: Tests and Manual Smoke

- Unit-test preference persistence in `SettingsViewModelTests`.
- Unit-test pure media coordinator token behavior:
  - disabled setting does nothing
  - meeting-active guard skips
  - pause returns no token when no media is playing
  - resume is called only after a successful pause
  - double release resumes once
- Extend `DictationFlowStateMachineTests` only if new effects are added. If the
  media coordinator is driven directly from `DictationFlowCoordinator`, keep the
  pure state machine unchanged.
- Add coordinator tests around start/stop/cancel/discard/start-failure paths
  using a fake media controller.
- Manual smoke on a dev app:
  - Safari YouTube playing -> hold push-to-talk -> video pauses -> release ->
    video resumes after capture exits.
  - Media already paused -> dictation does not start playback afterward.
  - Meeting recording active + media playing -> dictation does not pause media.
  - User manually resumes media during dictation -> MacParakeet does not fight
    the user on stop.

## Acceptance Criteria

- The setting is off by default.
- Dictation still starts if media control fails.
- Media never starts if it was not playing before dictation.
- Media resumes only when MacParakeet paused it.
- Meeting recording is protected from accidental pause/resume.
- No media metadata enters telemetry.
- `swift test` passes.
- A local dev-app smoke validates at least Safari/YouTube plus one native media
  app before release.

## Non-Goals

- Per-app media rules.
- Volume ducking/muting.
- Capturing system audio during dictation.
- Applying this behavior to meeting recording.
- Logging media title, URL, artist, source app, or Now Playing metadata.

## References

- GitHub issue #351: media pause/resume during push-to-talk dictation.
- Superwhisper Modes docs: "Pause Media While Recording".
- Superwhisper changelog: media pause became a default mode behavior.
- Apple `MPNowPlayingInfoCenter`: <https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter>
- Apple `MPRemoteCommandCenter`: <https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter>
- Apple `CGEvent`: <https://developer.apple.com/documentation/coregraphics/cgevent>
- Apple `NSEvent.SpecialKey`: <https://developer.apple.com/documentation/appkit/nsevent/specialkey>
- `nowplaying-cli`: <https://github.com/kirtan-shah/nowplaying-cli>
- `fastfetch` macOS media detection:
  <https://github.com/fastfetch-cli/fastfetch/blob/dev/src/detection/media/media_apple.m>
- Reversed MediaRemote header:
  <https://github.com/Cykey/ios-reversed-headers/blob/master/MediaRemote/MediaRemote.h>
