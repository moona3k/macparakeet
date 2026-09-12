# Shareable Transcripts

> **Research status:** This report preserves the exploration and alternatives
> that informed the decision. The accepted direction is governed by
> [`spec/15-shareable-transcripts.md`](../../../spec/15-shareable-transcripts.md),
> [ADR-029](../../../spec/adr/029-encrypted-shareable-transcript-snapshots.md),
> and the two [`spec/contracts/`](../../../spec/contracts/) sharing contracts.
> Where this report presents an earlier option such as link rotation or a
> different preset list, the governing documents supersede it.

> **Decision:** Proceed to a privacy and usability prototype. Build an explicit,
> text-only shared snapshot under `share.macparakeet.com`, not a cloud mirror of
> the Library. Encrypt the selected content on the Mac with a random key carried
> in the URL fragment. Give the owner a separate anonymous management credential
> stored in Keychain. Do not use a machine fingerprint, upload audio, enable
> automatic sharing, collect recipient analytics, or add collaboration in the
> first release.

## Executive assessment

The idea is both feasible and strategically sound. Sharing makes MacParakeet's
local corpus more useful and hands selected speech memory safely to another
person, so it passes the product filter in ADR-027.[^1] The strongest version of
the feature does not imitate a cloud meeting workspace. It turns a local item
into a deliberately composed, revocable web artifact.

The central product promise should be:

> Your Library stays on your Mac. A share is a separate encrypted text copy that
> you choose, preview, publish, expire, update, and revoke. Audio is never part of
> it.

There are four independent design problems that should not be collapsed into
one “unique key”:

1. **Owner authority:** how the originating Mac proves it may create and manage
   shares without an email account.
2. **Recipient access:** how anyone holding one URL can read one share without
   gaining access to anything else.
3. **Content confidentiality:** what the hosting service, its database, and its
   operators can learn.
4. **Abuse resistance:** how a free anonymous service limits spam, illegal
   material, automated account creation, and denial-of-wallet attacks.

A hardware fingerprint solves none of these cleanly. It is an identifier rather
than a secret, is difficult to rotate, conflicts with MacParakeet's current
public promise of “no fingerprinting, no persistent IDs,” and still does not
prove that a request comes from a legitimate person.[^2] A cryptographically
random installation credential is safer, simpler, and more honest.

The recommended first release is intentionally narrow:

| Dimension | Recommendation |
|---|---|
| Source | One Library transcription: meeting, file, URL/YouTube, or podcast |
| Content | Owner-selected transcript passages, one or more summaries, and/or notes |
| Audio | Structurally excluded |
| Publication model | Explicit snapshot; local edits never auto-publish |
| Recipient | Anyone with the complete link; no account |
| Confidentiality | AES-256-GCM in the app; key after `#` in the URL |
| Default lifetime | 30 days for a beta; 90-day anonymous hard maximum |
| Management | List, open, copy, update, rotate, expire, revoke, delete |
| Analytics | None for recipients in v1 |
| Collaboration | Separate future decision; not an extension of v1 |

## Why this belongs in MacParakeet

MacParakeet's accepted direction is private speech memory: capture stays local,
the Library becomes the center of gravity, and export and agent access make the
corpus useful.[^1] A share link fits that direction if it is treated as a
controlled export. It does not fit if it quietly moves the Library into a cloud
account or creates a second, server-authoritative copy of every meeting.

The current upstream app already has the right user-facing seam. The transcript
view provides contextual copy behavior: a meeting copy includes title, notes,
and transcript, while a menu offers transcript-only copy. Notes and generated
prompt results have their own copy actions, and export supports eight formats.[^3]
The share action should sit beside these existing actions and reuse their
content-projection logic, rather than introduce a parallel interpretation of a
transcript.

The live product, however, makes unusually strong promises. The website says no
account is required, audio never leaves the Mac, transcript content is not
collected, and no persistent device identifier or fingerprint exists.[^2] A
share feature is therefore not “just another endpoint.” Before release it needs
a new governing ADR or amendment, a public share-bundle contract, updated
privacy and network-surface documentation, and explicit consent copy.

This boundary is the differentiation. Cloud-first products already make links.
MacParakeet can make the act of disclosure legible.

## The product model: a shared snapshot

The local item remains the source of truth. A remote share is a derived,
versioned snapshot with its own lifecycle.

```text
LOCAL SOURCE OF TRUTH            ENCRYPTED HOSTING              RECIPIENT

Transcript                       Share metadata                 Browser shell
Notes                 select     - random locator     fetch     - obtains # key
Summaries             preview    - expiry/status      ------>   - decrypts locally
Speaker corrections   encrypt    - ciphertext object            - renders text
      |                   |              |                             |
      | local edits       | explicit     | revoke/delete               | copy/export
      v                   v              v                             v
  never auto-sync      new version    access stops                 copies remain
```

This separation yields predictable behavior:

- Editing speaker names, notes, or summaries locally marks an existing share as
  out of date; it does not change the public page.
- **Update shared page** shows another exact preview, creates a new encrypted
  version, and preserves the URL unless the owner chooses **Rotate link**.
- Revocation blocks future server access. It cannot remove text already copied,
  downloaded, screenshotted, or loaded in a recipient tab.
- Deleting a local transcript should default to revoking its active shares, but
  offline revocation must be shown as pending until confirmed by the server.
- A queued revocation record must survive deletion of its source transcript.
- Automatic expiry bounds orphaned content when a Mac and its recovery secret
  are both lost.

The server never receives access to the rest of the Library. The owner
credential may list only the shares already published under that anonymous
owner namespace.

## Owner experience

### Entry points

Use the plain user-facing name **Share link**. A product-internal name such as
“share capsule” can be useful in design discussion, but the interface should not
teach a new metaphor.

- A top-level **Share link** action sits beside Copy and Export on the
  transcription detail view.
- Transcript selection offers **Share selection** and includes exactly the
  highlighted passages.
