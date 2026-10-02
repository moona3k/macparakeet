# CLI, durable data, and trust-boundary audit

Audit date: 2026-10-02. Baseline: `f43f4bed2`. Scope: first-party CLI entry points, public automation contract, persistence and recovery boundaries, selected filesystem and subprocess boundaries. Line references below identify the baseline unless marked as an audit change.

The CLI has a substantial, documented automation surface and useful safeguards. The strongest actionable defect is an extra persistence step in CLI retranscription that undoes the shared service's concurrency protection. The appropriate architectural response is to keep completion ownership in Core and return its committed result. Adding more metadata-copy code at the CLI layer would make this worse.

This was a targeted code and runtime audit, not exhaustive formal verification of every command, every migration, or third-party native dependencies. No user database, transcripts, credentials, provider account, or retained recording was opened for this lane.

## Observed runtime evidence

[CLI process probes](evidence/cli-process-probes.json) exercised the baseline built binary with telemetry disabled, a temporary app-state directory, and a synthetic database. Process exit status and stdout/stderr were observed separately.

| Probe | Observed result |
|---|---|
| `--version` | `5.0.0`, exit 0 |
| `spec --json` | Parseable JSON, 157,612 bytes, exit 0 |
| `health --json`, absent isolated state | Exit 0, database `missing`, no state directory created |
| `history --json`, new explicit database | Parseable empty array, exit 0; initialized the synthetic database |
| Missing transcript, JSON mode | One error envelope on stdout, `errorType: lookup`, exit 1 |
| Missing meeting export, JSON stdout mode | One error envelope on stdout, `errorType: lookup`, exit 1 |
| Invalid invocation / missing required `--update` | Empty stdout, plain stderr, exit 2 |

The one-shot measurements were 18 ms for `spec`, 150 ms for health, 116 ms for initial history/database creation, and 26–30 ms for warm missing-record lookups. The first `--version` took 852 ms. These are local process samples, not p50/p95 estimates, a packaged-release benchmark, or model latency measurements. Caches, executable first use, and host activity were uncontrolled.

[Catalog coverage](evidence/cli-catalog-coverage.json) compares the running binary's `spec --json` with ArgumentParser's complete `--experimental-dump-help` tree. All 139 product leaf commands are cataloged; the only additional leaf is built-in `help`. Every catalog path exists. The hypothesis that a current command was missing from the catalog was rejected.

A [10,000-row synthetic dictation probe](evidence/cli-prefix-scale.json) stored
4,320 bytes of raw text per row and ran five full CLI invocations per lookup
shape. Exact-ID lookup (ending in missing-audio validation) had a 154 ms median;
ambiguous-prefix lookup had a 149 ms median. This did **not** demonstrate an
end-to-end prefix latency regression: process/database initialization and the
slightly different terminal paths remain confounders. The full-history decode
below is source-proven unnecessary work, not a measured production slowdown.

## Findings and prioritized recommendations

### [CLI-DATA-01] Let Core own the completed retranscription row

- **Evidence**: `Sources/CLI/Commands/RetranscribeCommand.swift:496-505` and `:537-555` await completed Core retranscription, then copy the original metadata back and issue another generic save. The helper at `:680-699` restores stale notes, chat, favorite, title, audio and artifact pointers. `Sources/MacParakeetCore/Services/TranscriptionService.swift:2257-2259` already uses the atomic `savePreservingUserMetadata` boundary; `Sources/MacParakeetCore/Database/TranscriptionRepository.swift:321-336` rejects deleted rows and merges live metadata in its write transaction.
- **Trigger**: Retranscribe a retained recording through the CLI while renaming it, editing/clearing notes, changing its favorite state, or detaching audio through another surface. A deletion after Core's save but before the CLI's extra save is another affected interleaving.
- **Impact**: The CLI can lose user edits and recreate a deleted recording. Restored stale paths can also disagree with current assets. The affected file path includes retained local, YouTube and podcast sources; meeting paths include archived and fallback processing.
- **Effort**: S, including deterministic regression coverage and contract documentation.
- **Risk**: LOW–MED. Remove redundant writes; verify preserved source metadata and committed payloads across source kinds rather than changing Core persistence semantics.
- **Confidence**: HIGH from source tracing; audit regression verification is recorded below.
- **Fix sketch**: Return the row Core has already committed. Delete the stale copy helper and generic post-completion saves. Keep source identity, public output shape and explicit `--update` requirement.
- **Audit disposition**: Fixed in the audit branch; focused regressions passed. The test seam invokes the real Core service and SQLite repositories with deterministic audio/STT substitutes; it does not measure real recognition quality.

