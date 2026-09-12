# Share Service v1

> Status: **Proposed**

## Purpose

This contract defines anonymous owner authority, the public and owner HTTP resources, optimistic concurrency, lifecycle, retention, and local deletion coordination for encrypted share snapshots.
The service accepts only [Share Link and Bundle v1](share-link-bundle-v1.md) envelopes and never needs UI concepts such as notes, summaries, or Share-sheet toggles.

## Producers and consumers

- **Producers:** the Mac app's sharing coordinator and the hosted share service.
- **Consumers:** the Mac app's management client, the first-party browser viewer, service operations, and contract tests in both repositories.
- **Authority:** the service is authoritative for remote access, expiration, current revision, and deletion receipts; the local Library remains authoritative for source content.

## Owner and recovery credentials

The app creates the following values with a cryptographically secure random generator:

```text
device token:   mpd1.<16-byte-device-selector-base64url>.<32-byte-device-secret-base64url>
recovery token: mpr1.<16-byte-owner-id-base64url>.<32-byte-recovery-secret-base64url>
```

The server stores domain-separated SHA-256 verifiers, never the secret portion:

```text
SHA-256("mp-device-v1\0" || selector-bytes || secret-bytes)
SHA-256("mp-recovery-v1\0" || owner-id-bytes || secret-bytes)
SHA-256("mp-locator-v1\0" || locator-bytes)
```

- Comparisons are constant-time.
- Unknown selectors and incorrect secrets return the same response.
- Device tokens use `Authorization: Bearer <device-token>` and never appear in URLs or request bodies.
- The Mac stores the device token and per-share content keys in a dedicated, non-synchronizing, device-only Keychain service.
- Full links, fragments, device secrets, and recovery secrets are never stored in GRDB, UserDefaults, or logs.
- The owner credential is generated silently on first publication and is required for creation, updates, expiry changes, listing, and permanent stop.
- A recovery token is optional, generated rather than user-chosen, and displayed only when the owner asks to create or replace one.
- Its 32-byte random secret provides 256 bits of entropy; recovery attempts are rate-limited per owner and coarse source signal, with unknown and incorrect tokens indistinguishable.
- The current device token may install, replace, or remove its recovery verifier without rotating recipient links.
- Recovery atomically installs a client-generated device verifier in a new credential generation and invalidates the prior device and recovery credentials; the new token secret remains local.
- A recovered device token may list opaque metadata, change an active expiration, permanently stop any owner share, and create new shares. It may replace content only for shares created in its own credential generation; earlier shares remain management-only because recovery does not restore their content keys or complete URLs.
- Recovery never returns content keys, ciphertext, plaintext, or complete recipient URLs.
- The owner remains continuous and has at most one current recovery code across credential generations. Recovery invalidates the imported code and offers one replacement; it never creates a second owner context or requires a bundle of recovery artifacts.

## Resource model

An owner-visible share resource has this stable shape:

```json
{
  "id": "22-character-client-generated-share-id",
  "locatorCommitment": "43-character-base64url-sha256",
  "contentRevision": 2,
  "version": 4,
  "contentWritable": true,
  "accessState": "active",
  "deletionState": "retained",
  "ciphertextBytes": 48213,
  "createdAt": "2026-09-11T22:00:00Z",
  "updatedAt": "2026-09-12T01:00:00Z",
  "expiresAt": "2026-10-11T22:00:00Z",
  "maxExpiresAt": "2026-12-10T22:00:00Z",
  "terminalAt": null
}
```

- `id` is 16 client-generated random bytes encoded as 22 unpadded base64url characters.
- `locatorCommitment` is the 32-byte domain-separated locator commitment encoded as unpadded base64url. It lets a recovered owner stop a listed share and lets a local outbox reconcile terminal deletion without disclosing the locator.
- `contentRevision` begins at `1` and increments only for content publication.
- `version` begins at `1`, increments for every content, expiry, or lifecycle mutation, and produces a strong ETag such as `"v4"`.
- `contentWritable` is true only when the current credential generation created the share; the app additionally requires the local content key before offering update.
- `accessState` is `active`, `expired`, or `stopped`; expired and stopped are terminal.
- `deletionState` is `retained`, `pending`, or `complete` and does not weaken `accessState`.
- An active share becomes unavailable when server time is at or after `expiresAt`, even if a cleanup job has not run.
- Owner-visible resources and reconciliation use `id` and `locatorCommitment`; the plaintext public locator is accepted at creation and retained only on the originating Mac, not returned by listing or recovery.

