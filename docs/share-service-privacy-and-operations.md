# Share Service Privacy and Operations

> Status: **Pre-implementation release contract**
> Governing decision: [ADR-029](../spec/adr/029-encrypted-shareable-transcript-snapshots.md)
> Wire contracts: [Share Link and Bundle v1](../spec/contracts/share-link-bundle-v1.md) and [Share Service v1](../spec/contracts/share-service-v1.md)

## Plain-language privacy model

MacParakeet sharing is an explicit disclosure, not a backup or sync system.
The publisher chooses and previews a text snapshot, the Mac encrypts it, and the hosted service stores the encrypted result until the link expires or is stopped.
Audio never enters the share path.

The complete URL is the access credential.
Anyone who receives it can read, copy, save, screenshot, and forward the content while the link remains active.
Stopping a link blocks future service access but cannot retrieve copies a recipient already made.

## What crosses the network

| Data | Leaves the Mac? | Server can read it? | Notes |
|---|---:|---:|---|
| Selected summary, notes, transcript, and display metadata | Yes, encrypted | No during normal operation | Only the exact previewed bundle is encrypted and uploaded. |
| Audio or video | No | No | Structurally absent from the bundle and API. |
| Content key | No HTTP request | No during normal operation | It is stored after `#` in the complete URL and used by the browser. |
| Ciphertext and authentication data | Yes | Yes, as opaque bytes | Required to store and deliver the share. |
| Opaque share, owner, object, and revision identifiers | Yes | Yes | Required for lifecycle and abuse controls. |
| One-way retired locator commitment | Yes | Yes | Retained without owner linkage, content, or timestamps solely so a stopped URL can never be reassigned. |
| Creation, update, expiration, terminal, size, and deletion state | Yes | Yes | Content-free operational metadata. |
| Owner bearer token | Yes, transiently over HTTPS | Yes during authentication | The secret is never persisted or logged; only a verifier is stored. |
| Recovery token | Yes during recovery or recovery-verifier replacement/removal | Yes during authentication | Successful recovery consumes the token. The current token is also required to replace or remove an existing verifier and is invalidated atomically by that change. Only a verifier is stored. |
| Recipient network metadata | Necessarily processed by the host | The network provider can observe it | The application does not persist raw IPs, referrers, user-agent history, or view history. |

The server never receives the rest of the Library, a fragment key, a complete recipient URL, local paths, hidden record identifiers, model details, prompts, or unselected metadata.

## Claims MacParakeet may make

Accurate claims include:

- The Library and source audio stay on the Mac.
- Only the selected text snapshot is uploaded, and it is encrypted before leaving the Mac.
- The hosting database and object store do not contain the decryption key.
- The service does not collect recipient viewing analytics or use recipient accounts.
- Every share expires and can be stopped permanently.

MacParakeet must not claim that a share is private from everyone, impossible to copy, anonymous at the network layer, or absolutely zero knowledge.
The recipient browser sees plaintext, anyone with the complete URL can read it, and the first-party viewer JavaScript receives the fragment key.
A malicious or compromised viewer deployment, DNS account, or recipient device could therefore expose plaintext at read time.

## Keychain behavior

The owner credential is random application state, not a machine fingerprint.
It uses a sharing-specific generic-password item that is non-synchronizing and accessible only on the device after first unlock, matching the existing Keychain pattern without requesting Touch ID, user presence, or an application password.

Normal signed-app operation should not add an onboarding permission step.
macOS can still show a Keychain authorization dialog in unusual cases such as signing-identity or access-control changes, so product copy must not promise that a system dialog is impossible.