### [CLI-DATA-02] Prevent nonfailed dictation reruns from resurrecting deleted takes

- **Evidence**: `Sources/CLI/Commands/RetranscribeCommand.swift:436-438` unconditionally saves a rerun when the original row was not failed. The failed-take path already uses `saveIfCurrentStatus` at `:446`; `Sources/MacParakeetCore/Database/DictationRepository.swift:142-155` performs that existence/status check and write in one transaction.
- **Trigger**: Delete a completed or cancelled dictation after the CLI resolves its retained recording but before recognition finishes, or complete that cancelled take through another operation.
- **Impact**: Generic save can recreate deleted history, overwrite an intervening status transition and recount a previously completed take in lifetime statistics.
- **Effort**: S.
- **Risk**: LOW. Reuse the existing atomic guard and preserve the failed-take recovery branch and successful same-status statistics updates.
- **Confidence**: HIGH from direct source flow; audit regression verification is recorded below.
- **Fix sketch**: Require the nonfailed row still to exist with its original status before persisting. Report the existing lookup-error class if it no longer qualifies.
- **Audit disposition**: Fixed in the audit branch; focused completed/cancelled deletion, changed-status rejection, and successful completed-take statistics tests passed.
- **Remaining boundary**: This status guard is not a general revision check. Concurrent changes to dictation `displayRawTranscript` or audio metadata can still be overwritten by a same-status full-row save. A future repository operation should merge those user-owned fields or reject a stale revision; this audit does not claim to have solved all concurrent dictation editing.

### [CLI-DATA-03] Put byte budgets on external CLI output

- **Evidence**: `Sources/MacParakeetCore/Services/LLM/LocalCLIExecutor.swift:565-574` reads both child streams to EOF into unbounded `Data`. The process timeout is a time budget (`:589-591`), with a default of 300 seconds (`:15-16`), not an output budget. `Sources/MacParakeetCore/Services/YouTubeDownloader.swift:293-318` similarly retains all downloader stderr while it runs.
- **Trigger**: A configured external helper emits excessive progress/debug output or enters an output loop before its timeout.
- **Impact**: The main process retains all bytes, then creates additional strings for decoding/sanitization. A time-bounded helper can still cause substantial memory pressure or an out-of-memory termination. This is a resource-containment concern; the user-selected shell template itself is an intentional product capability, not an injection finding.
- **Effort**: M.
- **Risk**: MED. Oversized legitimate generated content must fail explicitly, not be silently truncated into a successful answer. stderr may use a bounded tail for diagnostics.
- **Confidence**: HIGH for the unbounded allocation; MED for incidence. No production memory incident was reproduced in this lane.
- **Fix sketch**: Drain in chunks with separate stdout/stderr budgets, terminate owned processes on stdout limit, and return a typed failure. Add tests for over-budget output, retained stderr tail, cancellation and no blocked pipe writers. Keep existing user-approved command execution and environment behavior.

### [CLI-DATA-04] Stop decoding entire records for lookup and count operations

