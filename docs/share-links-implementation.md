# Encrypted sharing: implementation and release handoff

Sharing is implemented but **not publicly enabled**. `AppFeatures.shareLinksEnabled`
remains `false`; DEBUG builds can expose the native UI with `--enable-share-links`.
That switch does not redirect credentials or configure a production service.

## Where the behavior lives

- `MacParakeetCore/Services/Sharing`: allowlisted text projection, interoperable
  AES-GCM bundles, strict URLs, device/recovery credentials, HTTP and lifecycle.
- `SharePublicationRepository`: local publication ledger and ordered durable
  outbox. The existing GRDB migration adds sharing tables without changing
  transcript contents. Network operations do not belong in database transactions.
- `TranscriptionDeletionCoordinator`: persist permanent-stop intent before
  removing local keys, owned assets and source records. Audio-only deletion does
  not revoke a text snapshot.
- Committed source-deletion stop intent sends a payload-free cross-process hint
  to the running, sharing-enabled app. It drains asynchronously, including after
  a busy mutation; a failed attempt remains durable without an automatic retry
  loop. The synchronous CLI does not wait for remote revocation: if the app is
  closed, the stop waits for its next enabled startup.
- `ShareDraftViewModel` and `ShareManagementViewModel`: exact preview, explicit
  updates, expiry, pending operations, recovery and persistent Shared pages.
- The website repository owns a separate Worker, D1 database, private R2 bucket
  and first-party viewer. The marketing site's analytics layout is not reused.

The governing [product spec](../spec/15-shareable-transcripts.md),
[bundle contract](../spec/contracts/share-link-bundle-v1.md),
[service contract](../spec/contracts/share-service-v1.md) and
[privacy runbook](share-service-privacy-and-operations.md) remain authoritative.
UI choices may change without changing the wire contract.

## Important failure semantics

Keep the last confirmed page visible while an explicit update is pending. A
transport error does not prove a publication failed: replay the persisted
request rather than creating another link. A definitively rejected first create
can be discarded only when acceptance is ruled out and no terminal intent is lost.

Recovery persists the replacement device before sending. Probe it after a lost
response; retry only the same persisted request with the supplied recovery code.
Never overwrite uncertain authority with a newly generated credential. Recovery
restores management, not old decryption keys. Unknown already-deleted remote
tombstones are not imported, so removing a completed local record stays removed.

Stop confirmation means access is denied; deletion completion separately means
the service confirmed ciphertext absence. Offline local deletion preserves the
opaque terminal outbox. Recipient copies and provider recovery history are not
erased by revocation; the privacy runbook explains those limits.

## Verification and public enablement

The implementation has focused Swift lifecycle/projection/ViewModel tests,
shared Swift/WebCrypto fixtures, real-SQL website tests, and a synthetic runtime
script in the website repository. Real local workerd and isolated remote staging
checks exercised publication, retries, updates, recovery, stop and cron deletion.
Chrome, Firefox and mobile-emulated WebKit checks covered decryption, search
filtering, copy/download, no cookies and first-party-only requests. Chrome also
passed the 390-pixel responsive-layout check. This does not stand in for actual
Safari/iPhone, recipient in-app browsers or VoiceOver. Staging creation is
disabled after verification.

Run the normal build and test gates on the exact final commits before merging.
Do not mistake mock tests, source presence, or Chrome-only QA for a public release.
The separate release decision still requires:

- Production domain/storage configuration, provider retention verification,
  cost alerts and an owner for abuse cases and cleanup incidents.
- Cross-browser and recipient-channel fragment preservation, keyboard and
  VoiceOver checks, and native end-to-end UI/Keychain verification.
- Independent security-review findings resolved and current privacy/terms copy
  checked against the deployed service.

If production is later enabled, roll back by hiding the app entry points and
disabling new service creation/updates. Keep recovery, stop, reads of still-active
pages, expiry enforcement and cleanup running; never abandon outstanding shares.