- A summary's action row offers **Share this result**.
- Notes offer **Share notes**.
- Dictation history is out of the first slice. It is a separate model with
  private-mode semantics, while the initial value is strongest for Library
  transcriptions.

### Creation sheet

The sheet should answer one question: *exactly what will another person be able
to read?*

1. Select content blocks: summary, notes, chapters, transcript, or selected
   transcript passages.
2. Independently choose title, source type, date, duration, speaker labels,
   timestamps, and source attribution.
3. Show audio as a disabled row: **Audio is never included.**
4. Preview the actual recipient page, including generic link-preview behavior.
5. Choose expiry: 24 hours, 7 days, 30 days, or 90 days. Use 30 days as the beta
   default and do not offer “Never” to anonymous owners until recovery and abuse
   operations have proved reliable.
6. Confirm: **This encrypted text copy will leave your Mac. Anyone with the full
   link can read and forward it.**
7. Create, then offer Open, Copy link, the macOS share sheet, and Manage.

Contextual selection is the safest useful default. **Share selection** includes
only the highlighted text. A general **Share link** starts empty, or—if usability
testing shows that is too inert—preselects only the currently visible section.
It should never silently select the full transcript merely because a summary or
notes panel was open.

### Shared by me

Privacy depends on control after publication, so management is not optional
polish. A local **Shared by me** view should reconcile against the server and
show:

- active, expiring, expired, revocation-pending, revoked, deletion-pending, and
  deleted states;
- created, explicitly updated, and expiry dates;
- encrypted byte size, without server-known titles;
- open, copy, preview, update, rotate, change expiry, revoke, and delete actions;
- a warning when local content has changed since the published snapshot;
- the difference between **access revoked** and **online copy deleted**.

Do not claim success until the relevant server operation has returned a durable
receipt. If the Mac is offline, preserve the queued operation and say that the
link may still work.

## Recipient experience

The recipient should get a quiet, readable document—not a product funnel.

1. Decrypted title and optional source/date.
2. A provenance line: shared from MacParakeet, snapshot date, last explicit
   update, expiry, and “text only; audio was not uploaded.”
3. The chosen summaries and notes.
4. Chapters or an outline for a long transcript.
5. Transcript passages with optional speakers and timestamps.
6. In-page search performed only in the browser.
7. Copy and Download Markdown actions performed only in the browser.
8. A restrained MacParakeet attribution and **Report this share**.

The page should carry a brief accuracy note: transcripts and generated
summaries can contain errors. It should not show a login prompt, install gate,
advertising, trackers, comments, remote images, or a misleading “disable copy”
control.

Chat and document products illustrate why this restraint matters. Otter lets an
anyone-link viewer open a transcript without an account and lets owners revoke
conversation links, but its snippet links cannot be restricted or revoked.[^4]
Fathom combines open, domain, and named-person access, making its effective
permission model more complex.[^5] Descript's explicit republish/unpublish model
is the closest analogue for snapshot updates.[^6] Proton demonstrates that a
central management surface, expiry, passwords, and encrypted public links can
coexist.[^7]

## Direct answer: do not fingerprint the Mac

It is possible to derive or request identifiers associated with a machine, but
that is the wrong security primitive.

### Why a fingerprint fails

- **It is not a secret.** Serial numbers, hardware properties, and composite
  fingerprints can be read, copied, guessed, or spoofed. They identify a value;
  they do not prove possession of an uncopyable credential.
- **It is not reliably permanent.** Repairs, virtualization, restore, app
  reinstall, privacy protections, and platform changes can alter inputs.
- **It is not safely recoverable or rotatable.** A leaked fingerprint cannot be
  replaced without pretending the machine changed.
- **It creates linkability.** The same stable value connects actions over time,
  directly contradicting the live “no fingerprinting, no persistent IDs”
  promise.[^2]
- **It does not prevent abuse.** An automated client can spoof values or mint
  fresh ones. Anonymous service abuse is a rate, cost, and reputation problem,
  not a hardware-uniqueness problem.

RFC 4086 explicitly cautions that hardware-derived values are structured and
may offer less uniqueness or unpredictability than assumed.[^8]

### What to use instead

On the first Share action, generate:

- a public random `owner_id`;
- a public random `device_id` and separate random 256-bit `device_secret`;
- an independent 256-bit recovery code.

Store the owner secret in the macOS data-protection Keychain with a
device-only, non-synchronizing accessibility class. Store only a one-way verifier
on the server. Apple describes Keychain as encrypted storage for small secrets
and keys; device-only items deliberately do not migrate.[^9]

The key is statistically unique at cryptographic scale, which is what the
system needs. It represents an anonymous owner namespace, not a verified person
and not an intrinsic property of the Mac.

Do not let a person type or configure the authentication key; human-chosen
secrets are weaker. Let the person export, print, or save the generated recovery
code, with a plain warning that MacParakeet support cannot reconstruct it.

A concrete v1 token scheme is deliberately boring:

```text
device token   mpd1.<base64url(device_id)>.<base64url(device_secret)>
recovery token mpr1.<base64url(owner_id)>.<base64url(recovery_secret)>

server verifier
  SHA-256("mp-device-v1\0" || device_id || device_secret)
  SHA-256("mp-recovery-v1\0" || owner_id || recovery_secret)
```

All four values are generated locally with a cryptographically secure random
number generator. The server stores the public IDs, domain-separated verifiers,
credential generation, and lifecycle timestamps. It returns the same error for
an unknown ID and an incorrect secret and compares verifiers in constant time.
A password KDF is unnecessary for a generated 256-bit token; it becomes
necessary if user-chosen passphrases are introduced.

## Credential and recovery design

### Three separate capabilities

