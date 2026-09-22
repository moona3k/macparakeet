# Licensing

> Retained purchase-activation plumbing. Currently dormant; **do not delete**.

## Entry point

`EntitlementsService` — the single read/write surface for entitlement
state. Every code path that asks "is this build licensed?" goes
through it.

## What's here

- `EntitlementsService.swift` — entitlement state machine; owns trial
  and licensed transitions and persists to keychain via
  `KeyValueStore`.
- `Entitlements.swift` — pure value types describing the entitlement
  state.
- `LemonSqueezyLicenseAPI.swift` — network client for license-key
  activation and validation against LemonSqueezy.
- `KeychainKeyValueStore.swift` + `KeyValueStore.swift` — generic
  keychain-backed K/V used by this folder. Not licensing-specific in
  shape, but currently used only here.

## Cross-references

- [ADR-003](../../../spec/adr/003-one-time-purchase.md) — one-time purchase
  pricing (historical, kept for context).
- [ADR-006](../../../spec/adr/006-trial-and-license-activation.md) — dormant
  trial + license activation and the retained-code guardrail.

## What to know before editing

**This is retained future-option code, not dead code.** Current
public DMG builds are free and GPL-3.0; entitlements are always
unlocked. The plumbing here exists so a future GPL-compatible paid
distribution channel can be activated without re-implementing
licensing from scratch.

**Do not delete `EntitlementsService`, `LemonSqueezyLicenseAPI`,
entitlement state types, or trial/license telemetry as dead code.**
This applies to refactors, "cleanup" passes, lint sweeps, and any
agent that thinks the unused code looks suspicious. The only
acceptable removal path is: explicit owner direction + an ADR or
spec update reflecting the decision.

**Do not introduce active gating from these types into user-facing
flows.** `EntitlementsChecking.currentState(now:)` always returns `.unlocked`,
and `assertCanTranscribe(now:)` does not throw in current free/GPL builds.
There is no `isLicensed` API. Preserve those semantics unless an explicit
product decision and governing ADR/spec change authorize a different model.

**Dormant gating does not mean no licensing I/O.** App setup calls
`refreshValidationIfNeeded()`, and CLI transcription does so when
`--enforce-entitlements` is requested. A retained license key and instance ID
can trigger a LemonSqueezy validation request when its cached validation is
at least a day old. No stored activation means no validation request; the
result never locks the current free build.

**Keychain access is not free on first call.** The first read after
launch can take tens of milliseconds. Cache results in callers if
hot-pathing.

## How to verify a change

- `swift test --filter EntitlementsService` (and any
  `LemonSqueezy*` tests that exist).
- `swift test` — full suite. Licensing changes can ripple through
  telemetry (entitlement state is included in some events).
- Manual: confirm a fresh launch still treats the build as licensed
  (current behaviour) and that no UI surface gates on entitlement
  state.
