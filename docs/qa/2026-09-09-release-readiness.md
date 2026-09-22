# 0.8.0 final release review

The reviewed fixes are merged in [PR #992](https://github.com/moona3k/macparakeet/pull/992)
and final CI passed. The app and final DMG are signed, notarized, stapled, and
Gatekeeper accepted. **The 0.8.0 distribution candidate is ready.** Earlier
submissions remain `In Progress`, but the final clean submission below was
accepted and is the only artifact eligible for distribution.
No public release, appcast, Homebrew update, or download was published.

## Scope and source

- Baseline: `9eebffc7972548d0941456c8017cf46e58fde7f2`, after PR #991.
- Intended release: app **0.8.0**, embedded CLI **4.0.0**.
- Public channel verified on September 9: app **0.7.3**, standalone CLI **3.1.0**.
- Independent Cursor/Grok reviews covered recording/recovery and notes,
  prompt/label state, CLI contracts, packaging, and the Cohere backend decision.
- The earlier [September 7 QA](2026-09-07-0.8.0/README.md) applies only to the
  candidates named there. Its notarized package is not the final candidate.

## Release blocker and correction

The Meetings **After each meeting** chips wrote the development-only
`prompt_meeting_policies` table. Execution read canonical prompt auto-run fields
and label availability instead. Disabling Summary could leave it running;
enabling Action Items could leave it absent from the queue.

The card now writes source-scoped `.meeting` auto-run through the same repository
used by Prompt Library and execution. Its display uses label availability and
`Prompt.autoRuns(for:)`. Other source preferences are preserved. Returning to
Meetings refreshes its prompt snapshot, so edits made in the separate Prompts
screen are reflected without reloading the calendar or recent-meeting list.

Review also identified a misleading fallback on label-policy read errors. The
card preserves its last known restrictions, treats an initial failed load as
unknown, and displays an error instead of offering switches. A successful
legacy meeting-policy reload cannot clear the separate label-policy error.

No reverse migration is appropriate: published 0.7.3 already stores auto-run in
these canonical fields. The legacy table was introduced only in development.
Existing development testers may see the card return to the settings execution
actually used; they can re-toggle it to save their intended setting. No user
preferences were rewritten during this review.

## Verification before final CI

| Check | Evidence and scope |
| --- | --- |
| Baseline full CI | [34320892604](https://github.com/moona3k/macparakeet/actions/runs/34320892604) passed on a tree identical to `9eebffc7`: Release, CLI/package smoke, concurrency, Swift 6, full tests. This precedes the fix. |
| Original defect | Two production-wiring regressions failed before the fix. Real repositories plus a mock LLM prove queue selection without provider calls. |
| Focused fix tests | 72 workspace/result tests passed. Coverage includes Summary off, Action Items on, other-source preservation, hidden prompts, and labeled/unlabeled queues. |
| Tab-return defect | A separate real-repository regression failed before the refresh correction. All 22 workspace tests passed afterward, including unchanged calendar/list fetch counts. |
| Availability read errors | Regression failed before correction; all 23 workspace tests passed afterward. First-load errors hide unknown controls, later errors preserve restrictions, and legacy policy success cannot erase the error. Independent Grok review: LGTM. |
| CLI version | Two `CLIVersionTests` passed. Unreleased gateway notes and inference flags are recorded under the unpublished 4.0.0 release. |
| Distribution fixtures | Version and privacy validation fixture scripts passed; distribution scripts were not changed. |
| Initial real bundle | Built 0.8.0 / `20260909074325` at `9eebffc7`, CLI 4.0.0, required echo assets verified. **Predates fix; not a final artifact.** |
| Initial CLI runtime | Raw-mode local transcription/export and disposable-database collections, prompts, label colors/rename, versioned model/settings, label availability, and reset commands passed in that initial bundle. |
| Intermediate signed bundle | Build `20260909082721`, source `6c0200ae`, passed signing/privacy/echo checks, helper startup, and local transcription/export. Its notarization upload is preserved under submission `a2c56ec5-7fa1-4726-8732-a13f4d46708e`; it predates the availability-error correction and is superseded. |
| Isolated GUI startup | A separately identified copy of `6c0200ae` opened Meetings against a verified disposable SQLite path. Auto-note chips required AI setup, so no GUI toggle or provider configuration was attempted. The QA copy quit normally; the user's open app was untouched. |

Local detailed review and command logs are under `/tmp/macparakeet-release-*` on
the review host. They are supporting local evidence, not durable public assets.
The final candidate receipts below supersede the intermediate build checks.
DMG acceptance and stapling remain outstanding.

The installed no-mistakes daemon selects Claude and cannot select Grok per run.
Independent Cursor/Grok reviews and the normal GitHub gates honor the requested
model. Local Greptile requires authentication; its absence is not a review pass.

## Final candidate and receipts

- Reviewed/package source: `01751ce94a6c8655c1ad7056ac925c15d5685c4b`.
- Merged on remote main: `c93c837c2ed23a8cb6b1478dbfe20f4c00fb6d37`.
  Both have tree `2951a541a831fd76b53debb29a0c3155564b238d`.
- [Final CI 34332971965](https://github.com/moona3k/macparakeet/actions/runs/34332971965)
  passed: Release build, CLI contract smoke, packaged-app smoke, concurrency,
  Swift 6, and full tests (5,900 XCTest entries and 29 Swift Testing tests).
  No full local suite was run; focused tests preceded CI.
- CodeRabbit confirmed the availability-error fix and withdrew its proposed
  asynchronous loading mechanism. Both threads are resolved. Independent Grok
  correctness and maintainability reviews reached LGTM.
- App **0.8.0**, build **20260909090814**, embedded CLI **4.0.0**. Normal Xcode
  Release and SwiftPM CLI builds; no skipped-build metadata stamping.
- App/dSYM UUID: `9BC5DB51-D9E0-306D-9CEC-ACEE8200A1B9`.
- App archive SHA-256:
  `ec2ed253a33b4977d60863ef078b3484074cfc7cf2517d4178f5872199fa7cc6`.
- App notarization **Accepted**: `925ecc68-f09e-4791-9b74-5b64e13e52c5`.
  Stapler validation, Gatekeeper, signatures, privacy surface, and required echo
  assets passed. Signed yt-dlp 2026.08.19, Node v24.13.1, and FFmpeg 9.0.1 start.
- Final signed CLI passed local generated-audio transcription and Markdown export
  against an isolated SQLite database. No live provider inference was exercised.
- DMG SHA-256 before any staple:
  `2b4c16b5af9c544b5e5f3c5a52645d180cec0c28981824ca10713be100fd4b1f`.
- DMG submission: `87db18e5-31ce-4854-8f99-5407540ad391`, registered
  **2026-09-09 09:20:03 UTC**, status **In Progress**. The submit process exited 1;
  its output was lost inside the script's command substitution. The reason is
  unproven. The exact DMG is preserved, and was not resubmitted or stapled.
- Read-only mounted DMG checks passed: app/CLI/Info.plist hashes match the prepared
  app; embedded app signature, staple and Gatekeeper checks pass; embedded CLI
  reports 4.0.0. The verification mount was detached.

## Notarization recovery attempts

After the original DMG remained pending beyond the recovery boundary, a new
candidate was built from remote main `4dda4b81ca5f786a13dc1135c74de254c30b1437`.
This is a documentation-only successor to the final-CI source tree above.

- App **0.8.0**, build **20260909155335**, embedded CLI **4.0.0**; the app/dSYM
  UUID remains `9BC5DB51-D9E0-306D-9CEC-ACEE8200A1B9`.
- New app archive SHA-256:
  `b0a24fde6173814c2bdc26c1ce754d98f6f134f39dd35cb424d8ee693b7330a6`.
  App notarization **Accepted**: `0eab1692-8471-4717-a65a-5e700123f5ac`.
  Stapler validation and Gatekeeper assessment passed.
- New signed DMG SHA-256 before any staple:
  `2491acfcfa7af6515c993fae99484d7952b9ff21f3ef2fdcce728057074fa117`.
  Signature and `hdiutil verify` passed; the read-only mounted payload contains
  the expected stapled app, `/Applications` alias, and CLI 4.0.0.
- The direct upload ended with `Network.NWError 54` (connection reset by peer)
  after multipart transfer. Its registered submission
  `00fa77f5-1181-405e-8a2f-cb4e61a45dbc` remains `In Progress`.
  Two alternate client-path submissions were also registered as
  `e2a27ceb-ce3e-4900-85aa-eaac5eacc7f2` and
  `661f89e5-1064-43e8-9428-15be377e1ce0`; both remain `In Progress`.
  The accelerated paths crashed locally with `SIGBUS` in Xcode 26.4.1
  `notarytool` networking code. No proxy was configured.

Apple documents that the distributable disk image is the outermost container and
supports stapling directly. A ZIP wrapper would not meet that requirement,
because tickets cannot be stapled to ZIP archives. Duplicate uploads were paused
until the separate full restart below. On acceptance, staple the exact DMG,
validate the staple and Gatekeeper assessment, and record its post-staple hash.
On `Invalid`, retrieve the notarization log before changing the artifact.
Supporting receipts are under `/tmp/macparakeet-release-restart-*` on the review
host.

### Second clean restart

A full restart from remote main `89f098b1e8158d39a1e1c116a1d6aa6b6c98b26a`
rebuilt the app and DMG without reusing a generated bundle. The code is unchanged;
the source difference is this release-evidence document.

- App **0.8.0**, build **20260909162325**, embedded CLI **4.0.0**.
  The app archive SHA-256 is
  `d8956461d959d0e4b768d7e7e20cc90f736504d8f4363d41884b0c4931a45086`.
  Notarization **Accepted**: `c1555a9f-0c12-4de6-b8d0-79bc7463190d`;
  stapler and Gatekeeper validation passed.
- The newly signed DMG SHA-256 is
  `3d255cb99febda928518b84375096a518de9cc470505e4df601520b82e233dc3`.
  Signature, image checksum, mounted payload, Applications alias, and embedded
  CLI checks passed.
- The one fresh DMG submission, `7e8c33ca-2abb-4652-a66c-1f895a77f844`, again
  failed locally with `Network.NWError 54` after its first multipart part and is
  registered at Apple as `In Progress`. This reproduces the DMG-only transport
  failure after a complete rebuild while app uploads continue to succeed.

The normal release process was paused at this external transport boundary. The
final clean submission below demonstrates a completed upload; the earlier pending
IDs are not release artifacts and must not be stapled or published.

### Third clean retry

At the user's direction, a third clean rebuild was attempted from remote main
`a9a22f8996ce801b68b074965728bff949d2e0c1`. The new app archive
`04f936b36863ec3e229050941fb12f7334edb3480d987436347e55cf301db6b4`
encountered the same `Network.NWError 54` after all 20 multipart parts were
uploaded. Its submission `b3356473-1d7a-4837-b0e2-f1cb5bc72e79` remains
`In Progress` after the normal five-minute window. No DMG was created from this
attempt because app notarization did not complete. This demonstrates that the
host transport failure is no longer DMG-specific.

### Final clean submission

A subsequent user-directed clean restart from remote main
`1cc48e726ad457da013aee9ba4269625e3b66f67` completed both upload paths.

- App **0.8.0**, build **20260909173236**, embedded CLI **4.0.0**. App archive
  SHA-256: `028e4c4869a76133af4e550aff6a4dfa9cb158494d1a95c6a6fa7af79e49eab5`.
  Notarization **Accepted**: `6f2178d3-8df2-453e-991f-d57d263e08ee`.
  Stapler validation and Gatekeeper assessment passed.
- DMG SHA-256 before stapling:
  `db7fb0ff0583ed06612578fc5ef207f10c6363f91f0d3af4c0c267369dcce461`.
  Notarization **Accepted**: `257e1484-7b77-47e7-851d-8b9fedbe4832`.
  Final stapled DMG SHA-256:
  `a82b5f5e1c64272766e09a1985b627aad41960c6eba3ac7b1b9359927b8da474`.
- Final DMG stapler validation, disk-image checksum, signing, and Gatekeeper
  assessment passed. A read-only mount contains the expected app, `/Applications`
  alias, stapled app ticket, and embedded CLI 4.0.0.
- The optional Finder layout script returned `-1728` while addressing the
  temporary mounted volume. This does not affect the signed payload or
  drag-to-Applications flow, but the custom icon positions were not visually
  verified. Treat this as a publication-time visual QA item.

No public release, appcast, Homebrew update, or download was published during
this review. Those publication actions remain separate from candidate readiness.

The older development app still has an **Edit Prompt** sheet open. It was not
force-quit or replaced, and no editor contents were discarded. A normal local
restart remains pending closure of that sheet.

## Release scope and remaining coverage

| Item | Disposition |
| --- | --- |
| [PR #865](https://github.com/moona3k/macparakeet/pull/865), transcribe.cpp Cohere | Defer. Open/conflicting, significant backend and packaging change. Retain current FluidAudio/CoreML Cohere. |
| [PR #974](https://github.com/moona3k/macparakeet/pull/974), FluidAudio 0.15.6 | Already merged and included; no new inclusion decision. |
| [#933](https://github.com/moona3k/macparakeet/issues/933), [#949](https://github.com/moona3k/macparakeet/issues/949), [#952](https://github.com/moona3k/macparakeet/issues/952) | Existing hardware/hotkey/Whisper reports remain unresolved. Do not advertise them as fixed by this review. |
| [#976](https://github.com/moona3k/macparakeet/issues/976), [#977](https://github.com/moona3k/macparakeet/issues/977) | Existing capture/Line In reports; affected hardware not exercised here. |
| GUI, live external providers, Bluetooth/system-audio combinations, stable-to-candidate Sparkle upgrade | Not certified by these source reviews or mocked tests. |
| Standalone CLI/Homebrew 4.0.0 | Separate publication; the app may embed 4.0.0 while Homebrew remains on 3.1.0. |

## Proposed release highlights

Use the stable-to-candidate inventory when preparing the final public notes:
meeting startup/recovery improvements and saved notes; Library labels, favorites,
and generated recording covers; clearer transcript-prompt and Live Ask management;
model-aware generation controls; richer transcript/results display and export;
and the bundled agent-facing CLI. Do not imply every reported capture problem
or every provider/model combination has been verified.

**CLI 4.0.0 compatibility:** `export --stdout --format txt` now matches TXT file
export, including header, timestamps, and speakers. Callers needing bare text
should use the documented JSON transcript fields. Prompt collections/history,
labels, inference controls, and optional meeting-note context are documented in
[the CLI changelog](../../Sources/CLI/CHANGELOG.md) and
[the integration guide](../../integrations/README.md).
