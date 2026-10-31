# System Services

> Thin wrappers around macOS system surfaces: permissions, clipboard,
> accessibility selection, paste replacement, focused-app context, media
> control, and launch-at-login.

## Entry Point

Use the protocol for the surface you need and inject the concrete service from
the app environment. These services touch AppKit, Accessibility, CoreGraphics,
or other process-global macOS APIs; keep call sites explicit so tests can
replace them with mocks.

## What Is Here

- `PermissionService.swift` -- microphone, screen recording, and Accessibility
  checks/prompts/settings links.
- `ClipboardService.swift` -- pasteboard writes and restore behavior.
- `AppGeneratedKeyboardEvents.swift` -- marked application keyboard output at
  the session entry point, downstream of HID key state (#1286).
- `StreamingCursorScheduler.swift` / `StreamingCursorInserter.swift` -- optional default-off dictation caret stream (#449); paste remains the default path.
- `EventTapTeardown.swift` -- shared CGEvent tap teardown; always invalidates the Mach port (#1132).
- `BackgroundEventTap.swift` -- `EventTapThread` and `BackgroundEventTap`: every CGEvent tap runs on one dedicated thread, never the main run loop (#1142).
- `AccessibilityService.swift` -- selected-text reads through Accessibility
  attributes, parameterized strings, or a selected range in the full value.
- `SelectionCaptureService.swift` and `SelectionReplacementService.swift` --
  Accessibility-backed capture/replacement with clipboard fallback and restoration.
- `FrontmostApplicationProvider.swift` -- injectable frontmost-app metadata for
  meeting start context.
- `FocusedAppContextService.swift` -- frontmost app metadata for contextual
  transforms.
- `SystemMediaController.swift` -- media pause/resume bridge used before
  dictation capture.
- `LaunchAtLoginService.swift` -- launch-at-login integration.

## What To Know Before Editing

**Services are instance-owned and protocol-backed.** `PermissionService` is not
a singleton and has no `.shared`. Depend on `PermissionServiceProtocol` and
construct/inject a concrete `PermissionService` from the app layer or a mock
from tests.

**Permission prompts are user-visible product surfaces.** Screen recording,
microphone, and Accessibility flows affect onboarding, Settings, dictation, and
meeting capture. Update the governing UI/spec docs and tests when prompt
timing, copy, or recovery behavior changes.

**Do not hide ordered work in detached tasks.** If a caller needs the result,
error, or ordering of a system operation, make the path async and await it.
Fire-and-forget tasks are only appropriate for deliberately detached cleanup,
best-effort telemetry, or UI effects whose cancellation is harmless.

**Event taps never run on the main run loop.** macOS holds each keyboard event
until a filtering tap returns, so a tap on the UI thread turns any UI stall into
system-wide typing lag (#1142). Create taps with `BackgroundEventTap`; its
handler runs on `EventTapThread`. That thread must never wait on the main
thread: post UI work asynchronously. `stop()` returns only after callbacks have
ended, so release callback state after it.

**Keep `@MainActor` work short.** AppKit and Accessibility entry points often
start on the main actor, but long-running I/O, process execution, model work,
and waits should move off the actor and publish results back to UI state.

**Keep generated keyboard output out of HID state.** Use
`AppGeneratedKeyboardEvents` for source/event construction and its session
posting location. Changing only the source state ID does not isolate HID state
when posting at the HID entry point. Preserve Command-layout resolution and
allocate both events before posting either. Hotkey listeners ignore our marker
before swallowing or gesture bookkeeping; an own key-up is not physical release
evidence. `StreamingCursorEventMarker` remains a compatibility alias. Mouse and
explicit per-process routing are separate surfaces.

Streaming interruption also replays at the session entry point, alongside the
flushed text. Preserve the original input's metadata without applying our
marker: moving an intercepted session event upstream would contaminate HID.
If the interrupt flush fails, release the user's input promptly and stop this
insertion permanently. Do not retry after the input may have moved the cursor
or focus. For a non-cancelled insertion, report `partialInsert` even with no
committed text so the coordinator offers clipboard recovery without automatic
paste. Cancellation retains its quiet return; the caller suppresses success,
recovery, and post-insert actions, and the stopped flush is never retried.

Bare-Fn admission reads HID keys; custom-trigger and peer recovery retain
session semantics. Older app versions or other software can still leave HID
state stale. Preserve observed-release recovery rather than manufacturing a
release or expiring genuinely held keys. The CI Quartz probe establishes the
synthetic state distinction; physical input and Jump Desktop require native
acceptance.

## How To Verify A Change

- Permission/onboarding behavior: `swift test --filter OnboardingViewModelTests`
  plus the relevant dictation or meeting flow tests.
- Selection/Transform behavior: `swift test --filter TransformExecutorTests`
  and `swift test --filter TransformsHotkeyRegistryTests`.
- Clipboard/paste behavior: run the focused service/view-model test that owns
  the edited call path, then `swift test` for broad coverage before merging a
  behavior change.
