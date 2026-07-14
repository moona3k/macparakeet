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
- `SelectionCaptureService.swift` and `SelectionReplacementService.swift` --
  Accessibility-backed selected-text capture and replacement.
- `FocusedAppContextService.swift` -- frontmost app metadata for contextual
  transforms.
- `SystemMediaController.swift` -- media pause/resume bridge used before
  dictation capture.
- `LaunchAtLoginService.swift` -- launch-at-login integration.
- `CommandLineToolInstallService.swift` -- `/usr/local/bin/macparakeet-cli`
  symlink status and install/replace flow for the bundled CLI.

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

**Keep `@MainActor` work short.** AppKit and Accessibility entry points often
start on the main actor, but long-running I/O, process execution, model work,
and waits should move off the actor and publish results back to UI state.

## How To Verify A Change

- Permission/onboarding behavior: `swift test --filter OnboardingViewModelTests`
  plus the relevant dictation or meeting flow tests.
- Selection/Transform behavior: `swift test --filter TransformExecutorTests`
  and `swift test --filter TransformsHotkeyRegistryTests`.
- Clipboard/paste behavior: run the focused service/view-model test that owns
  the edited call path, then `swift test` for broad coverage before merging a
  behavior change.