The service may persist only opaque owner, device, share, and object identifiers; credential and locator verifiers; schema and revision numbers; ciphertext byte count and checksum; lifecycle timestamps; terminal and deletion states; quota counters; idempotency receipts; and sterile abuse-case state.
Titles, source details, speaker names, selection flags, local IDs, content-derived values, fragment keys, and plaintext are absent.
One exception to ordinary terminal retention is a permanent, one-way commitment for each accepted locator, stored without owner linkage, share metadata, or timestamps solely to prevent deliberate locator reuse.

## HTTP API

All bodies are JSON and times are RFC 3339 UTC at whole-second precision.
Every owner enrollment, recovery, and share mutation requires a 128-bit unpadded-base64url `Idempotency-Key` unless an endpoint states otherwise.
Every owner resource read or mutation first verifies that the presenting credential owns the target share; a wrong-owner target is indistinguishable from an unknown target and no state is revealed or changed.

| Method | Path | Stable semantics |
|---|---|---|
| `GET` | `/api/v1/capabilities` | Returns supported envelope/bundle versions and current service limits; it does not encode UI presets. |
| `POST` | `/api/v1/owners` | Registers client-generated owner, device selector/verifier, and optional recovery verifier; returns no secret. |
| `POST` | `/api/v1/owners/recover` | Authenticates a recovery token, atomically advances the credential generation, installs its device verifier and optional replacement recovery verifier, and invalidates old credentials. |
| `PUT` | `/api/v1/owners/recovery` | The current device token installs, replaces, or removes the optional recovery verifier; the recovery secret remains client-generated. |
| `GET` | `/api/v1/shares?limit=50&cursor=...` | Reconciles owner-visible metadata; returns no ciphertext or content-derived fields. |
| `PUT` | `/api/v1/shares/{share-id}` | Creates with `If-None-Match: *` or publishes the next content revision with `If-Match: "vN"`. |
| `PATCH` | `/api/v1/shares/{share-id}/expiry` | Changes the exact expiration of an active share with `If-Match`; it does not change `contentRevision`. |
| `DELETE` | `/api/v1/shares/{share-id}` | Permanently stops access, begins ciphertext deletion, and returns the current deletion receipt; it requires the opaque locator commitment and is idempotent and terminal. |
| `GET` | `/api/v1/s/{locator}` | Returns the current encrypted envelope only for an active, unexpired locator. |
| `POST` | `/api/v1/s/{locator}/reports` | Creates a rate-limited, content-free abuse case and always returns a generic receipt; it never triggers automatic quarantine. |
| `GET` | `/s/{locator}` | Serves a generic static viewer shell without share-specific metadata. |

Capabilities returns protocol ceilings rather than product presentation:

```json
{
  "envelopeVersions": [1],
  "bundleVersions": [1],
  "maxPlaintextBytes": 2097152,
  "maxCiphertextAndTagBytes": 2097168,
  "maxLifetimeSeconds": 7776000
}
```

Owner enrollment sends client-generated selectors and verifiers, all encoded as unpadded base64url:

```json
{
  "ownerId": "16-random-bytes",
  "deviceSelector": "16-random-bytes",
  "deviceVerifier": "32-sha256-bytes",
  "recoveryVerifier": "optional-32-sha256-bytes"
}
```

Recovery uses `Authorization: Recovery <recovery-token>` and supplies a fresh client-generated device selector/verifier plus an optional replacement recovery verifier.
The service response contains owner metadata and credential scope, never a secret.
Recovery configuration uses a normal full owner token and contains `recoveryVerifier`, whose `null` value removes recovery after explicit confirmation.

Create and update use this body shape:

```json
{
  "locator": "22-character-public-locator",
  "contentRevision": 1,
  "expiresAt": "2026-10-11T22:00:00Z",
  "envelope": {}
}
```

