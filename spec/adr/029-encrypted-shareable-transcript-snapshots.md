# ADR-029: Explicit Encrypted Share Snapshots

> Status: **Accepted; implementation planned**
> Date: 2026-09-11

## Context

MacParakeet can copy and export transcript text, but recipients must assemble their own presentation and the publisher cannot later stop access.
A hosted link would be useful for meetings, imported media, and other Library items, but it must not turn the local corpus into a cloud account or weaken the promise that audio stays on the Mac.

The feature needs three independent capabilities: recipient access to one share, anonymous owner authority to manage shares, and content encryption that keeps routine hosting infrastructure from reading the text.
A machine fingerprint or IP address is not a safe substitute for any of them because it is not a secret, is unreliable, and is difficult to rotate or recover.

## Decision

MacParakeet will treat sharing as an explicit encrypted export with its own lifecycle.

- A share is a separately persisted, text-only snapshot derived from one local Library item after an exact user preview.
- The local Library remains authoritative, and later local edits never publish automatically.
- Source audio and non-allowlisted local metadata are structurally excluded.
- The Mac encrypts a versioned share bundle with AES-256-GCM before upload.
- The complete recipient URL is a bearer capability: a random public locator is in the path and a random 256-bit content key is in the URL fragment, which is not sent to the service.
- Explicit updates retain the locator and key, use a fresh nonce, and atomically replace the publicly current encrypted revision.
- The service exposes only active, unexpired ciphertext, begins bounded cleanup on stop or expiry, and enforces a maximum total lifetime of 90 days from original publication.
- On first use, the app silently creates a random owner bearer credential in a dedicated, non-synchronizing, device-only Keychain namespace.
- An optional generated recovery code restores management of existing shares and normal publication of new shares; it cannot decrypt or replace pre-recovery content or reconstruct lost links.
- A device token may configure recovery only while none exists. Replacing or removing an existing verifier also requires the current recovery code, preventing a stolen device token from displacing the saved recovery path.
- Losing a configured recovery code leaves normal device management intact but permits no in-place reset; after stopping all outstanding shares, the app may enroll a fresh anonymous owner for future shares.
- Recovery replaces the prior management credential; without a saved recovery code, device-state loss also loses guaranteed early revocation.
- Stop sharing is permanent and immediately denies future service reads before asynchronous ciphertext cleanup.
- A stopped or expired locator is never reassigned; after bounded owner-linked retention, only a one-way owner-unlinked reservation remains.
- Local source deletion preserves a durable stop operation when the service is unreachable.
- Recipient access is accountless and read-only, with no password, analytics, comments, collaboration, or content-bearing previews in v1; content-free abuse reports never trigger automatic blocking.
- Sharing uses a separate release flag, storage, credentials, logging policy, and deployment surface from telemetry.

The stable link, bundle, authentication, API, lifecycle, and deletion semantics are defined in [Share Link and Bundle v1](../contracts/share-link-bundle-v1.md) and [Share Service v1](../contracts/share-service-v1.md).
The UI behavior is summarized in [Shareable Transcript Snapshots](../15-shareable-transcripts.md).

## Consequences

The Library and audio remain local while a publisher can disclose a deliberately smaller artifact and later stop future access.
An object-store or database disclosure yields ciphertext rather than the selected text, assuming sound cryptography and an uncompromised viewer.
The service contract stays independent of UI concepts such as Share-sheet toggles.

Anyone with the complete URL can read, copy, and forward the content.
Stopping cannot erase recipient copies or plaintext already loaded into a browser.
Keeping one URL through updates means a compromised URL cannot be repaired in place; the owner must create a new share and permanently stop the old one.

The viewer origin is part of the trust boundary.
First-party JavaScript receives the fragment key and plaintext, so MacParakeet must not claim protection against a malicious viewer deployment or absolute zero knowledge.
Encrypted content also prevents server-side search, meaningful content previews, and ordinary content moderation.

The feature adds hosted operations, local publication and outbox records, Keychain state, deletion coordination, abuse controls, and current privacy disclosures to an otherwise local corpus.
Losing the originating Keychain state without a saved recovery code leaves remote management unavailable until mandatory expiry.

## Alternatives considered

- **Provider-readable pages:** rejected because transcript plaintext would become ordinary server data and weaken the product's privacy differentiation.
- **Passwords or recipient accounts:** deferred because the bearer URL already provides the intended v1 access model and additional identity would expand UX and recovery substantially.
- **Machine fingerprint or IP identity:** rejected because neither is a durable, private, revocable secret.
- **Immutable links only:** rejected because explicit same-link updates preserve a useful recipient URL without creating automatic synchronization.
- **Automatic synchronization:** rejected because local edits must not silently widen or change a disclosure.
- **Comments in v1:** deferred because anonymous encrypted writes require a separate authorization, identity, moderation, notification, retention, and conflict model.
- **Secure Enclave request signing, App Attest, passkeys, or accounts:** deferred until measured abuse or multi-device requirements justify them.

## Release gates

Release remains blocked until shared Swift/browser cryptographic fixtures pass, endpoint and log capture proves fragments and plaintext stay out of requests and logs, stop and expiry deny reads at their exact boundary, all ciphertext revisions are purged within the documented window, local deletion survives offline retries, common recipient channels preserve the fragment, privacy and abuse procedures match runtime behavior, and the viewer deployment receives independent security review.

## Related decisions

- [ADR-002](002-local-only.md): local speech processing and explicit external text surfaces.
- [ADR-027](027-product-north-star.md): safe exposure of the local speech corpus to users and their agents.