| Capability | Where it lives | What it can do |
|---|---|---|
| Owner credential | macOS Keychain; verifier on server | Create, list, update, rotate, revoke, and delete this owner's shares |
| Recipient link | Share locator in path; content key in fragment | Read and decrypt exactly one share |
| Recovery code | User-controlled offline copy; verifier on server | Replace owner credential and invalidate a lost Mac |

The owner secret must travel only in an HTTPS Authorization header, never in a
URL. A useful opaque format is a non-secret selector plus secret value, so the
server can locate the verifier without scanning. Store a cryptographic hash of
the high-entropy secret and compare in constant time. Authorization headers,
recovery values, full URLs, URL fragments, and content must be redacted from app,
edge, trace, crash, and support logs.

NIST treats saved recovery codes as a valid recovery mechanism and recommends
offline storage, protected server-side verification, throttling, and
single-use/rotation behavior.[^10]

Recovery is one-time. The replacement Mac generates a new device secret and a
new recovery secret. One server transaction validates the old recovery verifier,
invalidates the lost device, installs both new verifiers, and increments the
credential generation. A lost response is reconciled by trying the new device
credential; the server response never contains a secret.

### Recovery scope

Recovery creates a real product choice:

- **Management-only recovery** lets a new Mac list metadata, revoke, delete, and
  change expiry. It cannot reconstruct an existing full link because the server
  never had the content key.
- **Full-link recovery** requires each content key to be additionally wrapped by
  an owner recovery key and stored server-side as ciphertext. This is more
  convenient but expands the cryptographic protocol and the consequences of
  losing the recovery code.

Use management-only recovery first. It preserves the most important safety
operation—revocation—without building key-wrapping and cross-device sync. A new
link can be created from the local source if it still exists. Add passkeys or
wrapped keys only after real multi-Mac demand.

### Why not Secure Enclave in v1

Apple Silicon supports Secure Enclave P-256 keys, and those private keys cannot
be imported or exported.[^11] That is useful hardening, but it also forces a
custom signed-request and replay-protection protocol and makes recovery
mandatory. A random bearer owner secret in Keychain over TLS is a smaller
protocol with fewer ways to make a cryptographic mistake.

App Attest is more relevant to abuse than to owner identity: Apple documents it
as a way for a server to gain confidence that a request came from a legitimate
instance of an app. Its current `isSupported` documentation says the value is
false on Mac devices, including iOS/iPadOS apps running on Apple silicon.[^12]
Do not plan the Mac launch around App Attest. Recheck only if Apple changes the
contract and then verify at runtime. Even if support arrives, it would verify app
integrity rather than human identity and would exclude differently signed
open-source builds if made mandatory.

The strongest objection to the bearer design is serious: a token accidentally
captured by a proxy, trace, crash dump, endpoint-security product, or support
bundle can be replayed until rotation. That makes end-to-end redaction tests a
release gate. A signing key or passkey can reduce that exposure later, but only
with a complete proof-of-possession protocol covering canonical requests,
freshness, nonces, body binding, replay state, and recovery. A partial custom
signature scheme is riskier than the small, well-contained bearer protocol.

## Content encryption

Use one independently random 256-bit AES-GCM key and a fresh nonce for every new
share. For an explicit update under the same link, either keep the key and
generate a nonce that can never repeat, or rotate both key and URL. The versioned
envelope should authenticate schema and context as associated data. Publish
cross-platform test vectors that prove CryptoKit encryption and Web Crypto
decryption agree.

The link shape is:

```text
https://share.macparakeet.com/s/<128-bit-random-locator>#v1.<256-bit-content-key>
```

RFC 3986 specifies that the fragment is separated before a URI is dereferenced,
so it is not part of the ordinary HTTP request.[^13] Web Crypto provides
AES-GCM decryption in modern browsers.[^14] The server therefore receives the
locator and returns ciphertext, while the browser obtains the key from the
fragment and decrypts locally.

### Honest security claims

This model protects against a stolen storage bucket or database containing
ciphertext. It keeps the decryption key out of normal HTTP requests and service
logs. It does **not** protect against:

- anyone who possesses the complete URL;
- browser history, clipboard sync, extensions, local malware, screenshots, or
  recipient forwarding;
- recipient copies after revocation;
- a malicious or compromised viewer deployment, because first-party JavaScript
  can read both the fragment and decrypted text.

The correct claim is: **MacParakeet stores the share as encrypted data and the
decryption key is in the link, not sent in the normal request.** Do not claim
that MacParakeet “can never decrypt” or use an unqualified “zero knowledge” or
“end-to-end encrypted” label before an independent threat-model review.

Content-specific Open Graph previews are incompatible with this default because
the preview crawler does not have a server-visible key. Use generic preview
copy. This is a product advantage: names and meeting titles cannot leak into
unfurl logs. A real-channel compatibility matrix still has to prove that
Messages, Mail, Slack, Teams, Gmail, QR codes, and browser share sheets preserve
the fragment.

### Share bundle

The encrypted bundle should be a public, versioned contract with no local file
paths or database identifiers:

```json
{
  "schemaVersion": 1,
  "publishedAt": "2026-09-11T22:00:00Z",
  "title": "Optional encrypted title",
  "source": { "kind": "meeting", "displayDate": "Optional" },
  "sections": [
    { "kind": "summary", "title": "Summary", "blocks": [] },
    { "kind": "notes", "title": "Notes", "blocks": [] },
    { "kind": "transcript", "title": "Transcript", "segments": [] }
  ]
}
```

Include only display-ready fields the owner selected. Omit local transcription
UUIDs, file paths, meeting links, calendar attendees, model/provider details,
prompts, chat history, confidence values, audio paths, remote thumbnails, and
unselected source URLs. Calendar context is explicitly local-only in the current
model and should never cross the boundary accidentally.

Use structured text blocks rather than arbitrary HTML. Render plain content via
`textContent`. If limited Markdown is added, disable raw HTML, remote images,
embeds, and scriptable URLs; sanitize again in the browser and keep a strict
Content Security Policy. OWASP recommends both safe DOM sinks and CSP as
defense-in-depth.[^15]