`expiresAt` is required on create and omitted on update.
Update retains the existing locator and expiry and publishes exactly `contentRevision + 1`.
Expiry changes contain only `expiresAt`.
Terminal delete contains the opaque commitment returned at creation or owner reconciliation so recovery and post-tombstone retries never require the plaintext locator:

```json
{
  "locatorCommitment": "43-character-base64url-sha256"
}
```

An abuse report contains only a bounded category; the viewer never submits decrypted text, the fragment, or user-authored report prose automatically.
Reports create cases only and never change access automatically.
A documented operator decision may permanently stop the referenced share through an audited internal control that does not grant plaintext access; the public API exposes no administrative credential.

The public fetch response contains only `contentRevision`, `expiresAt`, and the envelope.
Malformed, unknown, expired, stopped, deleted, and administratively unavailable locators all return `404 share_unavailable` with indistinguishable public behavior.
Payload responses use `Cache-Control: no-store`, and authorization depends on authoritative state rather than cache invalidation.

## Expiration

- Creation requires `now < expiresAt <= createdAt + 7,776,000 seconds`.
- The client default is `createdAt + 2,592,000 seconds`.
- `maxExpiresAt` is fixed when the share is first created and never moves.
- Expiry changes are accepted only while the share is active and before its existing expiration.
- Content updates never extend the lifetime.
- Invalid values are rejected rather than clamped or silently rounded.

## Idempotency, concurrency, and publication

- Idempotency scope is owner, method, canonical path, and key.
- The service stores the request digest and original response for 24 hours.
- Reusing a key with the same digest returns the original response; reusing it with a different digest returns `409 idempotency_conflict`.
- A client-generated share ID plus `If-None-Match: *` prevents duplicate creation after idempotency receipts expire.
- Creation atomically reserves the locator commitment; an active or retired locator can never be assigned again and returns `409 locator_conflict`.
- Creation records the current credential generation. A token may replace content only when that generation matches; credential recovery therefore cannot alter pre-recovery snapshots but can publish and update new ones.
- Content and expiry mutations use ETag compare-and-swap; stale writes return `412 version_conflict` with the current version and ETag.
- Permanent stop does not require compare-and-swap and wins over racing nonterminal mutations.
- Recovery is an atomic credential replacement. After a lost response, the client tests the newly generated credential rather than reusing the one-time recovery token.

Publishing a revision follows this observable invariant:

1. Write an immutable ciphertext object for the share and content revision.
2. Verify its byte count and checksum.
3. Validate state and version, then advance the authoritative current pointer in one primary metadata transaction.
4. Delete superseded ciphertext asynchronously.

A failed metadata commit may leave an unreachable object for bounded cleanup, but metadata must never point to a missing object.
A failed or conflicting update leaves the prior confirmed revision public.
Stop and expiry commit access denial before object deletion.

## Stop and deletion receipts

An access-stopped receipt means the authoritative terminal-state commit succeeded and every later public payload fetch fails.
It does not claim that a recipient copy, loaded tab, browser history, screenshot, or downloaded file was erased.

`DELETE` returns `202` while `deletionState` is `pending` and `200` only when it is `complete`.
A deletion-complete receipt means every known current, superseded, and orphan ciphertext object for the share has been confirmed absent from live storage.
It does not shorten a hosting provider's documented recovery-history bound.

An authenticated `DELETE` for a share that is already absent returns `200` with a locator-scoped terminal-absence receipt only when the supplied commitment matches an existing retired commitment, even after the idempotency receipt and owner-linked tombstone have expired.
The receipt confirms only that this locator can never be served or reassigned and lets a long-offline client complete its pending operation; it makes no owner-history claim and does not recreate the share or its tombstone.
For a live share, ordinary owner authorization and an exact commitment match are both required.
An unknown commitment, a commitment still active under another owner, and a wrong-owner live share return the same `404 not_found` owner-API response.

## Local lifecycle invariant

The app's internal schema may evolve, but an attached local publication ledger must preserve the local owner reference, remote share ID, locator commitment, locally available locator, content revision, ETag/version, state, exact expiration, nullable local transcription association, selected projection manifest, local content digest for stale detection, last confirmed receipt, and durable ordered outbox operations with their idempotency keys.
The per-share content key remains in its dedicated Keychain namespace while same-link update is possible; if it is unavailable, management may still stop the share but cannot update it.

