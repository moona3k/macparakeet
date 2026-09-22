# PR #979 hosted review disposition

**No newly established product blocker in the latest hosted review.** The latest code comment repeats the known stale-dialog discard case. Removing a folder merely because its recovery lock is missing would weaken the audio-preservation fix. Valid evidence-path and stale-documentation findings are corrected in this report follow-up. PR #979 merged at `e476f1567d0e1ed8aaeedf29751c871262d33b93` after both exact-head CI runs passed; [final CI receipt](evidence/pr979-ci-summary.json).

## Reviewed snapshot

- PR: [#979](https://github.com/moona3k/macparakeet/pull/979).
- Hosted and local source head: `250bbe2994a4b60b4ef81ac257f0ee6bb70874d3`.
- [Initial CodeRabbit review](https://github.com/moona3k/macparakeet/pull/979#pullrequestreview-5135747611): `3827999ddb84c8a8e0edcb3ac190e66813fc95fe`, submitted 2026-09-07 23:20:19 UTC.
- [Latest CodeRabbit review](https://github.com/moona3k/macparakeet/pull/979#pullrequestreview-5135835303): `250bbe29`, submitted 2026-09-07 23:36:14 UTC. CodeRabbit and cubic checks report success; both Swift CI jobs were still running at this refresh.
- Nine review threads fetched with no further page. All nine were unresolved at the read-only snapshot. Latest review body also contains three outside-diff comments, assessed below.
- No GitHub posts, replies, review submissions, or thread resolutions were made by this reviewer. Proposed replies below are for the root agent after it pushes the matching corrections.

Hosted review limits remain explicit: Greptile skipped the initial 117-file PR because of its 100-file limit. CodeRabbit excludes `scripts/dist/build_app_bundle.sh` through its `!**/dist/**` filter. Hosted success is not coverage of that packaging script or a release-certification result.

## Thread responses

### 1. Original audio evidence paths — corrected locally

Thread `PRRT_kwDORMx8l86gC770`, [comment r3953090199](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953090199).

> Replaced workstation-specific prefixes with `<PUBLIC_CORPUS>`, `<QA_WORKTREE>`, and `<QA_RUN>` in the requested audio evidence files and made the audio-review recipes use explicit local variables. Replacement handles both plain and JSON-escaped slashes. Parsed JSON comparison confirms every non-path value is unchanged; transcript results, timings, hashes, and candidate identifiers are preserved. The path-redaction receipt records source and curated hashes.

### 2. Additional original audio stdout paths — corrected locally

Thread `PRRT_kwDORMx8l86gC774`, [comment r3953090206](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953090206).

> Applied the same path-only redaction to the four cited stdout files and the other original audio stdout receipts. Swift JSON escapes slashes, so validation now inspects decoded strings as well as the serialized text. All non-path values remain identical; source hashes are preserved in the redaction receipt.

### 3. GUI duration interpretation — preserve the raw receipt

Thread `PRRT_kwDORMx8l86gC779`, [comment r3953090213](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953090213).

> This file is the raw observed GUI persistence receipt: `durationMs` was 9600. It does not assert a 10560 expected value. Preserving the receipt avoids rewriting observed evidence. `TranscriptionService` uses its metadata baseline and may extend it to the latest word end; stream duration alone is not a persistence oracle. No full-duration correctness pass is inferred from this receipt.

Assessment: the interpretation caution is useful, but changing the measured value would falsify evidence. The raw receipt remains unchanged. The baseline run did not retain a separate metadata-extractor-duration measurement, so no stronger equality assertion was added after the fact.

### 4. Stale release-status inventory — corrected locally

Thread `PRRT_kwDORMx8l86gC78A`, [comment r3953090216](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953090216).

> Updated `release-inventory.md` to mark the baseline documentation findings as corrected in this branch. The per-prompt settings status now reflects implemented on development main and unreleased; the old catalog/search/cards wording is explicitly historical.

### 5. Health command mutation claim — not supported by current code

Thread `PRRT_kwDORMx8l86gC78F`, [comment r3953090222](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953090222).

> The specific health contract already says its database probe does not create or migrate the database and default invocation does not create application directories (`cli-json-v1.md`, Health section). `HealthCommand` calls `probeHealthDirectories` and `DatabaseManager(readOnlyPath:)`, rather than the creating/migrating database initializer. The earlier catalog paragraph describes read commands generally; it does not override this explicit health guarantee. Keeping the inventory row consistent with the implementation and specific contract.

Assessment: confirmed through `Sources/CLI/Commands/HealthCommand.swift` and the explicit Health section of `spec/contracts/cli-json-v1.md`. No product change is justified by this comment.

### 6. Repeated completed-session discard — accepted narrow UX follow-up

Thread `PRRT_kwDORMx8l86gC78J`, [comment r3953090228](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953090228).

> Confirmed a narrow stale-dialog UX case: repeating discard after completed-row settlement retains audio but finds no lock and reports `missingLock`. The current contract requires claiming the current lock and only guarantees a no-op for a missing folder. This does not delete completed audio. Keeping completed-row idempotence as a follow-up; a fix must verify the matching completed meeting row and preserve live-writer/lease refusal, rather than suppressing all `missingLock` errors.

Assessment: the existing tests cover repeated missing-folder discard, completed-row audio preservation, restoration after partial deletion, and refusal of replacement/live ownership. They do not establish a successful second discard of an already-settled completed row. No new regression test or product edit was made during this read-only review.

### 7. Extended Cohere paths and report — corrected locally

Thread `PRRT_kwDORMx8l86gDFsH`, [comment r3953153369](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953153369).

> Redacted the escaped fixture paths in all three extended Cohere stdout files and the workstation paths in `cohere-extended.md`, using the existing `<PUBLIC_FLEURS>` and `<QA_ROOT>` placeholders. Recomputed each changed stdout artifact's `curatedSHA256` and `sizeBytes`; `sourceSHA256` is unchanged. Parsed JSON comparison confirms all other values are preserved. The original audio stdout files were checked for the same escaped-slash issue and corrected as well.

Assessment: this resolves the specifically cited Cohere files and the corresponding report. It does not claim a fresh whole-directory audit of every historical raw build log or command recipe; those can contain intentionally local reproduction paths.

### 8. Extended Cohere stdout hashes — corrected locally

Thread `PRRT_kwDORMx8l86gDFsI`, [comment r3953153373](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953153373).

> Replaced the Japanese and Korean `filePath` prefixes with `<PUBLIC_FLEURS>`, and fixed the identical Mandarin encoding case. The manifest now records the corrected `curatedSHA256` and `sizeBytes` for each. Original `sourceSHA256` values are preserved, and every manifest artifact's curated hash and byte count was verified.

### 9. Temporary browser evidence links — corrected locally

Thread `PRRT_kwDORMx8l86gDFsK`, [comment r3953153377](https://github.com/moona3k/macparakeet/pull/979#discussion_r3953153377).

> Curated the inspected browser screenshots, results, logs, and portable runners under `evidence/report-browser/` and replaced the temporary links with relative links. The manifest records source/curated hashes and sanitization. Historical 106/107-before-fix and 26/26-after-fix results retain their snapshot provenance; later data-only synchronization is recorded separately. Local link existence and runner/JavaScript syntax checks passed.

## Latest outside-diff comments

These appear in [the latest review body](https://github.com/moona3k/macparakeet/pull/979#pullrequestreview-5135835303) and have no separate review-thread IDs.

1. **`MeetingRecordingRecoveryService.swift:418–422`, Major, `missingLock` discard.** This repeats the known stale-dialog concern but proposes broader lockless-folder removal. Do not implement that fallback. Recovery discovery requires a lock; a later missing lock can mean another process completed and settled the recording, leaving valid audio. The current partial-deletion correction restores a removed lock under the ownership mutex; restoration I/O failures remain errors with surviving audio preserved. A generic lockless deletion would undo the safety boundary. Proposed reply:

   > Keeping the ownership check fail-closed. A lock can disappear because another process successfully settled a completed recording, so its absence cannot authorize deleting the remaining audio folder. Partial-discard failure now restores a removed recovery marker under the ownership mutex and preserves any replacement owner's lock. The narrower repeated completed-row UX case is retained as a follow-up; no blanket lockless deletion will be added.

2. **`release-inventory.md:32–34`, stale per-prompt status.** Duplicate of thread 4; corrected locally with its proposed reply.
3. **`release-inventory.md:73`, health mutation wording.** Duplicate of thread 5; the explicit Health contract and read-only database probe support the existing guarantee.

## Verification and remaining limits

The review used read-only GitHub GraphQL/PR queries and current source/test/contract reads. Local corrections touched documentation and curated evidence only. Parsed before/after JSON comparison checks path substitutions without changing transcript fields or outcomes; manifest hashes and sizes were recomputed and checked. No GUI, clipboard, private notes, audio, product build, Swift test, or external mutation was performed.

The read-only review snapshot above is historical. Both CI runs subsequently passed at `250bbe29`, the package received Apple acceptance, and PR #979 merged. The quoted responses describe the matching report corrections; root will post them after this report commit is published, so this document does not claim they were already sent during review.