## Service architecture

The simplest credible deployment is a separate Cloudflare project:

```text
MacParakeet app
  | HTTPS owner API: auth + idempotency + ciphertext
  v
Share Worker at share.macparakeet.com
  |-- D1: anonymous owner verifiers, share state, expiry, quotas
  |-- R2 private bucket: versioned ciphertext objects
  |-- static viewer: local assets only; no analytics or service worker
  `-- scheduled cleanup: expiry, tombstones, orphan reconciliation

Recipient browser
  | GET /s/<locator>        -> generic static shell
  | GET /api/v1/s/<locator> -> active-state check + ciphertext
  ` decrypts with # key     -> local render/search/copy/download
```

Keep this data plane separate from the existing telemetry Worker, D1 database,
and logs. The account and vendor may be shared, but code, bindings, secrets,
databases, buckets, domains, deployment credentials, and retention policies
should be isolated. A transcript-hosting incident must not become a telemetry
incident, or vice versa.

### Why D1 plus R2

- D1 is a good indexed authority for owner/share state and expiry. It should not
  store the content blob. D1 has a 2 MB row limit, 10 GB per-database paid limit,
  and single-threaded per-database processing, which are unnecessary constraints
  for variable transcript payloads.[^16]
- R2 is a better content store. Standard storage currently includes 10 GB-month,
  one million write-class operations, and ten million read-class operations per
  month; overage is $0.015/GB-month, $4.50/million writes, and $0.36/million
  reads, with no Internet egress charge.[^17]
- Workers Paid currently starts at $5/month and includes ten million requests
  plus thirty million CPU milliseconds per month.[^18]
- D1 Paid includes 25 billion rows read, 50 million rows written, and 5 GB
  storage before overage.[^19]

Do not expose the R2 bucket publicly. Every ciphertext read should pass through
the Worker, which checks D1 state first. Do not enable read replication for this
authorization query in v1: active-state reads go to the D1 primary, and a revoke
receipt is returned only after the primary commit succeeds. Primary-path
throughput and post-receipt revocation latency are release tests. Cloudflare
states R2 deletion is strongly consistent, but also warns that a deleted object
can remain available through a cache.[^20] Use `Cache-Control: no-store` for
ciphertext, no service worker, and do not rely on cached public R2 URLs. The
static viewer shell may be cached separately.

### Suggested data model

Plaintext D1 fields should be limited to operational metadata:

```text
owners
  owner_id, token_selector, token_verifier, recovery_verifier,
  created_at, credential_rotated_at, status, quota_class

shares
  share_id, owner_id, locator_hash, object_key, schema_version,
  ciphertext_bytes, created_at, updated_at, expires_at,
  revoked_at, deleted_at, abuse_status, current_revision

idempotency_keys
  owner_id, key_hash, operation, response_digest, expires_at

abuse_reports
  report_id, share_id, category, created_at, resolution,
  optional_reporter_contact
```

Encrypt or omit title, selected-field flags, transcript timestamps, speaker
labels, source filename/URL, local meeting ID, and all content. Avoid storing
recipient identity, view history, referrers, cookies, or product analytics.

### API sketch

| Method | Path | Authority | Purpose |
|---|---|---|---|
| POST | `/api/v1/owners` | enrollment + abuse gate | Create anonymous owner and verifier |
| POST | `/api/v1/owners/recover` | recovery code | Rotate owner credential, invalidate old Mac |
| GET | `/api/v1/shares` | owner | Reconcile remote share states |
| POST | `/api/v1/shares` | owner + idempotency key | Create metadata and ciphertext |
| PUT | `/api/v1/shares/{id}` | owner + `If-Match` | Publish an explicit new snapshot |
| POST | `/api/v1/shares/{id}/rotate` | owner | Replace recipient locator and content key |
| POST | `/api/v1/shares/{id}/revoke` | owner | Block reads before object deletion |
| DELETE | `/api/v1/shares/{id}` | owner | Delete active object and minimize metadata |
| GET | `/api/v1/s/{locator}` | recipient locator | Return ciphertext only when active |
| POST | `/api/v1/s/{locator}/report` | rate-limited public | Report abuse; never auto-attach decrypted text |

Create and update must be idempotent. Use compare-and-swap revisions (`ETag` /
`If-Match`) so retries cannot create duplicate shares or overwrite a later
update. D1 and R2 do not share a transaction, so publication ordering is an
explicit invariant: write the immutable R2 object first, verify its checksum,
then commit the D1 version and current-object pointer. Never expose a D1 pointer
before its blob exists. Retries reuse the same object key and idempotency record;
an unreferenced object is an orphan for scheduled deletion. Revoke state in D1
first, then delete R2 content. A recipient request must consult primary active
state rather than relying on object presence alone.

Every mutation also carries a random 128-bit `Idempotency-Key`. Reuse with the
same operation and request digest returns the original result; reuse with a
different digest returns a conflict. Credential replacement is an atomic
compare-and-replace against the credential generation. Authenticated and
recovery mutations should not accept replayable TLS 1.3 early data.

The local GRDB `ShareRecord` should contain `transcriptionID`, remote `shareID`,
full URL or locally protected content key, selection manifest, local content
digest, remote revision, status, expiry, and last confirmed operation. Pending
revocation/deletion records cannot cascade away with the source transcription.
The exact persistent schema needs its own data-retention review because the full
URL is itself a credential.

### Repository fit

Keep the existing dependency direction rather than adding a new package target:

| Layer | Proposed responsibility |
|---|---|
| SwiftUI app | Share actions, exact preview, confirmation, management, pending-state copy |
| `MacParakeetViewModels` | `ShareDraftViewModel`, `ShareManagementViewModel`, stale guards, retry/error presentation |
| `MacParakeetCore/Services/Sharing` | Allowlisted payload builder, crypto envelope, remote protocol, credential store, deletion coordinator |
| GRDB | Publication ledger plus durable upload/revoke/delete outbox |
| Separate web service | Anonymous enrollment, quotas, lifecycle metadata, private ciphertext objects |
| Static web viewer | Web Crypto decryption, structured safe render, local search/copy/download |

