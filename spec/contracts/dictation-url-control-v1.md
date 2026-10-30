# Dictation URL control v1

Status: ACTIVE in development; available in builds containing issue #1273's
implementation. This does not promise support in earlier stable releases.

## Purpose and ownership

Stream Deck, Shortcuts, Raycast, Keyboard Maestro, and scripts can control GUI
dictation without synthesizing a global hotkey. The caller does not need
Accessibility permission just to deliver a URL. The app's existing microphone,
entitlement, model, interaction-arbiter, and auto-paste requirements still apply.
The CLI remains a separate headless transcription surface.

`AppDelegate` receives URL events. `DictationURLCommand` validates and selects
an action from the current flow state; `DictationURLCommandRouter` buffers
cold-launch deliveries. `DictationFlowCoordinator` uses its normal persistent
(hands-free) start and stop paths. No new capture or insertion engine is added.

## Consent and privacy

Settings → Capture → Dictation → **Allow dictation control from links** is off
by default (`dictationURLControlEnabled`). Meeting URL consent does not enable
it. This is global consent: any app or website can send these commands while
it is enabled. There is no caller authentication or per-app allowlist.

Consent is checked at receipt and before each dispatch. Disabled requests are
ignored; queued requests are discarded if consent is off when setup finishes.
Onboarding and quit flows block dispatch without replay. Disabling control
does not cancel a dictation already started; the pill and shortcuts still work.

No URL, caller identity, or query contents are logged or sent to telemetry.
Normal optional dictation telemetry uses the bounded `trigger=url_control`
value for URL-started takes. Existing audio, history, formatter, clipboard,
and retention preferences apply without change.

## Grammar

| URL | Action |
| --- | --- |
| `macparakeet://dictation/start` | Start hands-free dictation when idle or showing the ready pill. |
| `macparakeet://dictation/stop` | Stop an active or starting take through the normal flow. |
| `macparakeet://dictation/toggle` | Start when idle/ready; stop when starting/recording. |

Scheme and host are case-insensitive; paths are exact and case-sensitive.
Reject unknown paths, encoded path aliases, trailing slashes, all queries
(including empty queries), fragments, credentials, ports, and URLs over 8,192
UTF-8 bytes. Rejection is silent and does not echo the URL. Development bundles
accept only `macparakeet-dev://`; distribution bundles use `macparakeet://`.
Existing bundle registration already owns these schemes.

## Lifecycle

- Repeated `start` never replaces, cancels, or stops a take. It is a no-op
  during entitlement checks, microphone/service startup, recording, pending
  stop, transcription/formatting, undo countdown, or result display/paste.
- `stop` during entitlement or microphone permission checks cancels the pending
  start, even if permission is later granted. During service startup it records
  a pending stop; if
  startup succeeds, normal stop/transcription follows. During capture it
  transcribes and inserts normally. It is a no-op in every other state.
- `toggle` has the same start/stop semantics above. It is a no-op during
  pending stop, processing, undo countdown, and result display/paste. Toggle
  is intentionally not idempotent; use explicit start/stop for retrying callers.
- Busy requests are not queued for a future take. Retry only after the prior
  flow has returned to idle. URL commands can stop a take started by a hotkey
  or the pill, and normal hotkey/pill stop remains available for URL takes.
- Before environment setup completes, at most 16 valid enabled commands are
  retained in arrival order. Excess commands are ignored. Setup failure drops
  pending commands. This is a temporary launch buffer, not a persistent queue.
- Delivery is fire-and-forget: successful `open` does not prove recording,
  transcription, or insertion succeeded. The normal pill and error/permission
  UI remain authoritative; no status response or callback is added.

## Focus and caller examples

Use background URL delivery to avoid activating MacParakeet over the intended
text field:

```sh
open -g 'macparakeet://dictation/start'
open -g 'macparakeet://dictation/stop'
# One button for hands-free start/stop:
open -g 'macparakeet://dictation/toggle'
```

The URL handler does not activate a window or choose a target application.
Foreground activation is controlled by the caller and macOS; ordinary URL
opening can change focus. Complete onboarding/permissions first, keep the
intended text field focused, and configure the automation to open URLs in the
background. If a launcher changes focus, restore the target before dictating
and before stopping. Cold launch and permission dialogs can also change focus.
MacParakeet still needs Accessibility for automatic insertion; the caller does
not. The normal copy fallback and Keep dictation on clipboard remain available.

## Compatibility

Adding commands requires parser/dispatch tests and contract updates. Changing
an existing command's meaning requires an explicit compatibility decision.
Settings copy, queue implementation, generated session IDs, and local artifact
paths are not stable protocol fields.

## Verification

Parser/router tests cover grammar, scheme isolation, consent at receipt and
per-command dispatch, startup failure, bounded buffering, ordering, and no
replay. The state matrix covers every flow state and both recording modes.
Coordinator tests exercise repeated starts, early stop, processing, undo,
pending paste, and interaction exclusion. Settings tests cover independent
opt-in, persistence, and discovery. Packaged Launch Services delivery, native
focus, physical audio, and real Stream Deck/launcher integrations require
separate manual verification; unit tests do not establish those outcomes.
