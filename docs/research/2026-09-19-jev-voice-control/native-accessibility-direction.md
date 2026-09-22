# Native Accessibility for Voice Control

Voice Control works with the app already in front of you, including the existing browser, through macOS Accessibility. Browser control must not require a Chrome (or other) extension.

The intended experience: install MacParakeet, grant the relevant macOS permissions, enable Voice Control, and speak. An extension, developer mode, an extension ID, native-host registration, or tab pairing makes browser control feel like a separate product.

The browser is another application. Webpage content, browser chrome, and native Mac apps share one interaction model.

An extension can provide extra DOM detail. That has not been shown to be necessary for the visible workflows this experiment targets. A successful extension recording proves that implementation, not an extension requirement.

## End state

- Supported visible interfaces are controlled through native Accessibility, including webpage content and native application controls.
- Users stay in their existing browser and session. No required extension, automation browser, remote-debugging setup, or restart.
- Speech becomes finalized command text through MacParakeet’s local speech infrastructure. Routing, Jev Choice when needed, local execution, and observed postconditions follow. Ordinary dictation remains ordinary dictation.
- Cloud command context remains an explicit Voice Control choice. Native execution does not mean Jev inference is local.
- Unsupported controls produce a clear limitation. Do not claim unrestricted control, and do not introduce an extension as the default answer to a gap.

## Confirmation

An explicit command authorizes its ordinary implied steps. Navigation, opening selectors, choosing dates, filling requested values, scrolling, and searching proceed without repeated prompts. Payment, destructive deletion, and external send remain deliberate. Searching for a flight does not authorize buying a ticket.

If the target, amount, recipient, or requested outcome is missing, ask that slot. Do not ask “are you sure?” for ordinary navigation.

Target freshness, Stop, consent, effect verification, and protection against duplicate or unknown effects stay. Removing unnecessary prompts does not remove those guarantees.

Spoken confirmation of a purchase summary is later. See [product](product.md) and [later](later.md).

## Evidence that would establish success

Representative browser and native-app workflows through the actual native Accessibility path, without an extension for observation or actions. Include a multistep browser task comparable to flight search, plus correction, cancellation, and a changing interface.

Typed commands qualify the controller. The existing audio-to-text pipeline is accepted as upstream; a focused integrated-voice smoke test still has to show the connection behaves. Fixture success is not universal website compatibility or a stable release. Current honesty: [evidence](evidence.md).

## Settled alongside this

Keep the experimental panel. Bring-your-own Jev key. Keep voice-to-Transform while leaving Transforms themselves unchanged. Correction, recovery, and local traces are first-class. Manual takeover is the initial mixed-input behavior; later, speech, typing, and mouse should interleave without fighting. Larger experimental task budgets are acceptable; Stop and no-progress protection stay.
