# Shareable Transcript Snapshots

> Status: **Proposed**
> Governing decision: [ADR-029](adr/029-encrypted-shareable-transcript-snapshots.md)
> Boundary contracts: [Share Link and Bundle v1](contracts/share-link-bundle-v1.md) and [Share Service v1](contracts/share-service-v1.md)

## Product promise

MacParakeet may publish a user-reviewed selection of transcript-derived text as an encrypted, expiring page at `share.macparakeet.com`.
The local Library remains authoritative; a share is a separate snapshot, not cloud sync.

The clearest user-facing explanation is:

> Your Library stays on your Mac. A share is a separate encrypted text copy that you choose, preview, publish, update, and stop. Audio is never included.

## Publisher experience

The Share sheet shows the exact content that will be published before any upload begins.
Meeting-like items initially select non-empty summaries and notes while leaving the transcript off.
A transcript-only item initially selects its transcript, and contextual actions may begin with only the selected passage, note, or result.

Transcript options follow the existing export vocabulary: timestamps, speaker labels, and metadata are independently selectable when available.
Share metadata is a narrow display projection; local paths, internal identifiers, model or provider details, prompts, calendar context, and other hidden application state are excluded.

The publisher chooses an exact expiration using 1 hour, 24 hours, 7 days, 30 days, or a custom date and time.
Thirty days is the default, every link expires, and the total lifetime may not exceed 90 days from first publication.

After publication, the app exposes the complete URL through copy and the macOS share sheet.
The publisher can explicitly update the selected snapshot at the same URL, shorten or extend an active link's expiration within its original lifetime ceiling, or stop sharing permanently.
Local edits never publish automatically.
A persistent Shared pages surface keeps active, detached, pending, expired, and stopped records manageable after source-attached controls disappear.
After remote deletion is confirmed, an owner may remove the terminal record from this Mac.

## Recipient experience

Anyone with the complete URL can open the page without an account or password.
The page is read-only and supports browser search, copy all, per-section copy, Markdown download, plain-text download, and print or save as PDF.

The page has generic link-preview metadata, is not indexed, and uses no recipient analytics, cookies, read receipts, remote fonts, or third-party page assets.
The product must be direct that anyone who receives the URL can read, copy, and forward its contents.

## Ownership and recovery

On first publication, MacParakeet silently creates a random sharing credential in a dedicated, non-synchronizing, device-only Keychain namespace.
It is not derived from hardware, an IP address, telemetry, licensing, or user content, and normal operation does not request biometric or application-password access.

An optional generated recovery code restores management authority after a reinstall or device loss.
Recovery can list opaque share records, change an unexpired expiration, and stop sharing, but it cannot reconstruct a lost complete URL or decrypt content.
The first-share flow explains that without a saved recovery code, losing local management state also loses the ability to stop a still-active page early.
Using recovery replaces the prior management credential, so an old installation becomes visibly unable to manage those records instead of retrying forever.
Previously published shares remain management-only after recovery, while the recovered installation can publish and update new shares normally under the same anonymous owner; recovery offers one replacement recovery code.

## Lifecycle and deletion

An explicit update keeps the URL and publishes a new encrypted revision only after the service confirms it.
A failed or conflicting update leaves the last confirmed revision available.

Stop sharing is permanent.
Once the service confirms the stop, future payload reads fail and remote ciphertext deletion begins; a new disclosure requires a new link.
The service never reassigns the stopped locator.
Revocation cannot erase copies a recipient has already loaded, downloaded, copied, or captured.

Deleting a local source also requests permanent stop for its active shares.
If the Mac is offline, local deletion may finish, but the app preserves an opaque durable operation and says the remote stop is pending until the service confirms it.
Natural expiration also denies access permanently and starts the same bounded ciphertext-cleanup process.

## Privacy boundary

The Mac encrypts the selected text before upload, and the decryption key remains in the URL fragment.
The service stores authenticated ciphertext and minimal operational metadata rather than transcript plaintext.
After ordinary terminal records expire, it keeps only a one-way, owner-unlinked commitment for each used locator so a stopped URL can never become active again.

This protects content from ordinary server logging and a database or object-storage disclosure when the cryptography is sound.
It is not an absolute zero-knowledge claim: the first-party viewer JavaScript and the recipient's browser necessarily handle the key and plaintext, so a compromised viewer deployment could expose them.
See [Share Service Privacy and Operations](../docs/share-service-privacy-and-operations.md) for the threat model, retention rules, and release gates.

## V1 scope

V1 includes text snapshots, accountless bearer-link reading, anonymous owner management, optional management recovery, explicit same-link updates, bounded expiration, permanent stop, and the read-only recipient conveniences above.

V1 excludes audio, automatic Library mirroring, live synchronization, passwords, named recipients, recipient accounts, viewing analytics, comments, correction requests, collaborative editing, permanent links, rich content-bearing previews, and a public CLI surface.
The CLI omission is a temporary interface-staging choice: protocol, projection, lifecycle, and persistence logic remain reusable Core capabilities rather than UI-only behavior.
Comments remain technically possible, but they require a separate identity, write-authorization, spam, moderation, notification, retention, and encryption contract.
An IP address is never identity; it may only inform short-lived coarse abuse controls.
A recipient may submit a content-free abuse report; it creates an operator case but never disables a page automatically.
Any operator stop is permanent, auditable, and does not require the operator to decrypt the snapshot.

## Release posture

The feature begins behind a default-off release flag.
Public release requires interoperable Swift and browser cryptography, verified lifecycle and deletion behavior, real-browser link compatibility, accurate privacy and terms copy, abuse and cost controls, and an independent security review.
Source presence or a working demo does not satisfy those gates.
