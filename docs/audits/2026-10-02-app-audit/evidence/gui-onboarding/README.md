# Synthetic native onboarding renders

These are screenshots of the actual `OnboardingFlowView` in an offscreen
AppKit `NSHostingView`, at its production 760 × 600-point size. They contain
synthetic state only. The probe injects fake permission/STT implementations,
network/cache/disk checks, a unique defaults suite, and no-op telemetry. It
does not start the app coordinator, activate a window, capture audio, download
models, request real permissions, or inspect the user's running application.

`before/` contains eight baseline renders. `after/` contains the matching eight
renders and a ninth that programmatically scrolls the real hosted scroll view
to its bottom, verifies the viewport changed, and shows both recovery controls.
`receipt.json` records image hashes, dimensions, and coordinated test outcomes.

The finding is visible in `before/03-offline-hotkey-phase.png`: the failure card
overlaps its heading and crowds its buttons against the footer. After the fix,
`after/03-offline-hotkey-phase.png` separates the heading and wraps the error;
`after/03b-offline-hotkey-phase-scrolled.png` shows the complete retry guidance
and controls after scrolling. The two dictation-phase renders provide a
control for the same failure content after key confirmation.

The audit-only probe is archived as `OnboardingAuditRenderTests.swift.txt`,
rather than leaving a skipped audit test in the permanent suite. To reproduce
in a dedicated checkout, temporarily copy it to
`Tests/MacParakeetTests/Views/Onboarding/OnboardingAuditRenderTests.swift`, then
run:

```bash
MACPARAKEET_AUDIT_RENDER_DIR="$PWD/.build/onboarding-audit-capture" \
  swift test --filter OnboardingAuditRenderTests
```

Remove only that temporary test file afterward. Its fixture helper uses the
test suite's standard unique-defaults cleanup. The compiler state must belong
to this checkout; do not run concurrent SwiftPM builds against it.

The renders prove view layout and the hosted scroll action. They do not prove
TCC prompt behavior, actual model loading, speech accuracy, physical hotkeys,
cross-application paste, VoiceOver, Reduce Motion, or Increase Contrast. The
success render injects a synthetic delivered transcript; it is not evidence of
a successful microphone-to-transcript run.