Deleting a local source must transactionally detach each share record and enqueue its terminal `DELETE` before the source row disappears.
The share and outbox records must not cascade with the transcription.
Detachment clears the projection manifest, content digest, and every other content-derived local field, then removes the per-share content key from Keychain as soon as the terminal intent is durable; bounded cleanup retries an interrupted key removal.
Offline UI says the remote stop is pending and the link may still work; it may say stopped or deleted only after the corresponding service receipt.

## Retention and logging

- Current ciphertext remains fetchable only while access is active and may remain in live storage solely during bounded terminal cleanup.
- Superseded, expired, stopped, and orphan ciphertext deletion begins immediately and completes within 24 hours.
- A stopped or expired share retains only an owner-linkable tombstone and operation receipts for at most 30 days after confirmed ciphertext deletion.
- After that tombstone is removed, only the non-owner-linkable locator commitment remains; it has no content, lifecycle timestamp, or management authority and is retained solely to preserve permanent revocation.
- Idempotency receipts and content-free abuse cases are retained for at most 24 hours and 30 days respectively.
- Edge abuse controls may process a coarse or keyed network signal for at most 24 hours; application storage never persists a raw recipient IP address.
- Provider recovery history may retain encrypted operational data for its published window, which must be documented before launch; deleted material must not be restored into the live service.
- Recipient application request logs are disabled.
- Application, edge, APM, crash, diagnostic, and support paths exclude Authorization values, recovery tokens, fragments, complete links, locator-bearing paths, request bodies, source metadata, decrypted content, and ciphertext.
- The service stores no recipient referrer, cookie, user-agent history, view history, or product analytics.

The hosting provider necessarily processes network metadata such as a request IP to deliver and defend the service.
The public privacy notice must describe that fact separately from MacParakeet application storage.

## Error contract

Errors use this envelope; `message` is non-stable display copy and `requestId` is a sterile support identifier:

```json
{
  "error": {
    "code": "version_conflict",
    "message": "The shared page changed before this update completed.",
    "retryable": false,
    "requestId": "opaque-support-id"
  }
}
```

Stable codes are `invalid_request` (400), `unauthorized` (401), `not_found` (404 owner API only), `share_unavailable` (404 public API), `locator_conflict` (409), `idempotency_conflict` (409), `payload_too_large` (413), `version_conflict` (412), `precondition_required` (428), `unsupported_version` (422), `invalid_expiry` (422), `quota_exceeded` (429), `rate_limited` (429 with `Retry-After`), `service_unavailable` (503), and `internal_error` (500).
The service never returns decrypted-content validation errors because it cannot perform that validation.

## Non-stable behavior

Human-readable copy, quota numbers below protocol ceilings, abuse thresholds, storage layout, database product, object-store product, queue implementation, and UI presets may change without a contract version bump when stable semantics remain intact.

## Versioning and compatibility

Additive response fields are allowed when existing clients continue to work.
Removing or changing a stable field, credential authority, state transition, endpoint semantic, error code, retention ceiling, or receipt meaning requires a version bump and an active-share migration or compatibility plan.

## Tests that enforce this

Native tests cover credential storage, later recovery setup, expiry arithmetic, ETag and idempotency behavior, outbox ordering and restart recovery, lost responses, local deletion without cascading share state, locator-commitment terminal reconciliation, and receipt-driven UI state.
Service contract tests cover owner authentication; recovery setup and rotation; credential-generation content-write scope; recovered live-share stop through listed locator commitments; correct-owner, wrong-owner, unknown, and post-tombstone delete responses; public-unavailable equivalence; exact expiry; terminal-operation precedence; permanent locator non-reuse; publication ordering; orphan and revision cleanup; retention; quotas; abuse-report non-enforcement; and log redaction.
Browser tests cover local decrypt, search, copy, Markdown and text downloads, print, accessibility, strict CSP, generic previews, `no-referrer`, no external requests, wrong-key or unavailable states, and hostile Markdown or segment content rendered without executable HTML, event handlers, or URLs.

## When this changes

Update this contract, [Share Link and Bundle v1](share-link-bundle-v1.md), native and service tests, viewer tests, privacy documentation, and any active-service migration or compatibility layer in the same coordinated change.