- **Evidence**: `Sources/CLI/Commands/CLIHelpers.swift:228-229` resolves a dictation prefix by fetching and decoding every visible dictation before filtering. `Sources/CLI/Commands/StatsCommand.swift:26` obtains a favorite count by fetching full favorite transcriptions. `Sources/MacParakeetCore/Database/DictationRepository.swift:235-249` confirms the unbounded default fetch.
- **Trigger**: A long-lived local library queried repeatedly by an agent, especially one with lengthy transcripts and word/speaker timing payloads.
- **Impact**: Prefix lookup has linear Swift allocations in history size; a scalar favorite count reads and decodes full transcript rows unnecessarily. The 10K-row process probe above did not show a latency penalty; attribution would need a repository-level allocation/query benchmark.
- **Effort**: S for dedicated SQL-backed lookup/count operations and equivalence tests; M including a representative synthetic-library benchmark.
- **Risk**: LOW. Keep UUID normalization, ambiguity rules and hidden-row filtering identical; do not hand-write incompatible UUID serialization.
- **Confidence**: HIGH for the work performed; MED for user-visible latency without a large-library measurement.
- **Fix sketch**: Add repository prefix lookup limited to enough matches to establish ambiguity, and `favoriteCount` using a database count. Benchmark 1K/10K/100K synthetic rows before broad repository refactoring.

### [CLI-DATA-05] Qualify a recoverable whole-library backup workflow

- **Evidence**: `Sources/CLI/Commands/ExportCommand.swift:6-12` and `:105-120` export individual transcripts in document formats; `Sources/CLI/Commands/MeetingImportCommand.swift:13-23` imports media as a new meeting. `Sources/MacParakeetCore/Database/README.md:122-149` distinguishes canonical rows from derived segments/cards, while split receipts and share revocation authority deliberately have independent lifetimes later in that document. A search of the CLI/database tree found no whole-library backup/restore command.
- **Impact**: Users who rely on the app as durable local speech memory need a demonstrable recovery route for database records, original audio, notes, corrections, prompt versions and required receipts. Text export and media re-import do not reconstruct that state. This is a product/recovery recommendation, not evidence that current files are being lost.
- **Effort**: L, initially a design and restore drill rather than immediate feature implementation.
- **Risk**: HIGH for a new restore implementation: migration skew, SQLite consistency, missing media, duplicate IDs and secret/revocation handling require explicit semantics.
- **Confidence**: MED. The inspected surfaces lack the workflow; external Time Machine or user backup arrangements were not audited.
- **Fix sketch**: First document and test an offline consistent backup/restore procedure against synthetic libraries and prior schema snapshots. Then decide whether to expose a versioned archive command. Define canonical versus rebuildable data and verify restoration into a new account before claiming recoverability.

## Architecture and contract assessment

The shared Core/repository layer is the right center of gravity. Repositories serialize writes, migrations are process-locked, and important operations use transactional preconditions. The main maintenance concern is duplicated orchestration at the app/CLI boundary: CLI wrappers can undo guarantees correctly implemented below them, as the retranscription defect demonstrates. Prefer thin adapters that parse, invoke a shared use case, and serialize the result.

The CLI is intentionally not a mirror of interactive microphone capture, onboarding screens, or the live meeting panel (`integrations/README.md:20-64`). That is a stated product choice. Useful parity already exists for library/search/export, notes, speaker corrections, prompt editing and task routes. A full GUI-equivalent live-capture CLI is not recommended merely for symmetry.

The public contract is unusually explicit about JSON success/failure, stdout versus stderr, post-parse versus parse errors, and exit codes (`Sources/CLI/README.md:46-64`, `spec/contracts/cli-json-v1.md`). The process probes support that contract on the exercised paths. `health` is genuinely non-repairing in the missing-state probe; `history --database` can initialize/migrate a database by documented design. Consumers should not reinterpret catalog `readOnly` as a filesystem sandbox.

Maintain the hand-authored semantic descriptions, but add reverse coverage of nested product leaf commands to `SpecCommandTests`: current tests cover registered roots and advertised paths (`Tests/CLITests/SpecCommandTests.swift:238-251`, `:288-317`). Runtime comparison found no drift today. This is preventive test coverage, not a current product defect or justification for a new metadata framework.

## Durable data and security assessment

Positive evidence observed in code:

- File-backed migration locking, foreign keys and a five-second busy timeout are explicit (`Sources/MacParakeetCore/Database/DatabaseManager.swift:19-24`, `:74-79`). Health uses a read-only initializer rather than applying migrations.
- Shared transcription completion merges current metadata and refuses to recreate a missing recording (`Sources/MacParakeetCore/Database/TranscriptionRepository.swift:321-336`). CLI completion needed to respect that ownership.
- Meeting import builds in a managed staging folder under a media mutation lease, publishes its folder before creating the durable row and retains retryable failures (`Sources/MacParakeetCore/Services/MeetingImport/MeetingImportService.swift:144-205`). The apparent stale-staging race is protected by the common lease; it was not reported as a defect.
- Whole-meeting audio clearing refuses sessions that are recording or await transcription/recovery (`Sources/CLI/Commands/HistoryCommand.swift:435-447`). Asset cleanup has managed-path and active-finalization checks.
- Transcription deletion enqueues durable sharing stop intent before asset removal and obtains the relevant media/child-processing leases (`Sources/MacParakeetCore/Services/Sharing/TranscriptionDeletionCoordinator.swift:12-25`). This is a stronger boundary than directly deleting the SQLite row.
- yt-dlp executes through argv with `--` before the URL (`Sources/MacParakeetCore/Services/YouTubeDownloader.swift:400-435`). Local CLI prompt data is delivered through stdin (`Sources/MacParakeetCore/Services/LLM/LocalCLIExecutor.swift:576-586`). User-configured shell templates and standard proxy/PATH inheritance are intentional surfaces.

These observations do not establish complete absence of injection, filesystem race, data-loss, or supply-chain defects. Cryptographic sharing, Keychain access, endpoint auth, all decoder paths and third-party binaries were not comprehensively audited here. No broad claim of security certification is made.

## Test quality and next verification priorities

`Tests/CLITests/MeetingCLIProcessTests.swift` is meaningful integration coverage: it crosses fresh CLI processes, production migrations/repositories, durable notes, generated artifacts, Markdown export and a missing-ID error. Its fake audio is expressly a path fixture; it does not prove STT, microphone, permission or real GUI behavior.

Many command tests exercise parsers and injected command bodies. Those are valuable for schema/error contracts, but a helper that recopies old metadata can pass isolated helper tests while damaging the end-to-end flow. The new regressions therefore keep Core/SQLite real and place edits at the awaited recognition boundary. A second interleaving deletes the completed row during artifact materialization before the CLI resumes; this specifically detects a redundant save after Core commit.

Recommended order:

1. Preserve the new mutation regressions and existing cross-process notes/export lane.
2. Add bounded-helper-output tests before changing subprocess capture.
3. Add a schema-upgrade plus synthetic-library restore drill, including correction history, notes and missing-media behavior.
4. Add large-library query benchmarks with stable fixtures and explicit resource budgets.
5. Keep packaged CLI qualification separate from unit-test success and from native GUI/microphone/model qualification.

## Audit change verification

Verification is coordinated by the root audit so builds/tests run in the owning worktree without competing SwiftPM writers. The initial fixture failed to honor the pinned STT engine; that setup failure was corrected and is not counted as a product regression.

The corrected baseline run, recorded in `.build/audit-evidence/cli-red-gui-green.log`, ran four persistence tests: three failed with 45 assertion failures, and the deletion-during-recognition control passed. Nineteen command tests recorded eight assertion failures in the new nonfailed-dictation deletion/status cases. These failures reproduce stale metadata restoration, explicit-clear rollback, post-commit resurrection and unsafe dictation completion. The production fix removes redundant transcription saves and uses the existing atomic dictation status guard. Two obsolete helper tests that asserted stale copying were removed in favor of the persistence-boundary regressions. The green run at `.build/audit-evidence/fixes-focused-green.log` passed all 17 command tests and all four persistence tests (21 CLI tests, zero failures). The same coordinated run passed one independent onboarding render test, for 22 total. The consolidated report records the final full-suite, CI and PR status.

Invariants for the selected fixes: preserve saved identity and original source metadata; return the shared service's completed row; preserve edits/clears merged at completion; never recreate a deleted recording; preserve dictation lifetime statistics and failed-take audio-retention behavior; keep JSON keys and exit-code meanings stable. Actual-model quality, GUI concurrency driven through Accessibility, provider behavior, and release packaging are separate verification lanes.
