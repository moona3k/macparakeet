# Command Mode GUI (F10a) De-Risk Plan

Status: Proposed  
Owner: Core app team  
Updated: 2026-02-15

## Objective

Reduce implementation risk for Command Mode by proving reliability at the three fragile boundaries before full GUI build:

1. hotkey chord detection and state arbitration
2. Accessibility selected-text retrieval across real apps
3. selection replacement via paste with undo safety

This plan is mandatory pre-work before the full F10a GUI implementation.

## Scope Boundary

In scope:

1. de-risk spikes and acceptance gates for hotkey, AX selection, and paste replacement
2. failure-mode taxonomy and UX behavior mapping
3. integration harness for orchestration seams
4. explicit Go/No-Go decision package

Out of scope:

1. pre-built quick commands (F10b)
2. command template persistence (F10b)
3. command-mode hotkey customization (F10b)
4. command history UI (F10b)

## Success Criteria (Go/No-Go)

Proceed to full F10a implementation only when all are true:

1. hotkey chord reliability: `Fn+Control` activation/cancel behavior is deterministic in manual matrix and integration tests
2. AX selection retrieval: pass rate >= 95% across manual matrix apps (TextEdit, Notes, Slack, Safari textarea, VS Code)
3. paste replacement: replacement succeeds and `Cmd+Z` reverts in all manual matrix apps
4. regression safety: dictation hotkey behavior unchanged in existing test suite
5. failure UX map complete: every failure path has defined app behavior and message
6. telemetry/logging tags added for each critical transition and failure bucket

## Dependencies and Preconditions

1. existing dictation hotkey flow remains stable baseline (`swift test` green before each spike)
2. Accessibility permission can be toggled/revoked for manual negative tests
3. test apps installed: TextEdit, Notes, Slack, Safari, VS Code
4. command CLI path remains usable for transform baseline:
`macparakeet-cli llm command "<command>" "<selected_text>"`
5. no concurrent feature branch mutates `HotkeyManager` and `ClipboardService` contracts without rebasing this plan

## Execution Governance

1. one active phase at a time; do not start next phase before prior exit criteria are met
2. each phase ends with a short evidence note in PR description:
   - what passed
   - what failed
   - what remains open
3. `swift test` must be green at branch head before requesting review on any de-risk PR
4. if a blocker is found, freeze forward progress and capture issue + reproduction before continuing

## Blocker and Severity Policy

1. P0 blocker:
   - deterministic data loss or wrong-target paste
   - stop all forward work until fixed
2. P1 blocker:
   - command flow unusable in 1 or more matrix apps
   - do not proceed to next phase until fixed or explicitly waived
3. P2 non-blocker:
   - minor UX inconsistency without data loss
   - may proceed with documented follow-up issue
4. flaky test policy:
   - any new test failing intermittently in local reruns (5 consecutive runs) is treated as blocker until stabilized

## Ownership and Review

1. plan owner: core app team
2. hotkey spike reviewer: hotkey/state-machine owner
3. AX spike reviewer: platform/accessibility owner
4. paste spike reviewer: clipboard/input owner
5. final Go/No-Go approvers: app lead + QA lead

## Deliverables

1. contract lock doc section (API and behavior contracts)
2. hotkey spike code + tests + manual evidence
3. AX spike code + tests + manual evidence
4. paste spike code + tests + manual evidence
5. failure matrix doc with user-facing outcomes
6. integration tests for command orchestration seams
7. Go/No-Go decision note with pass/fail evidence summary

## Phase Plan

### Phase 0: Contract Lock

Create/confirm one contract section for:

1. `HotkeyManager` command callbacks
2. `AccessibilityService.getSelectedText()` behavior and error model
3. command replace semantics and undo guarantees

Contract requirements:

1. start command mode on `Fn+Control` rising edge
2. cancel command mode on second chord press
3. selected text hard cap: 16,000 chars
4. explicit typed AX errors:
`notAuthorized`, `noFocusedElement`, `noSelectedText`, `textTooLong`, `unsupportedElement`
5. exactly one paste action on success
6. no partial write on failure
7. target app undo (`Cmd+Z`) must revert replacement

Exit criteria:

1. contracts documented and referenced in spike PR descriptions
2. no unresolved contract ambiguity

### Phase 1: Hotkey Spike

Build a narrow spike with no command overlay UI:

1. add command-chord callbacks to `HotkeyManager` and app-level no-op handlers
2. enforce precedence rules:
   command chord > dictation gesture when both possible
3. suppress dictation state-machine actions while command mode active
4. add focused tests for rising edge, precedence, and second-press cancel

Exit criteria:

1. deterministic automated behavior
2. manual checks:
   no accidental dictation start on `Fn+Control`
3. second chord press consistently cancels

### Phase 2: Accessibility Spike

Implement `AccessibilityService` and test in isolation:

1. fallback sequence:
   - `kAXSelectedTextAttribute`
   - selected range + parameterized substring from full value
2. preserve selected content exactly for transform input
3. add unit tests for all typed error paths

Manual matrix:

1. TextEdit
2. Notes
3. Slack
4. Safari textarea
5. VS Code editor

Exit criteria:

1. >= 95% successful retrieval for intentional selections
2. correct explicit failures for empty selection and permission denial

### Phase 3: Paste/Replace Spike

Exercise replacement independently from command recording:

1. feed known replacement text through existing `ClipboardService.pasteText`
2. verify single-write behavior and no duplicate pastes
3. validate app focus and key-window handoff rules

Manual checks per app:

1. replacement lands in correct target field
2. one `Cmd+Z` restores original selected text
3. no clipboard corruption after failure

Exit criteria:

1. all matrix apps pass replace + undo

### Phase 4: Failure Matrix and UX Decisions

Create explicit mapping from technical failure to user behavior:

1. no accessibility permission
2. no selection
3. selection too long
4. STT empty command
5. LLM timeout/failure
6. paste failure
7. hotkey conflict with dictation active

For each case define:

1. user-facing message
2. overlay state transition
3. recovery action
4. logging tag/category

Exit criteria:

1. matrix complete and reviewed before full implementation PR

### Phase 5: Integration Harness Before Full UI

Add tests for orchestration seams before command overlay polish:

1. command hotkey precedence over dictation
2. no-selection path returns idle with actionable error
3. stop path processes once and pastes once
4. cancel path leaves no stale recording state
5. dictation regression checks still pass

Exit criteria:

1. integration tests pass consistently
2. no regressions in existing dictation tests

## Risk Register

1. AX API inconsistency by app/editor type
   - impact: high
   - mitigation: fallback retrieval chain + app matrix + explicit unsupported errors
2. hotkey collision with dictation gestures
   - impact: high
   - mitigation: explicit precedence contract + dedicated integration tests
3. paste targeting wrong window/control
   - impact: high
   - mitigation: key-window resign rules + one-paste invariant tests
4. undo behavior non-deterministic in some apps
   - impact: medium
   - mitigation: manual matrix gate blocks rollout
5. hidden race conditions in async orchestration
   - impact: high
   - mitigation: generation guards + serialized command actions + test harness

## Observability Requirements

For each spike and later F10a runtime path:

1. structured logs for:
   - command mode start request
   - hotkey chord detected
   - selected text length and retrieval path
   - stop/process begin and completion
   - paste success/failure
2. error logs include failure bucket and user-facing message key
3. log lines must make post-mortem timeline reconstruction possible

Required event keys:

1. `command_hotkey_detected`
2. `command_selection_read_started`
3. `command_selection_read_failed`
4. `command_recording_started`
5. `command_recording_stopped`
6. `command_processing_started`
7. `command_processing_failed`
8. `command_paste_started`
9. `command_paste_failed`
10. `command_flow_completed`

## Evidence Artifacts

Each phase completion must include:

1. test output snippet (`swift test` or filtered suite)
2. manual matrix results table with app-by-app pass/fail
3. known limitations discovered
4. follow-up issues (if any) tied to F10b or hardening backlog

Manual matrix table must include:

| App | Scenario | Expected | Actual | Pass/Fail | Notes |
|---|---|---|---|---|---|
| TextEdit | Replace + undo | Single replace, one `Cmd+Z` restores |  |  |  |
| Notes | Replace + undo | Single replace, one `Cmd+Z` restores |  |  |  |
| Slack | Replace + undo | Single replace, one `Cmd+Z` restores |  |  |  |
| Safari textarea | Replace + undo | Single replace, one `Cmd+Z` restores |  |  |  |
| VS Code | Replace + undo | Single replace, one `Cmd+Z` restores |  |  |  |

## Timeline (Estimate)

1. Phase 0: 0.5 day
2. Phase 1: 0.5 day
3. Phase 2: 1.0 day
4. Phase 3: 0.5 day
5. Phase 4: 0.5 day
6. Phase 5: 0.5 day

Total estimated de-risk duration: 3.5 days.

## PR Slicing

1. `de-risk/contracts`: contracts + plan references
2. `de-risk/hotkey-spike`: command chord detection + tests
3. `de-risk/ax-spike`: accessibility service + tests + manual results
4. `de-risk/paste-spike`: replacement safety + manual results
5. `de-risk/integration-gates`: failure matrix + orchestration tests
6. `f10a/full-build`: command overlay and end-to-end flow, only after gates pass

## Tracking Checklist

- [ ] Contract lock complete
- [ ] Hotkey spike complete
- [ ] Accessibility spike complete
- [ ] Paste spike complete
- [ ] Failure matrix complete
- [ ] Integration gates complete
- [ ] New logs/events verified in console output
- [ ] P0/P1 blockers resolved or explicitly waived
- [ ] Go/No-Go review passed

## Go/No-Go Review Template

At the end of Phase 5, document:

1. criteria passed/failed (with evidence link per criterion)
2. open defects by severity (P0/P1/P2)
3. residual risks
4. recommended decision:
   - Go to F10a full build
   - No-Go, return to specific phase with actions
5. approver sign-off:
   - app lead
   - QA lead
