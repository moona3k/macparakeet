# Hide Floating Meeting Recording Pill

**Status:** EXECUTOR-READY - not started
**Date:** 2026-07-04
**Issue:** #648 - "[Feature Request] Ability to Hide meeting recording UI"
**Related specs:** `spec/04-ui-patterns.md`, `spec/05-audio-pipeline.md`, ADR-014 (meeting recording), ADR-015 (concurrent dictation/meeting), ADR-019 (crash-resilient meeting recording), ADR-025 (meeting capture reliability)
**Verified against:** live GitHub issue #648 and `origin/main` on 2026-07-04. The working tree used for this plan was dirty on an unrelated branch, so implementation should start from a clean worktree based on `origin/main`.

## What This Plan Closes Out

The reporter likes meeting recording to run in the background or from the menu bar, but the floating meeting recording UI occupies screen space. The owner accepted the direction in issue #648: introduce a toggle to hide it.

The product decision is narrow: add a preference to hide the floating meeting recording pill, while preserving all recording controls, capture-health visibility, finalization, recovery, and menu bar recording indication. This is an enhancement, not a bug fix, and should be labeled `enhancement` plus `ready-for-agent` if the issue tracker is updated.

## Verified Current State

- The floating meeting pill is an AppKit `NSPanel` owned by `MeetingRecordingPillController`. `show()` creates the window, `hide()` detaches it, and both are presentation-only operations.
- `MeetingRecordingFlowCoordinator` builds the long-lived `MeetingRecordingPillViewModel`, `MeetingRecordingPanelViewModel`, `MeetingRecordingPillController`, and `MeetingRecordingPanelController` during `.showRecordingPill`, then starts polling, glow updates, transcript observation, and speech warm-up observation.
- The same `MeetingRecordingPillViewModel` drives the Transcribe/Meetings tile, including elapsed time, pause state, audio levels, background transcription count, and `captureHealth`.
- The Meeting tile already exposes active recording controls: pause/resume and stop, plus inline capture-health warning chips.
- The menu bar menu already has Start/Stop Recording and `AppDelegate.resolveMenuBarState(...)` gives meeting recording priority over dictation and file transcription, so the menu bar can remain the passive "recording is active" signal when the floating pill is hidden.
- The floating pill currently owns the easiest path to the live meeting panel: click the pill or choose Open MacParakeet from the pill context menu. Hiding the pill must not strand access to the live panel.
- The quit path already hides and restores the pill with `dismissFloatingPillForQuit()` and `restoreFloatingPillIfRecording()`. A hide preference must gate restore, or cancelling quit will resurrect the exact UI the user disabled.
- The existing `showIdlePill` preference is the closest pattern: `SettingsViewModel` persists it, posts an app notification, `AppSettingsObserverCoordinator` fans it out, and `AppDelegate.handleShowIdlePillChange()` applies the presentation change.

## Scope Boundaries

### In Scope

- A default-on preference for showing the floating meeting recording pill.
- A status-menu toggle for the preference, because the reporter explicitly wants meeting recording to work from the menu bar.
- A Settings > Meeting Recording row for discoverability and consistency with other capture preferences.
- Runtime application of the preference while a recording is active:
  - turning it off hides the floating pill immediately without stopping recording;
  - turning it on re-shows the pill if a recording is active.
- A menu/status-menu path to open the live meeting panel while recording, replacing the click-the-pill path for users who hide the pill.
- Focused tests for default/persistence, notification fanout, flow-neutral hide/restore, and menu labels.
- A short spec/docs update so the UI-pattern docs no longer say the pill always appears unconditionally.

### Out of Scope

- Redesigning the meeting pill visuals, animation, icon, or flower-of-life motif.
- Changing meeting capture, AEC, `microphone-cleaned.m4a`, final STT routing, or artifact semantics.
- Removing the Meeting tile, meeting hotkey, pause/resume, stop, discard, recovery, or capture-health warnings.
- Adding another floating warning or replacement overlay.
- Making the live meeting panel itself persistent or menu-bar-only. This plan only preserves access to the existing panel.
- Changing dictation `showIdlePill` behavior, except for following its pattern.

