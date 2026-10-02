# Meeting URL control v1

Status: ACTIVE in development; availability in installed builds depends on the
release containing this change. Added for issue #1198.

## Purpose and ownership

Let Shortcuts, launchers, and local scripts control the GUI app's meeting
recorder, including its title at creation. `AppDelegate` receives macOS URL
open events; `MeetingURLCommand` validates them and `MeetingURLCommandRouter`
holds cold-launch requests until environment setup finishes. The existing
`MeetingRecordingFlowCoordinator` owns permissions, capture, and saving.
The CLI continues to inspect saved meetings; it does not capture audio.

## Consent and privacy

Settings → Capture → Meetings → **Allow recording control from links** is off
by default. The `meetingURLControlEnabled` preference must be explicitly true.
Any app or website can send a custom URL; this is a global opt-in, not caller
authentication or a per-site allowlist. Disable the switch to revoke control.
Disabled requests are ignored and never replayed after enabling the switch.
Queued requests recheck consent at dispatch. Onboarding and quit dialogs block
dispatch; requests received during those flows are not replayed later.

Normal macOS microphone and system audio permissions still apply. Starting
opens the existing live meeting panel when capture is ready. Audio-source,
muted-start, local STT, and enabled post-recording processing preferences remain
unchanged. No raw URL or supplied title is logged or sent to telemetry by this
surface. The title is ordinary local meeting metadata. A title in an automation
or shell command may also be retained by that caller.

## Stable URL grammar

| URL | Action |
| --- | --- |
| `macparakeet://meeting/start` | Start with the normal date-based title. |
| `macparakeet://meeting/start?title=Weekly%20Planning` | Start with the supplied title. |
| `macparakeet://meeting/stop` | Stop and save through normal background transcription. |
| `macparakeet://meeting/pause` | Pause an active recording. |
| `macparakeet://meeting/resume` | Resume a paused recording. |

The scheme and host are case-insensitive. Paths and query names are exact and
case-sensitive. Only `start` accepts a query, with at most one `title` value.
Percent-encode reserved characters and spaces; `+` is a literal plus, not a
space. Titles are decoded once, trimmed, limited to 500 Swift Characters, and
must not contain internal control characters. Empty/whitespace titles use the
normal fallback. URLs over 8,192 UTF-8 bytes, unknown paths/parameters,
duplicate titles, credentials, ports, and fragments are rejected in full.
Malformed requests are ignored without echoing their contents.

Development bundles register only `macparakeet-dev://` and accept only that
scheme. Distribution bundles register `macparakeet://`.

## Lifecycle semantics

- `start` is a no-op unless the recorder is idle. Repeated starts never stop
  or rename an existing recording; a title only applies to a newly accepted start.
- `stop` cancels a start still checking permissions. Once capture is starting
  or active, it uses normal stop/save behavior, including when paused. It never
  discards an existing recording. It is a no-op when idle or already stopping.
- `pause` and `resume` apply only after capture is active. They are no-ops
  during startup, stopping, or idle. Repeating the current desired state is
  harmless. Service calls are serialized and guarded by recording generation;
  rapid opposing requests settle to the latest desired state.
- Cold-launch requests wait for environment setup, in arrival order, with a
  maximum of 16 queued commands (excess requests are ignored). Environment
  setup failure discards queued commands. This is not a persistent job queue.
- Opening a URL is fire-and-forget. Successful `open` means macOS delivered a
  request, not that recording started or that transcription finished. The app's
  normal UI and permission/error presentation remain authoritative. No callback,
  status response, completion wait, destructive action, or remote server is added.

## Compatibility and verification

Additive commands require parser/dispatch tests and documentation. Changing the
meaning of an existing URL requires an explicit compatibility decision.
Presentation copy, generated timestamps, internal queue implementation, and
local artifact paths are not stable protocol fields.

`MeetingURLCommandTests` covers grammar, title decoding, scheme isolation,
consent, cold-launch ordering, startup failure, and bounded buffering.
`MeetingRecordingFlowCoordinatorTests` covers title propagation, repeated
starts, pending-start cancellation, pause/resume, and existing saving paths.
`SettingsViewModelTests` covers default-off consent and persistence.
Packaged-app verification must additionally check Launch Services registration
and warm/cold URL delivery; unit tests do not prove OS delivery or real audio.