Do not serialize `Transcription` or reuse the full meeting artifact renderer.
The model carries source paths/URLs, chat, calendar context, notes, capture data,
and other fields that are not safe share defaults.[^32] Use a dedicated
allowlist DTO. Reuse the existing effective-speaker projection and action stale-
guard behavior so a share does not publish uncorrected speaker attribution while
corrections are still loading.[^33]

Deletion currently has no remote hook, so add one Core coordinator used by
detail, library, and bulk deletion flows. Its durable outbox must be committed in
the same local transaction as the decision to detach/delete the source. Keep
sharing credentials separate from the dormant licensing install identifier and
from telemetry. Use release flag, user enablement, and per-share confirmation as
three separate gates. Do not add a public CLI command in the first milestone;
that would require its own contract and abuse boundary.

### Web-origin hardening

Use a dedicated origin with host-only/no cookies, no third-party assets, no
analytics, no remote fonts, no service worker, no public directory, and no
sitemap. At minimum:

```text
Content-Security-Policy:
  default-src 'none'; script-src 'self'; style-src 'self';
  connect-src 'self'; img-src 'self' data:; font-src 'self';
  media-src 'none'; object-src 'none'; base-uri 'none';
  form-action 'none'; frame-ancestors 'none'; worker-src 'none'
Referrer-Policy: no-referrer
Cache-Control: no-store
X-Content-Type-Options: nosniff
X-Robots-Tag: noindex, nofollow, noarchive
Cross-Origin-Resource-Policy: same-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
```

`noindex` is a crawler instruction, not access control.[^21] The high-entropy
link and content encryption provide the security properties.

## Capacity and cost

Text storage is unlikely to be the limiting cost. Human abuse operations,
privacy/security review, customer support, and incident response dominate.

Use a conservative planning workload:

- three new shares per active user per month;
- 25 recipient opens per new share;
- 100 KB average ciphertext per snapshot;
- 90 days average retention, giving nine active objects per owner;
- approximately 83 dynamic Worker requests per active user per month;
- one R2 write per created share and one R2 read per recipient open.

| Monthly active owners | New shares/mo | Retained ciphertext | Public reads/mo | Planning infrastructure cost/mo |
|---:|---:|---:|---:|---:|
| 1,000 | 3,000 | 0.9 GB | 75,000 | about $5 |
| 10,000 | 30,000 | 9 GB | 750,000 | about $5 |
| 100,000 | 300,000 | 90 GB | 7.5 million | about $6–10 |

The table is a model, not a quote or capacity test. It does not include taxes,
logging, custom-domain
fees, support, legal response, security tooling, attacks, unusually viral links,
or a second environment. At 100,000 owners, the modeled Worker request count, R2
operations, and D1 row usage stay within current paid-plan inclusions. Roughly 80
GB of R2 storage above the included 10 GB adds about $1.20, while 8.3 million
dynamic requests at four milliseconds use 33.2 million CPU milliseconds and add
roughly $0.06 above the included 30 million. That yields an estimated Cloudflare
subtotal near $6.30 per month before the excluded costs above.[^17][^18]

A conventional alternative such as Supabase Pro starts at $25/month and includes
Postgres, 100 GB file storage, 250 GB egress, two million Edge Function calls,
and 100,000 monthly active users before listed overages.[^22] It is a credible
escape hatch if team identity, SQL operations, regional deployment, or ordinary
account recovery become central. For an accountless encrypted-blob service,
Cloudflare is the smaller and cheaper initial shape. Under the same 100,000-owner
model, Supabase is roughly $83/month before a custom domain or larger compute:
$25 base, about $45 for 500 GB of uncached egress above the included 250 GB, and
about $12.60 for 6.3 million Edge Function calls above the included two million.
That comparison assumes every public read is proxied for immediate revocation;
confirm internal storage-to-function billing before commitment.

Do not mistake low unit cost for low risk. Put hard global spend/usage ceilings,
payload and active-share quotas, an emergency creation kill switch, and a
read-only mode in place before public launch.

## Abuse, privacy, and legal operations

### Make it a poor general-purpose host

- Accept structured text only—no audio, arbitrary files, HTML, images, scripts,
  embeds, custom domains, redirects, or server-side URL fetching.
- Use a conservative encoded/decoded byte limit. The initial 2 MiB suggestion
  must be calibrated against actual long transcripts; lack of compression keeps
  limits and denial-of-service behavior legible.
- Do not make URLs clickable in v1. This reduces phishing value and avoids
  leaking recipient navigation.
- Cap anonymous owners at an initial 25 active shares and 10 MiB, with creation
  limits such as 10/hour and 30/day. These are hypotheses to test, not facts.
- Enforce coarse, short-lived edge IP/ASN limits without building a browser
  fingerprint or recipient analytics database.
- Use a browser-mediated adaptive challenge ticket for suspicious
  create/recovery traffic, not for ordinary recipient reads. It adds friction
  and cost to automation but is not proof of a unique human and is not
  Sybil-proof.
- Put **Report this share** on every page. A public report creates a rate-limited
  case only; it must not directly disable the share. Quarantine requires an
  authenticated operator decision or a separately specified, auditable
  multi-signal rule. Release operations need restoration/appeal, false-report
  throttling, and quarantine-audit retention.

An install credential proves only “the same installation.” Reinstalling or
automating clients can mint new identities. Strong Sybil resistance eventually
requires greater friction: a passkey, verified account, paid entitlement, or
attestation-backed official build. No machine fingerprint removes that tradeoff.

### Retention and deletion

