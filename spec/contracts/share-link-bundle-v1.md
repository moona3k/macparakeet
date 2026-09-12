# Share Link and Bundle v1

> Status: **Implemented v1 contract; public enablement pending**
> Release status and evidence: [implementation handoff](../../docs/share-links-implementation.md)

## Purpose

This contract defines the complete recipient link, encrypted envelope, and decrypted text bundle exchanged by the Mac app and the browser viewer.
It keeps cryptographic interoperability and content exclusions stable while allowing the app UI and service implementation to evolve independently.

## Producers and consumers

- **Producers:** the Mac app's share projection, serialization, encryption, and link construction code.
- **Consumers:** the first-party viewer at `share.macparakeet.com`, native share management, shared cryptographic fixtures, and compatibility tests.
- **Transport:** the [Share Service v1](share-service-v1.md) stores and returns the envelope without decrypting it.

## Complete link

The complete v1 URL is:

```text
https://share.macparakeet.com/s/<locator>#v1.<content-key>
```

- `locator` is exactly 16 cryptographically random bytes encoded as 22 unpadded base64url characters.
- `content-key` is exactly 32 cryptographically random bytes encoded as 43 unpadded base64url characters.
- `v1` is the fragment format version.
- Invalid versions, lengths, alphabets, or encodings fail closed.
- The fragment is never intentionally placed in an HTTP request, referrer, log, diagnostic, crash report, or support artifact.
- Explicit updates keep the same locator and content key.
- V1 has no rotate operation; replacing a disclosed link means creating a new share and permanently stopping the old one.

The UI may abbreviate a URL for display, but copy and the macOS share sheet must use the complete value.

## Encrypted envelope

The service stores this JSON object:

```json
{
  "schema": "com.macparakeet.share-envelope",
  "schemaVersion": 1,
  "algorithm": "A256GCM",
  "nonce": "base64url-12-random-bytes",
  "ciphertext": "base64url-ciphertext-followed-by-16-byte-tag"
}
```

Stable rules:

- Encryption is AES-256-GCM with the 32-byte `content-key`.
- `nonce` is 12 fresh random bytes for every content revision and must never repeat for one content key.
- V1 does not compress plaintext.
- `ciphertext` contains the encrypted plaintext followed by the 16-byte GCM authentication tag, matching the Web Crypto result representation.
- The maximum UTF-8 plaintext bundle is 2,097,152 bytes; the maximum decoded ciphertext plus tag is 2,097,168 bytes.
- The service validates envelope shape and size but cannot validate decrypted bundle fields.
- Unknown envelope versions or algorithms are rejected rather than guessed.

The exact additional authenticated data is the UTF-8 encoding of this sequence, with `\0` representing one zero byte:

```text
com.macparakeet.share-envelope\0v1\0<locator>\0<content-revision>
```

`content-revision` is an unpadded base-10 integer beginning at `1` and increasing by exactly one for each explicit snapshot update.
Expiry is not authenticated in this envelope because it is independently mutable server state.

## Decrypted bundle

The authenticated plaintext is UTF-8 JSON with this shape:

```json
{
  "schema": "com.macparakeet.share-bundle",
  "schemaVersion": 1,
  "publishedAt": "2026-09-11T22:00:00Z",
  "title": "Optional selected display title",
  "source": {
    "kind": "meeting",
    "displayDate": "2026-09-11T20:00:00Z",
    "durationMs": 3600000
  },
  "sections": [
    {
      "kind": "summary",
      "title": "Summary",
      "markdown": "## Decisions\n\nSelected display-ready text."
    },
    {
      "kind": "notes",
      "title": "Notes",
      "markdown": "Owner-authored notes."
    },
    {
      "kind": "transcript",
      "title": "Transcript",
      "segments": [
        {
          "text": "Selected transcript text.",
          "startMs": 12300,
          "endMs": 15800,
          "speaker": "Jordan"
        }
      ]
    }
  ]
}
```

Stable bundle semantics:

- `schema`, `schemaVersion`, `publishedAt`, and at least one non-empty section are required.
- `publishedAt` is the whole-second UTC time of the current encrypted content revision. It is refreshed on every explicit content update and is the viewer's displayed updated time; an expiration-only change does not alter it.
- Optional values are omitted rather than guessed or emitted as `null`.
- `source.kind` is one of `meeting`, `file`, `web`, `podcast`, or `other`.
- Summary sections may repeat; notes and transcript occur at most once.
- Section order defines display, copy, and download order.
- Summary and notes Markdown is treated as untrusted input. Raw HTML and automatic remote assets are not rendered. A restricted renderer may construct safe DOM nodes directly; any renderer producing HTML must use a reviewed sanitizer before insertion.
- Transcript segments contain non-empty `text` and may include the current display speaker label.
- `startMs` and `endMs` are either both present or both absent, with `0 <= startMs <= endMs`.
- Unknown section kinds invalidate the bundle.

The share projection may include only the selected display title, source kind, display date, duration, summary text and display titles, notes, transcript text, timestamps, and current speaker labels.
The Core projection's `ShareSelection.includeMetadata` defaults to false and independently controls the bundle title and source metadata. Transcript export formatting options do not opt those fields in; the app passes the owner's explicit preview selection.
It must exclude audio, local record or segment IDs, paths, artifact locations, source URLs, thumbnails, confidence values, model or provider details, prompt instructions, generation receipts, chat, calendar and attendee data, meeting URLs, capture diagnostics, and every unselected field.

## Non-stable presentation

Viewer typography, colors, layout, button placement, human-readable errors, and the Mac app's Share-sheet composition may change without a bundle version bump.
Contextual selection defaults are governed by [Shareable Transcript Snapshots](../15-shareable-transcripts.md), not the wire bundle.

## Versioning and compatibility

V1 readers must ignore unknown additive object fields but reject unknown `schema`, `schemaVersion`, section kinds, and cryptographic algorithms.
Removing or changing a stable field, encryption rule, AAD byte, size boundary, or section semantic requires a new version and a compatibility plan for active links.
The service must retain the viewer support needed to open every unexpired version it accepted.

## Tests that enforce this

- Native `ShareLinkContractTests` cover link grammar, fragment parsing, malformed inputs, and proof that generated HTTP requests omit fragments.
- Native `ShareCryptoEnvelopeTests` and browser viewer tests consume the implementation-created `spec/contracts/fixtures/share-crypto-v1.json` and cover Swift-to-Web-Crypto interoperability, wrong keys, wrong locators, wrong revisions, mutation, truncation, and nonce freshness.
- `node scripts/dev/verify_share_crypto.mjs` parses the fixture with JavaScript and independently verifies its authenticated bytes with Web Crypto, including all five negative mutations.
- Native `ShareBundleV1Tests` cover required fields, revision-time updates, size limits, transcript timing pairs, speaker omission, safe Markdown handling, unknown kinds, and the privacy allowlist.
- Browser tests cover maximum payload rendering, hostile Markdown and segment content, CSP enforcement, no external asset requests, local copy and downloads, and generic failure behavior.

## When this changes

Update this contract, its shared fixture, native tests, viewer tests, and the service compatibility matrix in the same coordinated change.
