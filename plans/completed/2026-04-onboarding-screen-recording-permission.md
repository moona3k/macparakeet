# Onboarding — Screen Recording Permission Step

> Status: **COMPLETED / ARCHIVED** - implementation exists on `main`; this plan is retained for historical context.
> Date: 2026-04-10
> Driving issue: [#66](https://github.com/moona3k/macparakeet/issues/66)
> Related ADRs: `spec/adr/014-meeting-recording.md`, `spec/adr/015-concurrent-dictation-meeting.md`
> Related docs: `spec/02-features.md` (onboarding), `spec/adr/005-onboarding-first-run.md`

## Objective

Add an **optional** Screen & System Audio Recording permission step to the first-run onboarding flow so users who want to use meeting recording grant the permission up front instead of being surprised by a system prompt the first time they click "Record meeting."

Also add a live permission-polling loop during onboarding (and refresh on the matching Settings row) so granting a permission in System Settings reflects back in the app without requiring a manual re-check.

**This plan is intentionally narrow.** It is the shippable slice of issue #66. It does **not** implement the full capability-based onboarding refactor described in that issue — that is a follow-up plan to be written separately.

## Why this and why now

1. Meeting recording is live in v0.6. The Screen Recording permission is real and unavoidable for that feature.
2. Today, users only encounter the permission prompt the first time they click the meeting pill — mid-intent, often right before a real meeting. That is the wrong time to ask.
3. All the plumbing already exists:
   - `PermissionService.checkScreenRecordingPermission()` / `requestScreenRecordingPermission()` / `openScreenRecordingSettings()` — `Sources/MacParakeetCore/Services/PermissionService.swift:40-60`
   - `TelemetryPermission.screenRecording` enum case and `permissionPrompted/Granted/Denied` events — `Sources/MacParakeetCore/Services/TelemetryEvent.swift:118`
   - `MeetingRecordingFlowCoordinator` already drives the first-use flow via `.checkingPermissions` state
4. The change is contained to ~4 files. It can land as a single PR without touching the STT runtime, database, or meeting recording service.

## Scope

### In scope

- New `meetingRecording` step in `OnboardingViewModel.Step`, positioned after `.accessibility` and before `.hotkey`.
- New page in `OnboardingFlowView` with honest framing ("we never look at your screen"), Enable button, and an explicit **Skip** button (not a silent Continue).
- Live polling loop that re-checks all three TCC permissions every ~2 seconds while the onboarding window is visible, stops when it closes.
- Persistent `onboarding.meetingRecordingSkipped` flag so skipped users aren't renagged.
- New Settings row: "Screen & System Audio Recording" capability with status pill and "Open System Settings" / "Enable" button, live-updating the same way the onboarding page does.
- Telemetry: reuse the existing `screen_recording` permission event name, add an optional `context` attribute if practical (or just emit from the new onboarding code path — the event name is already allowlisted because the meeting coordinator already sends it).
- Tests for the new ViewModel behavior (step ordering, skip flag, polling start/stop, skip allows `canContinueFromCurrentStep() == true`).

### Out of scope

- Full capability-based onboarding refactor (shared readiness coordinator, workflow-tailored onboarding, "which modes do you want?" branching). That is the rest of issue #66 and belongs in a separate plan.
- Any change to `MeetingRecordingFlowCoordinator` beyond what is needed to reflect the new Settings row — the existing `.checkingPermissions` flow must keep working for users who skipped the onboarding step.
- Re-onboarding existing users. Users past `hasCompletedOnboarding` do **not** see the new step. The existing first-use flow continues to cover them.
- Touching the STT runtime, diarization, or model warm-up flow.
- Unifying Settings and onboarding around a shared `ReadinessModel` type. Both views will still call `PermissionService` directly in this plan. (A shared coordinator is the follow-up refactor.)

### Invariants (must not change)

- Dictation-only users must still be able to complete onboarding without granting Screen Recording. The new step is **optional**; `canContinueFromCurrentStep()` must return `true` on the meeting-recording step regardless of permission state.
- Existing users who have already completed onboarding must not see onboarding reopen because of this change.
- First-use permission prompt in `MeetingRecordingFlowCoordinator` must still work unchanged for users who skipped.
- Revocation still works: if a user grants during onboarding and later revokes in System Settings, the meeting coordinator's existing `.checkingPermissions` re-check catches it (no change needed).
- No `CGRequestScreenCaptureAccess()` calls inside the polling loop — only `CGPreflightScreenCaptureAccess()`. The `Request` variant has UI side effects and must only be called in response to the user clicking "Enable."

## Current state snapshot

### Already true

- `OnboardingViewModel.Step` is a linear wizard: `welcome → microphone → accessibility → hotkey → engine → done` (`Sources/MacParakeetViewModels/OnboardingViewModel.swift:12-32`).
- `PermissionService` has all three TCC APIs wired (`Sources/MacParakeetCore/Services/PermissionService.swift:40-71`).
- `TelemetryPermission.screenRecording` exists and is already emitted from `MeetingRecordingFlowCoordinator` at first-use — confirming the event name is already allowlisted in `macparakeet-website/functions/api/telemetry.ts`.
- `SettingsViewModel` has `microphoneGranted` and `accessibilityGranted` but no `screenRecordingGranted` (`Sources/MacParakeetViewModels/SettingsViewModel.swift:164-166`).
- `SettingsView.permissionsCard` shows Microphone and Accessibility rows (`Sources/MacParakeet/Views/Settings/SettingsView.swift:516-547`).
- `OnboardingFlowView` has a step icon map, title/subtitle map, continue-button map, progress strip, and a main `stepBody(viewModel.step)` switch. Adding a new case means touching each of these maps — the compiler will flag anything missed.
- Tests live in `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift`.

### Gaps this plan closes

- No onboarding step for Screen Recording → users surprised mid-meeting.
- No live permission polling → users must click "Re-check" after flipping a toggle.
- No Settings row for Screen Recording → users can't verify or re-trigger it from Settings.

## Locked design decisions

These are not open questions for the implementing agent. They were decided in the planning conversation that produced this plan.

### 1. Optional, not mandatory

The step must be skippable. Two visible buttons on the page:

- **Primary:** "Enable meeting recording"
- **Secondary:** "Skip — I'll set this up later"

No silent Continue-as-skip. The Skip button persists `onboarding.meetingRecordingSkipped = true` and advances.

`canContinueFromCurrentStep()` returns `true` on this step regardless of permission state. The Continue button is only used if the user grants permission; otherwise they click Skip.

### 2. Position: after accessibility, before hotkey

New order: `welcome → microphone → accessibility → meetingRecording → hotkey → engine → done`.

Rationale: groups all three TCC permissions together, keeps the heavy model-download step at the end, and places the skip decision before any sunk-cost feeling.

### 3. Honest framing about the permission name

macOS calls the permission "Screen & System Audio Recording" and users legitimately read that as "record my screen." Address it directly in the copy:

> **Meeting recording (optional)**
>
> To capture audio from calls, MacParakeet needs macOS's "Screen & System Audio Recording" permission.
>
> **MacParakeet never looks at or saves your screen.** Apple bundles screen access into this permission — it's the only way apps are allowed to capture system audio. We only use the audio.
>
> You can skip this and enable it later if you don't plan to record meetings.

### 4. Live polling: 2-second interval, view-lifecycle scoped

- Start polling when the onboarding window appears.
- Poll every 2 seconds: `AVCaptureDevice.authorizationStatus(for: .audio)`, `AXIsProcessTrusted()`, `CGPreflightScreenCaptureAccess()`.
- Update `OnboardingViewModel` state if values change; this drives UI updates via `@Observable`.
- Stop the timer when the window closes (`stopObservingWarmUp()` path — add a parallel `stopPermissionPolling()`).
- Same lifecycle-scoped polling on the Settings window when it is visible.

### 5. Relaunch fallback for screen recording

On some macOS versions `CGPreflightScreenCaptureAccess()` continues to return `false` after the user grants permission until the app is relaunched. After ~10 seconds of polling without a transition to granted following an Enable click, show an inline hint:

> "If the status doesn't update, quit and reopen MacParakeet — macOS sometimes requires a restart after granting this permission."

Do not try to auto-restart the app. Just surface the hint.

### 6. Telemetry: reuse existing event names

- `permissionPrompted(permission: .screenRecording)` — emit when user clicks Enable during onboarding.
- `permissionGranted(permission: .screenRecording)` — emit when poll detects transition to granted.
- `permissionDenied(permission: .screenRecording)` — do **not** emit on skip (skip is a user choice, not a denial); emit only if the system reports denial explicitly.
- New event: `onboardingStep(step: "meeting_recording")` — already covered by the existing `onboardingStep` event with the new step's title.

The event names already exist, so **no `macparakeet-website/functions/api/telemetry.ts` change is required**. But confirm this before merging — grep `ALLOWED_EVENTS` on the website repo for `screen_recording` / `onboarding_step` to be safe.

### 7. Skipped-flag storage

`UserDefaults` key: `"onboarding.meetingRecordingSkipped"` (Bool). Stored via the same `defaults` dependency already injected into `OnboardingViewModel`. Cleared by `resetOnboarding()` alongside the existing reset logic.

The flag is informational — it prevents re-nagging in Settings (no pulsing "set this up!" dot) but does not gate any feature. Meeting recording's existing first-use prompt remains the final fallback.

## Implementation plan

### Step 1 — `OnboardingViewModel` (MacParakeetViewModels target)

File: `Sources/MacParakeetViewModels/OnboardingViewModel.swift`

1. Add `case meetingRecording` between `.accessibility` and `.hotkey` in the `Step` enum. Title: `"Meeting Recording"`.
2. Add `@Observable` state:
   - `public private(set) var screenRecordingGranted: Bool = false`
   - `public private(set) var meetingRecordingSkipped: Bool = false` (initialized from `defaults`)
   - `public private(set) var showRelaunchHint: Bool = false`
3. Extend the `PermissionServiceProtocol` dependency — no new methods, the APIs already exist. The ViewModel just needs to call `permissionService.checkScreenRecordingPermission()`, `requestScreenRecordingPermission()`, and `openScreenRecordingSettings()`.
4. Add new actions:
   - `requestScreenRecordingAccess()` — emits `permissionPrompted`, calls `requestScreenRecordingPermission()`, records the "pending grant" timestamp (used by the relaunch-hint timer).
   - `skipMeetingRecordingStep()` — sets `meetingRecordingSkipped = true`, writes to `defaults`, calls `goNext()`.
   - `openScreenRecordingSystemSettings()` — passes through to `permissionService.openScreenRecordingSettings()`.
5. Update `canContinueFromCurrentStep()`:
   ```swift
   case .meetingRecording:
       return true  // optional step — always allowed
   ```
6. Add live polling:
   - `private var permissionPollingTask: Task<Void, Never>?`
   - `public func startPermissionPolling()` — starts a `Task` with a `while !Task.isCancelled { try? await Task.sleep(...) ; refresh() }` loop at 2-second intervals. Writes to mic/accessibility/screenRecording state on the main actor. Idempotent (no-op if already running).
   - `public func stopPermissionPolling()` — cancels and clears the task.
   - `refresh()` already handles mic and accessibility; extend it to also read `permissionService.checkScreenRecordingPermission()` and update `screenRecordingGranted`. When it transitions `false → true`, emit `permissionGranted(permission: .screenRecording)` exactly once per session.
7. Add the relaunch hint:
   - Private `grantRequestedAt: Date?` timestamp set inside `requestScreenRecordingAccess()`.
   - Inside the polling loop, if `screenRecordingGranted == false` and `grantRequestedAt != nil` and `now - grantRequestedAt > 10s`, set `showRelaunchHint = true`.
   - Clear `grantRequestedAt` and `showRelaunchHint` when grant succeeds or when the user leaves the step.
8. Extend `resetOnboarding()` to clear the `meetingRecordingSkipped` flag.

### Step 2 — `OnboardingFlowView` (MacParakeet target)

File: `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift`

1. Update every switch over `OnboardingViewModel.Step` to include `.meetingRecording`. The compiler will flag missed cases. Locations (from grep):
   - Step icon map (line ~152)
   - `stepBody(_:)` switch (line ~282)
   - Title map (line ~823)
   - Subtitle map (line ~834)
   - Continue-button-label map (line ~851)
   - `stepIsCompleted(_:)` (line ~160)
2. For `stepIsCompleted(.meetingRecording)`: return `viewModel.screenRecordingGranted || viewModel.meetingRecordingSkipped`.
3. New `meetingRecordingStepView` with:
   - Title "Meeting Recording (Optional)"
   - Honest copy (see locked decision #3)
   - Primary button "Enable meeting recording" → calls `viewModel.requestScreenRecordingAccess()`. Disabled when `screenRecordingGranted == true`.
   - Secondary button "Skip — I'll set this up later" → calls `viewModel.skipMeetingRecordingStep()`.
   - Status pill reflecting `screenRecordingGranted`.
   - Conditional link: "Open System Settings" → `viewModel.openScreenRecordingSystemSettings()`.
   - Conditional relaunch hint when `viewModel.showRelaunchHint == true`.
4. Wire `startPermissionPolling()` / `stopPermissionPolling()` to the view lifecycle (`.task { ... }` + cleanup in the `OnboardingWindowController` close path).

### Step 3 — `SettingsViewModel` (MacParakeetViewModels target)

File: `Sources/MacParakeetViewModels/SettingsViewModel.swift`

1. Add `public var screenRecordingGranted = false`.
2. Extend `refreshPermissions()` to also read `permissionService.checkScreenRecordingPermission()` and assign.
3. Add `public func requestScreenRecordingAccess()` → calls `permissionService.requestScreenRecordingPermission()`, emits `permissionPrompted(.screenRecording)`, then refreshes.
4. Add `public func openScreenRecordingSystemSettings()` passthrough.
5. Add lifecycle-scoped polling similar to the onboarding ViewModel (start when Settings window visible, stop when closed). If adding a full polling loop to Settings is more than ~20 lines, a simpler first pass is: call `refreshPermissions()` whenever the Settings window becomes key. The live-polling implementation can be a second PR if needed.

### Step 4 — `SettingsView` (MacParakeet target)

File: `Sources/MacParakeet/Views/Settings/SettingsView.swift`

Update `permissionsCard` (line 516):

1. Update subtitle from "Required for dictation and pasting text into apps." to something like "Required for dictation. Screen Recording is optional and only needed for meeting capture."
2. Add a third row below Accessibility:
   ```swift
   Divider()
   HStack {
       rowText(
           title: "Screen & System Audio Recording",
           detail: "Optional. Only used to capture meeting audio — MacParakeet never records your screen."
       )
       Spacer()
       permissionPill(granted: viewModel.screenRecordingGranted)
   }

   if !viewModel.screenRecordingGranted {
       Button("Enable meeting recording") {
           viewModel.requestScreenRecordingAccess()
       }
       .buttonStyle(.bordered)
   }
   ```

### Step 5 — Tests

File: `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift`

Add cases:

1. `test_meetingRecordingStep_ordering` — confirm `Step.allCases` contains `.meetingRecording` between `.accessibility` and `.hotkey`.
2. `test_meetingRecordingStep_canContinue_always_true` — regardless of `screenRecordingGranted` or `meetingRecordingSkipped`.
3. `test_skipMeetingRecordingStep_sets_flag_and_advances` — after calling, `meetingRecordingSkipped == true`, `defaults` contains the key, and `step == .hotkey`.
4. `test_screenRecordingGrant_transition_emits_permissionGranted_once` — use a mock `PermissionService` that reports false then true; polling refresh should emit `.permissionGranted(.screenRecording)` exactly once. (Use an in-memory telemetry spy; there's already a pattern for mocking telemetry in the test target — grep for existing permission-event tests.)
5. `test_resetOnboarding_clears_meetingRecordingSkipped_flag`.
6. `test_relaunchHint_shows_after_10s_without_grant` — inject a controlled clock via the existing `now:` closure and a mock permission service; drive the polling loop manually in the test.
7. `test_polling_lifecycle` — `startPermissionPolling()` idempotent; `stopPermissionPolling()` cancels the task.

Add a separate `SettingsViewModelTests` case:

8. `test_refreshPermissions_includes_screenRecording` — verifies the new field is populated.

The existing test file uses a mock `PermissionService`; extend it with `screenRecordingGranted` behavior (it probably already has a stub since `MeetingRecordingFlowCoordinator` tests use it — check `Tests/MacParakeetTests/` for `MockPermissionService` or similar).

### Step 6 — Telemetry allowlist sanity check

Before merging:

```bash
# In macparakeet-website repo:
grep -n "screen_recording\|onboarding_step" functions/api/telemetry.ts
```

Both should already be present because the meeting coordinator already emits `permissionPrompted(.screenRecording)`. If either is missing, **add them to the Worker allowlist in a separate PR to the website repo and deploy it first** — otherwise the Worker drops the entire event batch and you silently lose co-batched telemetry (per the `feedback_telemetry_allowlist.md` lesson).

### Step 7 — Spec updates

Small doc updates to keep source-of-truth aligned:

1. `spec/02-features.md` — onboarding section: document the new `meetingRecording` step, list it as optional.
2. `spec/adr/005-onboarding-first-run.md` — amend with a "2026-04 addendum: optional Screen Recording step" note, or add it to the steps list.
3. No ADR change needed — the architectural direction (capability-based onboarding) is deferred to the full refactor plan, not this PR.

### Step 8 — Manual verification checklist

Must be run on a fresh macOS user account or VM (not the dev machine, because permissions are already granted there):

- [ ] Fresh install → complete onboarding including grant of Screen Recording → click "Record meeting" → **no** system permission prompt appears; meeting recording starts directly.
- [ ] Fresh install → complete onboarding but **skip** the meeting recording step → click "Record meeting" → existing first-use permission flow runs normally.
- [ ] Fresh install → on the meeting recording step, click Enable, grant in System Settings → within 2 seconds the onboarding UI reflects granted state without needing a click.
- [ ] Fresh install → on the meeting recording step, click Enable, do nothing in System Settings for 10+ seconds → relaunch hint appears.
- [ ] Existing install (pre-onboarding-complete defaults) → launch app → onboarding does **not** reopen.
- [ ] Settings window → Permissions card shows the new row. Revoke Screen Recording in System Settings → Settings row reflects revoked state within 2 seconds (or on next window focus, per Step 3's simpler fallback).
- [ ] `swift test` green.

## Known pitfalls (do not re-learn the hard way)

- **Don't call `CGRequestScreenCaptureAccess()` in the polling loop.** It has UI side effects (can trigger system prompts). Only call `CGPreflightScreenCaptureAccess()` to check.
- **Don't emit `permissionDenied` on skip.** Skip is a deliberate user choice, not a denial. Only emit denied if the underlying API reports it.
- **`@Observable` + actor hops:** when writing back polling results from the `Task`, use `await MainActor.run { ... }` or mark the update methods `@MainActor`, matching the existing `refresh()` pattern in `OnboardingViewModel`.
- **Test the `@MainActor` store isolation:** the existing test file already deals with actor hops for `refresh()`. Copy that pattern.
- **Existing users:** do not gate on `meetingRecordingSkipped` for feature access. It is purely informational for Settings UI polish.
- **Two-repo telemetry:** see Step 6. Confirm allowlist before merging, even though the event name is already used by the meeting coordinator.
- **Don't "improve" surrounding code.** The full capability refactor is tempting while you're in `OnboardingViewModel`, but it is explicitly out of scope and belongs in its own plan.
- **Screen recording relaunch quirk:** on macOS versions where the preflight check keeps returning false post-grant until relaunch, the hint copy is the only mitigation. Do not try to restart the app from code.

## Acceptance criteria

- [ ] New `meetingRecording` step exists in `OnboardingViewModel.Step` between `.accessibility` and `.hotkey`.
- [ ] Users can complete onboarding without granting Screen Recording (Skip button works, advances to hotkey).
- [ ] Users who click Enable and grant in System Settings see the onboarding UI update within ~2 seconds.
- [ ] `SettingsView` Permissions card includes a Screen & System Audio Recording row.
- [ ] A fresh-install user who grants during onboarding can click "Record meeting" and not see a surprise permission prompt.
- [ ] A fresh-install user who skips during onboarding still gets the existing first-use permission flow on their first meeting click.
- [ ] Existing users past `hasCompletedOnboarding` do not see onboarding reopen.
- [ ] `swift test` passes (new tests + existing ~1311 tests).
- [ ] Spec updates landed (`spec/02-features.md`, `spec/adr/005-onboarding-first-run.md`).
- [ ] Manual verification checklist in Step 8 completed.

## Commit / PR guidance

Single PR, rich commit message per `docs/commit-guidelines.md`. Suggested title:

> Add optional Screen Recording permission step to onboarding

Body sections:

- **What Changed**: new `meetingRecording` onboarding step, Settings row, live permission polling, skip flag, relaunch hint.
- **Root Intent**: close the most user-visible gap from issue #66 — users being surprised by a Screen Recording permission prompt at first meeting-record click.
- **Prompt That Would Produce This Diff**: "Add an optional Screen Recording permission step to onboarding after Accessibility, with live polling and a Skip button, plus a matching row in Settings. Do not refactor onboarding into a capability model — that is a separate follow-up."
- **ADRs Applied**: ADR-005 (onboarding), ADR-014 (meeting recording), ADR-015 (concurrent dictation + meeting).
- **Files Changed**: enumerate.
- Reference `#66` and note the issue stays open for the broader capability refactor.

## Follow-up (not in this plan)

The full capability-based onboarding refactor described in issue #66 — shared readiness coordinator extracted from `OnboardingViewModel`, unified readiness model across onboarding/Settings/feature entry points, workflow-tailored onboarding ("which modes do you want?"), first-class setup items — is **deferred to a separate plan**. It should be written when there is appetite to touch the onboarding architecture more deeply. This plan is explicitly the narrow, shippable slice.