- Default to 30 days and enforce a 90-day anonymous maximum during beta.
- Revoke access synchronously in metadata, then delete ciphertext.
- Use scheduled expiry plus an R2 lifecycle rule as a safety net. Cloudflare
  says lifecycle deletion typically happens within 24 hours, which is too slow
  to be the access-control path but useful for orphan cleanup.[^23]
- Keep R2 versioning/retention locks off so content can be deleted.
- Minimize D1 tombstones after an operational window. D1 Time Travel is always
  on and supports up to 30 days on the paid tier, so policy must distinguish
  removal from the live service from eventual disappearance of metadata in
  recovery history.[^24]
- Retain no plaintext content and no recipient IPs for product analytics. Use
  short, documented security-log retention and sterile event shapes.
- State that server deletion cannot erase recipient copies.

### Policy and compliance gates

This is issue-spotting, not legal advice.

- Update the privacy policy, network-surface documentation, and website copy
  before any real transcript upload. Describe encrypted payloads, operational
  metadata, edge processing, retention, deletion, recovery, and browser trust.
- Add Terms and an acceptable-use policy. On first share, require confirmation
  that the owner has authority to disclose the selected text and understands
  that other participants' words may be included.
- Provide privacy access/deletion and incident-response paths. GDPR principles
  include purpose limitation, data minimization, storage limitation, and
  integrity/confidentiality; an anonymous ID or encrypted transcript can still
  relate to people.[^25]
- User-hosted transcripts may reproduce copyrighted material, especially from
  YouTube and other URLs. Assess a DMCA agent, public contact, notice/counter-
  notice, and repeat-infringer process before public operation. The U.S.
  Copyright Office states that qualifying providers must publish and register
  designated-agent information and respond expeditiously to valid notices.[^26]
- Establish restricted unlawful-content and emergency-response procedures with
  counsel. Encryption changes what the operator can inspect; it does not erase
  duties triggered by an abuse report that supplies actual content.
- Decide launch geography only after reviewing applicable EU/UK platform and
  transfer duties. Avoid claims such as HIPAA compliance without the specific
  contracts and controls.

## Competitive synthesis

Current products prove demand but also show MacParakeet's opening:

| Product | Current official behavior | Lesson for MacParakeet |
|---|---|---|
| Granola | A unique web URL can expose summarized notes instead of the full transcript, with private/company/anyone-link controls.[^27] | Summary-first sharing is useful; expose selected passages without normalizing full-transcript disclosure. |
| Otter | Anyone-link viewers can access transcript/playback without sign-in; exports are owner-controlled; normal links can be revoked, but snippet links cannot.[^4] | Every share and excerpt needs an independently revocable resource. |
| Fireflies | Offers audience tiers, invites, link passwords, and several expiry choices; public guest behavior varies by plan.[^28] | Expiry is expected, but public-link access should never be the default for every meeting. |
| Fathom | Supports anyone-link, same-domain, and named-person access and several roles.[^5] | Effective permission becomes hard to explain; start with one capability model. |
| Descript | Anyone-link pages can exclude search; published content stays at the previous version until explicitly updated and can be unpublished.[^6] | Use explicit snapshot updates and visible version dates. |
| Notion | Anyone-link reading needs no account; commenting/editing introduces accounts; public sites can live-update, index, and expose contributor metadata.[^29] | Keep indexing, collaboration, and contributor metadata out of v1. |
| Dropbox | Paid links may add password/expiry/download controls, but disabled downloads do not prevent other forms of saving.[^30] | Never market copy prevention; revocation only stops future service access. |
| Proton Drive | Accountless public links can use encryption, expiry, passwords, and a central manager.[^7] | Privacy and a usable lifecycle can coexist; management is part of the trust promise. |

Link sharing is table stakes. The differentiator is the sentence the owner can
understand and verify: **only this selected text copy leaves my Mac, it leaves
encrypted, and I can see and revoke every copy I published.**

## Collaboration: defer deliberately

Read-only sharing needs a publisher and a bearer link. Collaboration introduces
participant identity, invitations, roles, notifications, version history,
conflicts, moderation, retention, and recovery. Anonymous comments invite spam;
attributed comments require accounts; encrypted multi-writer state requires a
substantially different key and synchronization protocol.

ADR-002 currently lists real-time sharing and team features as out of scope.[^31]
Do not let comments appear as a small follow-on checkbox. If demand emerges,
write a separate product decision and start with a precise workflow such as
**request a correction** or **acknowledge an action item**, not a generic cloud
document editor.

A more aligned near-term collaboration model is **owner-approved import**: a
recipient opens an encrypted share, then explicitly imports a provenance-
preserving local copy into their own MacParakeet. That keeps each person's
Library local and avoids a shared cloud source of truth.

## High-value adjacent ideas

1. **Decision packet.** Share decisions, action items, and only the supporting
   transcript passages. This is more useful and less revealing than a raw dump.
2. **Revocable text clip.** Share one quote or passage with the same expiry and
   revocation model as a full artifact. Avoid Otter's irreversible-snippet trap.
3. **Evidence-aware summaries.** Let summary bullets link to included transcript
   anchors so a recipient can verify context without receiving the full meeting.
4. **Agent-readable handoff.** Offer local browser-generated Markdown and a
   structured JSON download. Do not expose a hidden public server API that
   bypasses encryption or lifecycle controls.
5. **Correction-aware republish.** Show which shared sections changed after
   speaker correction or transcript editing, then require preview and explicit
   update.
6. **Self-hosted share service.** Because MacParakeet is open source, a later
   documented service contract could let privacy-sensitive teams operate their
   own compatible host. Avoid premature provider abstraction in the first
   implementation, but keep the wire contract portable.
7. **Native Mac sharing.** Once a URL is created, the macOS share sheet can send
   it through Messages, Mail, AirDrop, or other installed services without
   MacParakeet becoming a messaging client.

## Anti-goals