Uninstall or Keychain loss may remove local management and content keys.
A saved recovery code restores remote management and future publication, not decryption or replacement of pre-recovery content and not lost complete URLs; without it, mandatory expiry is the final bound.
When no recovery code is configured, the current device credential may add one later.
Once a recovery code exists, replacing or removing it also requires that current code, so a stolen device credential cannot displace the owner's saved recovery path.
If the code is lost, the current device can still manage its shares but cannot replace that verifier; after permanently stopping every outstanding share, the app may discard that anonymous owner and enroll a fresh one for future shares.
Deleting a local source permanently stops its shares and removes their local content keys and content-derived publication metadata once the terminal request is durably queued.

## Threat model

| Event | Expected protection and response |
|---|---|
| Full URL is disclosed | The holder can read and forward the share. Permanent stop limits future fetches; a replacement requires a new share. |
| Database or object-store dump | The attacker obtains ciphertext and limited operational metadata, not the selected text or fragment key, assuming sound cryptography. |
| Viewer origin or deployment is compromised | The attacker may exfiltrate fragment keys and plaintext at read time. Harden deployment and state this limitation honestly; CSP cannot make authorized malicious first-party code safe. |
| Owner token is stolen | The attacker may manage owner shares within its scope but cannot decrypt them without complete URLs. If recovery is configured, the device token alone cannot replace or remove its verifier, and the saved recovery token can invalidate the stolen device token. If recovery is absent, the device bearer is full owner compromise and can install its own recovery verifier. |
| Mac or Keychain state is lost | Saved recovery permits limited management; otherwise links remain accessible only until stop by an operator or mandatory expiry. |
| Recipient saves a copy | Revocation does not erase it. The UI must never imply digital-rights management or copy prevention. |
| Anonymous publisher abuses the service | Encrypted text prevents semantic scanning. Enforce text-only schemas, payload and owner quotas, transient rate controls, spend ceilings, a creation kill switch, and read-only service mode. |
| Recipient reports abuse | Store a content-free category and opaque share reference. A report opens a case but never automatically uploads plaintext or quarantines a link. |

## Viewer and deployment controls

The viewer uses self-hosted assets only, HTTPS with HSTS, a strict Content Security Policy, generic metadata, `noindex`, `Referrer-Policy: no-referrer`, and `Cache-Control: no-store` for payload responses.
It has no analytics, service worker, remote font, advertising, third-party script, or automatic external media request.
Markdown is untrusted input and must be rendered through reviewed sanitization with raw HTML and automatic remote assets disabled.
The share deployment neither sets nor consumes cookies, strips them from application logging, and verifies that the main site does not set parent-domain cookies that would be sent to `share.macparakeet.com`.

Every service API request uses HTTPS to the build-approved origin, which is `https://share.macparakeet.com` in production.
Clients reject HTTP, downgrade, cross-origin destinations, and redirects to an unapproved origin; credential-bearing requests do not automatically follow redirects, and `Authorization` or `Recovery-Authorization` headers are never forwarded on any redirect.

Viewer code, DNS, deployment credentials, service secrets, storage, and logs are isolated from telemetry infrastructure even when both systems use the same hosting provider.
Deployment access is narrowly held and audited because viewer-code integrity is a confidentiality control.

## Retention and deletion

- Public reads stop exactly when authoritative server time reaches `expiresAt` or when a permanent stop commits; cleanup timing never extends access.
- Superseded, expired, stopped, and unreachable orphan ciphertext is purged from live storage within 24 hours.
- A deletion-complete receipt is issued only after every known current, prior, and orphan ciphertext object for the share is confirmed absent.
- Owner-linkable terminal tombstones are removed within 30 days after confirmed ciphertext deletion.
- Content-free abuse cases are removed within 30 days after case creation.
- Sterile operator-decision audit records are removed within 30 days after the decision.
- A one-way, owner-unlinked commitment for each accepted locator remains after tombstone deletion solely to enforce permanent non-reuse; it contains no content, timestamp, or management authority.
- Idempotency receipts and ephemeral keyed or coarse abuse signals last no more than 24 hours.
- Recipient application request logging is disabled, and raw recipient IPs are not persisted by the application.
- Hosting-provider backup or recovery-history windows must be documented from the deployed configuration before beta; deleted data is never restored into the live service.

