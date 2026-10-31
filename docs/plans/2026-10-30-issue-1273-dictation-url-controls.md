# Issue #1273: dictation URL controls

## Decision and evidence

Proceed with a contained additive feature. [Issue #1273](https://github.com/moona3k/macparakeet/issues/1273)
requests start/stop/toggle so a Stream Deck key or workflow tool can control
dictation without Accessibility-powered synthetic hotkeys. The report has no
comments as inspected on 2026-10-30. It identifies a concrete daily workflow;
no claim of broader measured demand is needed to justify this small surface.

Inspected base: `d3430a0a0` on `origin/main`. Existing meeting URL controls
(#1198 / #1211) already establish bundle schemes, explicit opt-in, and
cold-launch buffering. `DictationFlowCoordinator` owns persistent capture,
permissions, entitlements, hotkey synchronization, insertion, and history.
`DictationFlowStateMachine` already handles stop during entitlement/service
startup. No new capture engine, IPC server, or CLI dependency is necessary.

The important mismatch is the manual start action: it deliberately supports
rapid replacement of active recordings and undo windows. Exposing it directly
would let a repeated URL discard work. A small state-dependent command adapter
makes URL start idempotent and protects pending stop, processing, undo, and
finishing (which may still own insertion). Toggle is explicitly non-idempotent.

This advances ADR-027's safe automation of local speech capture. It does not
need semantic classification or an AI integration; Jev is not used.

## Context zone and implementation plan

- In scope: strict start/stop/toggle URLs, independent default-off consent,
  existing persistent dictation, bounded launch buffering, searchable Settings,
  contract/integration docs, focused tests, independent review, and a PR.
- Preserve: existing shortcut/pill behavior, microphone/entitlement/interaction
  gates, meeting control, local transcription, formatter choices, paste/history,
  retention, stable/development scheme isolation, and unrelated worktrees.
- Exclude: parameters, AI-polish overrides, targeting applications, status or
  callback protocols, authenticated clients, destructive commands, new CLI
  recording commands, and changes to the dictation state machine itself.
- Verification: focused parser/router, state matrix, coordinator, Settings, and
  telemetry tests; source review of app wiring; independent correctness and
  maintainability/security review. Skip local CI/full-suite gate as requested.
- Manual evidence boundary: packaged warm/cold Launch Services, native focus,
  real audio, and Stream Deck/launcher behavior remain separate qualification.

## Design choices

Use a dedicated dictation parser/router matching the small existing meeting
pattern. Avoid a generic automation framework or refactoring working meeting
behavior. Add `url_control` as a bounded telemetry trigger rather than labeling
URL starts as a hotkey or menu click. Never log input URLs.

Background delivery is part of the integration guidance (`open -g`), because
regular URL launching can steal the target field's focus. The handler never
activates a window or infers an insertion target. No claim that this removes
MacParakeet's own microphone/Accessibility requirements is made.

## Completion record

Implementation and automated/manual verification results are recorded in the
PR. The versioned contract is the source of truth for supported behavior.