- Cloud sync or remote access to the entire Library.
- Automatic attendee sharing or global share defaults.
- Audio, video, arbitrary file, image, or HTML hosting.
- Search-engine publishing, profile pages, custom domains, or a creator CMS.
- Permanent anonymous storage before recovery and abuse operations are proven.
- Workspaces, CRM sync, task tracking, comments, notifications, or live editing.
- Recipient analytics, tracking pixels, read time, unique-view claims, or link
  previews that disclose content.
- DRM-like “disable copy” language.
- A device fingerprint, user-chosen credential, or owner secret stored in
  preferences/config.
- Reuse of telemetry consent, endpoints, databases, or event logs as share
  consent or share infrastructure.

## Rollout and evidence gates

### Gate 0: decisions and contracts

- Accept a new ADR for the opt-in encrypted publishing boundary.
- Define `share-bundle-v1`, owner API, deletion/retention, error, and telemetry-
  exclusion contracts.
- Threat-model the link, viewer supply chain, recovery, abuse response, and
  cross-origin boundaries.
- Decide management-only versus full-link recovery. Recommendation:
  management-only.
- Decide launch geography and complete privacy/terms/DMCA counsel review.

### Gate 1: throwaway interoperability prototype

Use synthetic transcript fixtures only.

- Prove Swift CryptoKit → Web Crypto AES-GCM interoperability with published
  test vectors and mutation/wrong-key failures.
- Test fragment survival and generic previews in Messages, Mail, Gmail, Slack,
  Teams, browser copy/paste, QR, and the macOS share sheet.
- Measure decryption, render, search, print, copy, and Markdown download for
  representative and maximum-sized text.
- Test Safari, Chrome, Firefox, iOS/Android browsers, common in-app webviews,
  VoiceOver, keyboard navigation, large text, reduced motion, and no-JavaScript
  failure copy.
- Capture all browser/app/service traffic and prove no plaintext, fragment,
  title, speaker name, source URL, or content-derived metadata reaches logs or
  network destinations.

If important channels strip fragments, supported webviews fail materially, or
the trust model cannot be explained accurately, stop and reconsider the content
model before storing real transcripts.

### Gate 2: internal service alpha

- Separate Worker, D1, R2, secrets, logs, deployment credentials, and kill
  switch from telemetry.
- Test create/update idempotency, revision conflicts, rotate, revoke, deletion,
  expiry, quota exhaustion, and rollback.
- Prove revocation while cached, object deletion, scheduled orphan cleanup, and
  documented D1 recovery-history bounds.
- Exercise Keychain reset, device loss, stolen token, recovery rotation, and
  no-recovery expiry.
- Run abuse-report, takedown, outage, denial-of-wallet, and compromised-viewer
  drills with synthetic content.

### Gate 3: feature-flagged beta

- Default off; explicit local consent; no automatic share creation.
- Conservative quotas and 90-day hard maximum.
- No recipient analytics. Collect only sterile aggregate operation outcomes if
  the governing telemetry contract is deliberately amended.
- Conduct an 8–12 person mental-model study. Owners and recipients should be
  able to explain what leaves the Mac, what the server stores, who can read the
  link, what revocation does, and whether audio uploads.
- Commission independent security review of crypto envelope, viewer code, API,
  deployment, and logging.

### Gate 4: public release

Release only after current privacy/terms/network docs match runtime behavior,
legal/abuse response is staffed, beta deletion receipts are trustworthy, and
the compatibility and mental-model gates pass. Keep collaboration, permanent
anonymous storage, passwords, passkeys, rich previews, and self-hosting as
separately justified increments.

## Decisions to make before implementation planning

| Decision | Recommendation | Why it matters |
|---|---|---|
| Content visibility to operator | Fragment-encrypted only | Preserves the product's local-first differentiation; determines previews, support, and moderation |
| Owner authentication | Random Keychain bearer secret | Smallest safe accountless protocol |
| Recovery | Generated offline code; management-only | Ensures lost devices can revoke without building cloud key sync |
| Anonymous expiry | 30-day default; 90-day maximum | Bounds orphaned and abusive storage while recovery proves itself |
| Selection default | Explicit contextual content only | Prevents accidental whole-meeting disclosure |
| Domain | `share.macparakeet.com` | Clear brand trust plus origin/deployment isolation; no new domain needed |
| Recipient analytics | None | Avoids false “views,” tracking, and privacy-policy expansion |
| Collaboration | Separate future ADR | It changes identity, sync, moderation, and scope fundamentally |
| Hosting | Separate Cloudflare Worker + D1 + private R2 | Minimal cost and operational fit; isolate from telemetry |
| Public release gate | Interop, privacy, recovery, abuse, legal, and mental-model evidence | Source presence and a working demo are not release proof |

## Final recommendation

Proceed—but prototype the trust boundary before building the polished feature.
The core idea is not “put transcripts on a website.” It is **let a person cut a
precise, temporary, encrypted window into one local speech-memory item.**

That design gives MacParakeet something cloud meeting tools cannot say with the
same credibility: the Library is still local, the disclosure is visible, the
host stores ciphertext, audio never uploads, and every published copy has an
owner-controlled lifecycle.

The machine-key instinct was directionally right: an account is not required.
The correction is to generate a revocable secret rather than derive an identity
from hardware. Pair it with a separate recovery code, treat the URL as the
recipient's key, and accept the honest limitation that anyone who receives that
URL can copy and forward the text.

The most valuable next artifact is a synthetic, throwaway cryptographic and
recipient-page prototype—not production infrastructure. It should answer three
questions cheaply: do links survive real sharing channels, do recipients
understand the privacy model, and can MacParakeet operate revocation and abuse
response without ever asking to see a transcript?

## Sources