### Invariants

- Hiding the floating pill is a presentation preference only. It must never stop, pause, discard, finalize, or advance a recording.
- `MeetingRecordingPillViewModel` stays long-lived and continues updating the tile even when no floating pill window exists.
- Polling, live transcript observation, capture-health updates, background transcription badge state, and speech warm-up observation continue exactly as they do today.
- The menu bar icon must still show the recording state while a meeting is active.
- At least one always-reachable stop path remains available while the pill is hidden: status menu, hotkey, and Meeting/Transcribe tile.
- Capture-health warnings remain visible on a non-hidden surface, currently the Meeting/Transcribe tile and live panel.
- Default behavior is unchanged: existing users still see the floating pill unless they opt out.

## Proposed UX

### Naming

Use positive copy so the default-on behavior reads naturally:

- Settings row: **Show floating meeting controls**
- Detail: **Shows the small recording pill while a meeting is active. Turn this off to control recording from the menu bar, hotkey, or Meetings tab.**
- Menu item: **Show Floating Meeting Controls** with a checkmark when enabled.

Avoid "hide meeting UI" in product copy. It is implementation-focused and could imply hidden recording state. The app should make clear that recording controls remain available elsewhere.

### Status Menu While Recording

When meeting recording is active and the floating pill can be hidden, the status menu should contain:

- **Stop Recording** - existing toggle behavior.
- **Open Live Meeting Panel** - new action, enabled only while the live panel exists and recording is active.
- **Show Floating Meeting Controls** - checkable preference toggle.

When not recording, the menu may still show the checkable preference, but **Open Live Meeting Panel** should be hidden or disabled.

## Implementation Plan

