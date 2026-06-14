# Meeting Auto-Stop Orchestration

**Status:** Execution guide completed for ADR-023 Phases A+B; keep as handoff context for deferred Phase C.
**Date:** 2026-06-14
**Source of truth:** ADR-023 first, then `plans/active/2026-06-14-meeting-auto-stop.md`.
**Requirement:** REQ-MEET-015

This file is an execution aid for the ADR-023 implementation branch. It does
not replace the ADR or the implementation plan.

## Bird's-Eye Plan

Implement activity-based meeting auto-stop in narrow, shippable slices:

1. Phase A: implemented 2026-06-14. Recognized conferencing app quits, 15s
   grace, veto countdown, settings toggle, feature flag, telemetry, policy
   tests, coordinator tests.
2. Phase B: implemented 2026-06-14. Sustained dual-channel silence under the
   same toggle, using the existing meeting level signal path, with a
   conservative 4 min default grace.
3. Phase C: deferred. Consume ADR-024 per-process attribution only if the attribution
   surface already exists or can be introduced without expanding this branch
   into the whole ADR-024 implementation.

Keep the implementation opt-in and default-off behind
`AppFeatures.meetingAutoStopEnabled`. Auto-stop must always run the same
finalize/transcribe/save path as manual stop.

## Owner Decisions

- App-quit grace: 15 seconds.
- Countdown posture: veto-able countdown, not silent stop.
- Defaults: choose conservative common-sense defaults where the ADR leaves
  tuning open.

## Goal Prompt

Use this prompt to resume or hand off the goal:

```text
Implement MacParakeet ADR-023 activity-based meeting auto-stop in
/Users/dmoon/code/macparakeet-worktrees/feat-meeting-auto-stop-phase-a.

Source of truth order:
1. CLAUDE.md
2. spec/10-ai-coding-method.md
3. spec/adr/023-activity-based-meeting-auto-stop.md
4. plans/active/2026-06-14-meeting-auto-stop.md
5. subsystem READMEs for touched areas

Owner decisions:
- app-quit grace is 15s
- veto countdown is required
- choose conservative common-sense defaults

Implement Phase A, then Phase B, then Phase C only if ADR-024 attribution is
available or can be cleanly added without implementing all of ADR-024. Keep the
feature opt-in/default-off behind AppFeatures.meetingAutoStopEnabled. Pure
policy belongs in MacParakeetCore; AppKit/CoreAudio/SwiftUI side effects stay
in the app/viewmodel layer. Auto-stop must call the normal meeting stop
finalize/transcribe/save path and must never discard or truncate data.

Run focused tests while iterating and full `swift test` before the PR. Update
docs/status markers and archive the plan only when the implemented phase scope
is actually complete.
```

## Guardrails

- Do not add a calendar end-time stop path.
- Do not stop paused recordings.
- Do not keep observers or timers alive while idle or while the toggle/flag is
  off.
- Do not introduce audio or screen content inspection for detection.
- Do not add telemetry event names without mirroring the website allowlist
  before any flag-on release.
