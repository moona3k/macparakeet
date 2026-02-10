# ADR 005: First-Run Onboarding Window

Date: 2026-02-10

## Context

MacParakeet is a menu bar app with a global Fn hotkey and paste automation. To deliver a premium first-run experience, we need to:

- Explain the core interaction model (Fn hotkey, stop/paste, cancel).
- Acquire required permissions (Microphone, Accessibility).
- Prepare the local STT engine (Python/uv + daemon) so the first dictation feels fast and reliable.

Without onboarding, users encounter failures out of context (missing permissions, slow first warm-up) and the product feels brittle.

## Decision

Implement a dedicated first-run onboarding window that appears automatically when the app starts and onboarding has not been completed.

The onboarding flow is linear and step-based:

1. Welcome
2. Microphone permission
3. Accessibility permission
4. Hotkey instructions
5. Speech engine warm-up (best effort; retry or defer)
6. Ready

The onboarding can also be launched manually from Settings.

## Consequences

- Users get a guided, premium setup that reduces first-run friction.
- Hotkey manager is restarted after onboarding to reliably start listening once Accessibility is granted.
- Speech engine warm-up happens explicitly during onboarding to reduce latency on the first dictation.
- Onboarding completion is stored in `UserDefaults` as an ISO8601 timestamp.

## Alternatives Considered

- Inline onboarding inside the main window: rejected because the app is menu-bar-first and may never open the main window on first launch.
- No onboarding: rejected due to permission and warm-up failures appearing as unexplained errors.

