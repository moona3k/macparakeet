# Historical browser extension experiment

Retired from the product on 2026-09-19 after the user selected native macOS Accessibility for all visible computer control, including the existing browser. These Swift files are preserved as research evidence and are not compiled by any package target. There is no production extension, native-messaging host, registration service, socket bridge, or browser pairing requirement.

The JavaScript extension, developer installer, and earlier fixture harness remain under `integrations/voice-control-browser/` for historical inspection only. The earlier recording qualifies that retired experimental path; it does not establish native browser control.

Preserved sources include the adapter, framing transport, multiplexer, registration service, native host, and focused tests. Their earlier command examples and imports may no longer build against current production types. Do not restore them to product dependencies or run their installer as part of normal Voice Control setup.

No user's installed extension, native-host registration, pairing configuration, profile, browser session, or local files were changed by retiring these repository sources.

The active direction is [native Accessibility](../native-accessibility-direction.md) and [product](../product.md). Native-browser qualification belongs in `scripts/dev/voice-control/` and [testing-handoff](../testing-handoff.md).
