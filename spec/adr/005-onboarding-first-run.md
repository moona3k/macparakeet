# ADR 005: First-Run Onboarding Window

Date: 2026-02-10

## Context

MacParakeet is a menu bar app with a configurable global hotkey (default: Fn) and paste automation. To deliver a premium first-run experience, we need to:

- Explain the core interaction model (hotkey, stop/paste, cancel).
- Acquire required permissions (Microphone, Accessibility).
- Prepare local models (Parakeet STT + Qwen LLM) so dictation and AI refinement are ready on first use.

Without onboarding, users encounter failures out of context (missing permissions, slow first warm-up) and the product feels brittle.

## Decision

Implement a dedicated first-run onboarding window that appears automatically when the app starts and onboarding has not been completed.

The onboarding flow is linear and step-based:

1. Welcome
2. Microphone permission
3. Accessibility permission
4. Hotkey instructions
5. Local model setup (Parakeet + Qwen, required to continue; retry available)
6. Ready

The onboarding can also be launched manually from Settings.

If onboarding is closed before completion, the app shows an explicit confirmation dialog. If the user exits setup anyway, onboarding is shown again on the next app activation until completion.

## Consequences

- Users get a guided, premium setup that reduces first-run friction.
- Hotkey manager is restarted after onboarding to reliably start listening once Accessibility is granted.
- Both local models are downloaded/warmed during onboarding to reduce first-use latency for dictation and AI refinement.
- Onboarding completion is stored in `UserDefaults` as an ISO8601 timestamp.
- Incomplete setup is never silently dismissed; users either continue setup or explicitly defer it.

## Alternatives Considered

- Inline onboarding inside the main window: rejected because the app is menu-bar-first and may never open the main window on first launch.
- No onboarding: rejected due to permission and warm-up failures appearing as unexplained errors.