[^1]: MacParakeet, “[ADR-027: Product North Star — Private Speech Memory](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/spec/adr/027-product-north-star.md),” accepted July 3, 2026; upstream snapshot accessed September 11, 2026.
[^2]: MacParakeet, “[Privacy Policy](https://macparakeet.com/privacy/),” updated July 9, 2026; accessed September 11, 2026.
[^3]: MacParakeet, “[TranscriptResultView.swift](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift#L1187-L1212)” and “[TranscriptResultActions.swift](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeet/Views/Transcription/TranscriptResultActions.swift#L5-L59),” upstream snapshot accessed September 11, 2026.
[^4]: Otter, “[Share a conversation](https://help.otter.ai/hc/en-us/articles/360048338793-Share-a-conversation),” updated May 16, 2024; accessed September 11, 2026.
[^5]: Fathom, “[Sharing Call Recordings](https://help.fathom.video/en/articles/295616),” edited June 4, 2026; accessed September 11, 2026.
[^6]: Descript, “[Export and publish content with Descript web links](https://help.descript.com/hc/en-us/articles/10255817744653-Export-and-publish-content-with-Descript-web-links),” current help page; accessed September 11, 2026.
[^7]: Proton, “[How to create a shareable link in Proton Drive](https://proton.me/support/drive-shareable-link),” current help page; accessed September 11, 2026.
[^8]: IETF, “[RFC 4086: Randomness Requirements for Security](https://www.rfc-editor.org/rfc/rfc4086.html),” June 2005.
[^9]: Apple, “[Keychain services](https://developer.apple.com/documentation/security/keychain-services/)” and “[Restricting keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility),” current developer documentation; accessed September 11, 2026.
[^10]: NIST, “[SP 800-63B-4: Authentication and Authenticator Management](https://pages.nist.gov/800-63-4/sp800-63b.html),” August 26, 2025.
[^11]: Apple, “[Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave),” current developer documentation; accessed September 11, 2026.
[^12]: Apple, “[DCAppAttestService.isSupported](https://developer.apple.com/documentation/devicecheck/dcappattestservice/issupported),” current developer documentation; accessed September 11, 2026.
[^13]: IETF, “[RFC 3986: Uniform Resource Identifier (URI): Generic Syntax](https://www.rfc-editor.org/rfc/rfc3986.html#section-3.5),” January 2005.
[^14]: W3C, “[Web Cryptography Level 2](https://www.w3.org/TR/WebCryptoAPI/),” current specification; accessed September 11, 2026.
[^15]: OWASP, “[HTML5 Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)” and “[Content Security Policy Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html),” current guidance; accessed September 11, 2026.
[^16]: Cloudflare, “[D1 limits](https://developers.cloudflare.com/d1/platform/limits/),” updated April 21, 2026; accessed September 11, 2026.
[^17]: Cloudflare, “[R2 pricing](https://developers.cloudflare.com/r2/pricing/),” current pricing; accessed September 11, 2026.
[^18]: Cloudflare, “[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),” updated August 28, 2026; accessed September 11, 2026.
[^19]: Cloudflare, “[D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/),” updated April 21, 2026; accessed September 11, 2026.
[^20]: Cloudflare, “[R2 consistency model](https://developers.cloudflare.com/r2/reference/consistency/),” current documentation; accessed September 11, 2026.
[^21]: Google Search Central, “[Robots meta tags specifications](https://developers.google.com/search/docs/crawling-indexing/robots-meta-tag),” current documentation; accessed September 11, 2026.
[^22]: Supabase, “[Pricing](https://supabase.com/pricing)” and “[About billing on Supabase](https://supabase.com/docs/guides/platform/billing-on-supabase),” current pricing; accessed September 11, 2026.
[^23]: Cloudflare, “[R2 object lifecycles](https://developers.cloudflare.com/r2/buckets/object-lifecycles/),” updated April 21, 2026; accessed September 11, 2026.
[^24]: Cloudflare, “[D1 Time Travel and backups](https://developers.cloudflare.com/d1/reference/time-travel/),” updated April 21, 2026; accessed September 11, 2026.
[^25]: European Union, “[Regulation (EU) 2016/679, Article 5](https://eur-lex.europa.eu/eli/reg/2016/679/art_5/oj/eng),” April 27, 2016.
[^26]: U.S. Copyright Office, “[DMCA Designated Agent Directory](https://www.copyright.gov/dmca-directory/)” and “[Section 512 resources](https://www.copyright.gov/512/),” current guidance; accessed September 11, 2026.
[^27]: Granola, “[Sharing notes](https://docs.granola.ai/help-center/sharing/sharing-notes)” and “[Sharing controls](https://docs.granola.ai/help-center/consent-security-privacy/sharing-controls),” current help pages; accessed September 11, 2026.
[^28]: Fireflies, “[Share Meeting Recaps](https://guide.fireflies.ai/articles/2474667467-share-meeting-recaps-with-teammates-participants-specific-people-user-groups-and-non-fireflies-users),” updated July 15, 2026; accessed September 11, 2026.
[^29]: Notion, “[Sharing and permissions](https://www.notion.com/help/sharing-and-permissions)” and “[Publish a Notion Site](https://www.notion.com/en-gb/help/public-pages-and-web-publishing),” current help pages; accessed September 11, 2026.
[^30]: Dropbox, “[How to set or change shared link permissions](https://help.dropbox.com/share/set-link-permissions),” updated February 20, 2026; accessed September 11, 2026.
[^31]: MacParakeet, “[ADR-002: Local-First Processing](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/spec/adr/002-local-only.md#L125-L131),” upstream snapshot accessed September 11, 2026.
[^32]: MacParakeet, “[Transcription.swift](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Models/Transcription.swift#L10-L87),” upstream snapshot accessed September 11, 2026.
[^33]: MacParakeet, “[TranscriptionViewModel.swift](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetViewModels/TranscriptionViewModel.swift#L1922-L1942)” and “[SpeakerAttributionReadService.swift](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Services/Diarization/SpeakerAttributionReadService.swift#L4-L53),” upstream snapshot accessed September 11, 2026.