An access-stopped receipt and deletion-complete receipt are intentionally different.
The first proves no later service read succeeds; the second proves live ciphertext removal.
Neither proves erasure from recipient devices or from a provider recovery system before its disclosed bound.

## Logging and support

Application, edge, APM, crash, diagnostic, and support paths redact or omit complete URLs, locator-bearing paths, fragments, device and recovery credentials, Authorization and Recovery-Authorization values, request bodies, ciphertext, decrypted text, source metadata, and recipient identifiers.
Support uses sterile request IDs and lifecycle states.
No troubleshooting workflow asks a user to paste a full share URL or recovery code.

Operator metrics are aggregate service health and cost signals such as request outcomes, latency, storage bytes, cleanup backlog, and quota rejections.
They are not recipient views and cannot be presented to an owner as viewing analytics.

## Abuse and incident response

Abuse controls focus on cost and availability because the operator cannot inspect encrypted content in normal operation.
The service has per-owner payload and storage quotas, bounded creation rates, report-rate controls, global spend alerts, a creation kill switch, and a mode that preserves existing reads while rejecting enrollment, publication, content updates, and expiration extensions. This mode continues to allow authentication, recovery, permanent owner/operator stop, deletion reconciliation, expiration enforcement, and retention cleanup.

Public reports create cases only.
Administrative restriction requires a logged operator decision. Reports and automated signals may inform that decision but never permanently stop access automatically.
The operator control permanently stops the service-side share identifier without revealing plaintext, and records a sterile reason and actor audit entry.
Legal notices that include plaintext follow a separate counsel-approved process and do not silently expand ordinary logging or retention.

A suspected viewer compromise requires freezing new publication, preserving sterile deployment evidence, rotating deployment credentials, restoring a reviewed static build, and publishing a public incident notice. The service holds no owner contact information and cannot promise individual owner notification.
Because the service does not know which recipients viewed a link, it must not claim complete recipient notification.

## Release evidence

The feature stays behind a default-off flag until all of the following are demonstrated with synthetic data first:

- **Contract:** the ADR, both v1 contracts, privacy notice, terms, and abuse process agree with the implementation.
- **Cryptography:** Swift CryptoKit and browser Web Crypto share a committed fixture; wrong-key, tamper, locator, revision, nonce, maximum-size, and truncated-tag tests fail closed.
- **Network:** packet and log capture show no plaintext, fragment, complete URL, owner secret, recovery secret, or content-derived metadata reaching service logs or third parties.
- **Viewer:** Safari, Chrome, Firefox, common mobile browsers and in-app webviews preserve the fragment and pass read, search, copy, download, print, keyboard, VoiceOver, no-external-request, and generic-preview checks.
- **Lifecycle:** create and update are idempotent; failed updates keep the prior revision; exact expiry, concurrent mutation, permanent stop, and no-reactivation tests pass against authoritative state.
- **Deletion:** payload reads fail immediately after an access-stopped receipt, every revision and orphan is absent before deletion-complete, and provider recovery bounds are verified.
- **Device:** Keychain reset, reinstall, lost response, stolen token, optional recovery, no-recovery, and credential rotation paths are exercised.
- **Local deletion:** an offline source deletion preserves its ordered outbox across restart and does not claim remote success early.
- **Abuse and cost:** oversized upload, owner farming, read flood, report flood, quota exhaustion, spend ceiling, kill switch, and read-only mode tests pass.
- **Comprehension:** publishers and recipients can accurately explain what leaves the Mac, who can read it, what updates, what stopping does, why copies remain, and what recovery cannot restore.

## Deferred privacy expansions

Passwords, recipient accounts, named invitations, full-link recovery, comments, correction requests, notifications, multi-device sync, content inspection, rich previews, and recipient analytics each change the privacy or authority model.
None may be added as an unversioned extension of v1.