### Phase 1 - Preference Model and Settings Surface

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/AppRuntimePreferences.swift` | Add `showMeetingRecordingPillKey` or `showFloatingMeetingControlsKey`. Default should be `true`, matching current behavior. |
| `Sources/MacParakeetCore/AppNotifications.swift` | Add `.macParakeetShowMeetingRecordingPillDidChange` or equivalent. |
| `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` | Add a privacy-safe `TelemetrySettingName` value such as `meetingRecordingPill` / `meeting_recording_pill`, or explicitly reuse an existing setting name only if the owner accepts the ambiguity. Do not record whether a meeting is active, transcript text, audio, app names, or screen content. |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | Add `showMeetingRecordingPill`, default `true`, persist to `UserDefaults`, post the new notification, and emit `setting_changed`. |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Add the toggle to the Meeting Recording card near the Meeting hotkey row, because both govern control surfaces. |
| `Sources/MacParakeetViewModels/SettingsSearchIndex.swift` | Add or extend meeting-search keywords: `floating controls`, `meeting pill`, `hide meeting`, `recording UI`. |
| `docs/telemetry.md` | Add the new `setting_changed.setting` value if a new telemetry setting name is introduced. |

**Tests**

- Extend `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`:
  - default is `true` when no preference exists;
  - changing it persists the value;
  - changing it posts the new notification;
  - reloading the view model reads the persisted value.
- Extend `Tests/MacParakeetTests/ViewModels/SettingsSearchIndexTests.swift` so searches for "meeting pill", "floating controls", and "hide meeting" find the Meeting Recording settings card.
- Extend `Tests/MacParakeetTests/TelemetryServiceTests.swift` if a new `TelemetrySettingName` case is added.

**Ship criteria:** The preference exists, defaults on, persists, is searchable, and has privacy-safe telemetry parity with adjacent settings.

### Phase 2 - Flow-Neutral Floating Pill Visibility

Add a presentation gate to `MeetingRecordingFlowCoordinator` instead of skipping `.showRecordingPill`.

| File | Change |
|------|--------|
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Accept a provider closure such as `shouldShowFloatingMeetingPill: @MainActor () -> Bool` or a mutable setting reference. During `.showRecordingPill`, still initialize the pill VM, panel VM, callbacks, polling, transcript observation, and panel controller; call `pillController?.show()` only when the preference is on. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Add a method such as `refreshFloatingPillVisibility()` that hides the existing pill when disabled and shows it when enabled and recording is active. This must not call `teardownPillFlow()`. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Gate `restoreFloatingPillIfRecording()` on the preference so cancelling quit does not resurrect a disabled floating pill. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Keep `dismissFloatingPillForQuit()` as a presentation detach. It may preserve frame only when a panel exists. |
| `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift` | Pass the preference provider into the meeting coordinator. |
| `Sources/MacParakeet/App/AppSettingsObserverCoordinator.swift` | Add the notification fanout callback for the new setting. |
| `Sources/MacParakeet/AppDelegate.swift` | Add a handler analogous to `handleShowIdlePillChange()` that calls `meetingRecordingFlowCoordinator?.refreshFloatingPillVisibility()`. |

**Tests**

- Extend `Tests/MacParakeetTests/MeetingRecordingFlow/MeetingRecordingFlowCoordinatorTests.swift`:
  - when the preference is off, entering recording still sets state to recording and leaves `isMeetingRecordingActive == true`;
  - toggling preference off during recording is flow-neutral;
  - toggling preference on during recording is flow-neutral;
  - `restoreFloatingPillIfRecording()` remains flow-neutral and respects the off preference;
  - idle calls are no-ops.
- Extend `Tests/MacParakeetTests/App/AppSettingsObserverCoordinatorTests.swift`:
  - the new notification calls exactly its callback;
  - stopping observation prevents the callback, matching existing channel behavior.

**Ship criteria:** The floating pill window can be hidden or restored at runtime without changing the meeting flow state, callback bindings, recording lifecycle, or finalization path.

### Phase 3 - Menu Bar Control Parity

The menu bar is the reporter's preferred replacement surface. It must be more than just passive status.

| File | Change |
|------|--------|
| `Sources/MacParakeet/App/MenuBarCoordinator.swift` | Add a checkable `Show Floating Meeting Controls` item when meeting recording is enabled. Keep it available in the status menu; optional in the main app menu. |
| `Sources/MacParakeet/App/MenuBarCoordinator.swift` | Add an `Open Live Meeting Panel` item that appears or enables while a meeting recording is active. |
| `Sources/MacParakeet/App/MenuBarCoordinator.swift` | Update `menuNeedsUpdate(_:)` so Start/Stop Recording, Open Live Meeting Panel, and the checked state of Show Floating Meeting Controls are all accurate every time the menu opens. |
| `Sources/MacParakeet/AppDelegate.swift` | Add callbacks from the menu coordinator to toggle the preference and to open the live meeting panel. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Expose a guarded method such as `presentLiveMeetingPanel()` that calls the existing private panel-show logic only in `.starting` / `.recording`. |

**Tests**

- Add `Tests/MacParakeetTests/App/MenuBarCoordinatorTests.swift` if the coordinator can be tested without full app launch. Cover:
  - checkmark reflects the preference;
  - toggling the menu item calls the preference callback;
  - Open Live Meeting Panel is enabled only while a meeting is active;
  - Start Recording changes to Stop Recording while active.
- If AppKit menu testing is too brittle, document that gap and cover the state-provider logic with a small extracted pure helper instead of asserting raw `NSMenuItem` state directly.

**Ship criteria:** A user who hides the floating pill can start, stop, and open the live meeting panel from the menu bar, with recording state visible in the menu bar icon.

### Phase 4 - Docs and Issue Triage Closeout

| File | Change |
|------|--------|
| `spec/04-ui-patterns.md` | Update Meeting Recording Pill behavior from unconditional "appears" / "persists" to default-on and user-hideable. State that menu bar, hotkey, and Meeting tile remain the fallback controls. |
| `spec/README.md` | Add a brief implemented item once shipped, or omit until implementation lands if the plan is committed before code. |
| `plans/active/2026-07-04-hide-meeting-recording-pill.md` | Move to completed after merge and update evidence. |
| GitHub issue #648 | After implementation, comment with the AI triage disclaimer only if posting as an agent. Recommended label/state: `enhancement`, `ready-for-agent` before work; close after verified merge. |

**Tests / verification**

- No dedicated tests for docs-only changes beyond markdown/link sanity.
- If posting to GitHub during triage, every generated comment must start with:

```markdown
> *This was generated by AI during triage.*
```

## Verification Contract

### Focused Automated Tests

Run focused tests for the touched areas:

- `swift test --filter SettingsViewModelTests`
- `swift test --filter SettingsSearchIndexTests`
- `swift test --filter AppSettingsObserverCoordinatorTests`
- `swift test --filter MeetingRecordingFlowCoordinatorTests`
- `swift test --filter TelemetryServiceTests` if a telemetry enum case changes
- `swift test --filter MeetingRecordingTileTests` only if tile copy or state rendering changes

Run full `swift test` at most once, as the final code-change gate, per repo instruction.

### Manual Smoke

Use a clean worktree and dev app build. Smoke the real `NSPanel` behavior because unit tests cannot prove actual AppKit window visibility.

1. Start with the preference on. Start a meeting recording. Confirm the floating pill appears, menu bar icon shows recording, tile shows recording, and Stop Recording is in the status menu.
2. Turn the preference off while recording. Confirm the floating pill disappears, recording continues, tile elapsed time continues, capture-health warnings remain visible on the tile/panel, and Stop Recording remains available.
3. From the status menu, choose Open Live Meeting Panel. Confirm notes/transcript/ask panel opens.
4. Stop recording from the status menu. Confirm meeting finalizes/transcribes normally.
5. Start another meeting with the preference off. Confirm no floating pill appears, but the menu bar icon and tile show active recording.
6. Turn the preference on during recording. Confirm the pill reappears without resetting elapsed time or capture state.
7. While recording with the preference off, initiate quit and cancel it. Confirm the pill does not reappear.
8. Verify the meeting hotkey still toggles recording regardless of pill visibility.

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Hiding the pill accidentally skips flow setup | Medium | High | Gate only `pillController.show()`. Keep VM setup, callbacks, polling, panel setup, and observations unconditional. |
| User cannot find stop controls after hiding the pill | Medium | High | Keep menu bar Stop Recording, hotkey, and Meeting tile controls. Add Open Live Meeting Panel to the menu. |
| Capture-health warnings become invisible | Medium | Medium | Preserve warning chips on the tile/panel. Do not make the pill the only warning surface. |
| Quit-cancel restores hidden UI | Medium | Low | Gate `restoreFloatingPillIfRecording()` on the preference. Add focused test. |
| Menu and Settings toggles drift | Low | Medium | One source of truth in `SettingsViewModel` / `UserDefaults`; menu reads provider on open. |
| Telemetry enum drift or website allowlist confusion | Low | Low | Use the existing `setting_changed` event shape; update `docs/telemetry.md` and telemetry tests if a new setting value is added. |

## Done Criteria

- [ ] Issue #648 has an implementation-ready local plan and can be labeled `enhancement` / `ready-for-agent`.
- [ ] Floating meeting pill visibility is user-configurable and defaults on.
- [ ] Turning the preference off hides only the floating `NSPanel`, not the recording lifecycle.
- [ ] Turning the preference on while recording restores the pill.
- [ ] Menu bar icon, Stop Recording, Open Live Meeting Panel, meeting hotkey, and Meeting tile remain usable when the pill is hidden.
- [ ] Capture-health warnings still appear on a non-hidden surface.
- [ ] Quit-cancel restore respects the hidden preference.
- [ ] Focused tests pass, and full `swift test` is run no more than once as the final gate.
- [ ] `spec/04-ui-patterns.md` reflects the default-on, hideable behavior.

## Open Questions

- Should the status menu toggle be shown at all times, or only when a meeting recording is active? Lean all times for discoverability and because it is a persistent preference.
- Should the menu label say "Show Floating Meeting Controls" or "Show Meeting Pill"? Lean "controls" for user clarity.
- Should there be an "Open Live Meeting Panel" item outside active recording? Lean hidden or disabled; the panel is live-session state, not a general Meetings workspace.
- Should the preference telemetry use a new `meeting_recording_pill` value or reuse `hide_pill`? Lean new value to avoid conflating dictation idle-pill visibility with meeting floating controls.
