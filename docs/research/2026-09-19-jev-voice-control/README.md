# Voice Control

MacParakeet Voice Control turns ordinary speech or a typed inbox command into action on the app already in front of you. Observation and effects use native macOS Accessibility. Jev chooses among competing options when the host cannot compile a unique next step. It does not browse or write scripts. It can judge observed landings; it does not issue receipts.

This is a DEBUG experiment (`--enable-voice-control`). Live Google Flights results and the integrated microphone path are still unproven. Ordinary dictation is unchanged.

[Interactive walkthrough](walkthrough.html) · [Capability matrix](release-scope.md) · [Contract](../../../spec/contracts/voice-control.md) · [ADR-033](../../../spec/adr/033-explicit-voice-control.md)

## Read in this order

1. [Product](product.md) — what it feels like, confirmation, modes, intent capture
2. [Architecture](architecture.md) — observe → compile → choose → act → verify
3. [Tools](tools.md) — what compiles locally without a model
4. [Everyday use](everyday-use-cases.md) — the catalog of moments that should feel magic
5. [Evidence](evidence.md) — what is proven, what is not
6. [Later](later.md) — overlays, TTS, remaining holes

## Reference material

- [UX storyboards](ux-storyboards.md)
- [Route catalog](routing-catalog.md)
- [Evaluation](evaluation.md)
- [Native Flights qualification](testing-handoff.md)
- [Lessons from prior computer-use systems](references.md)
- [Native Accessibility direction](native-accessibility-direction.md)
- [Historical browser extension](historical-browser-extension/README.md) — not a shipping path

## Constraints that do not move

Native Accessibility is the only observation and execution adapter. No required browser extension, CDP, or special profile. Speech stays on the Mac. Confirm only payment, destructive deletion, and send. Fail open: a missing key, timeout, or malformed answer executes nothing.
