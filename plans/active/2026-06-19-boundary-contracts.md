# Plan: Establish Boundary Contract Docs + Contract Tests

> **Executor instructions**: Keep this as a contract hardening slice, not a
> broad documentation rewrite. Build the first `spec/contracts/` set, add the
> matching tests, and update only the docs that must point to the new canonical
> contracts. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 225c61dfc..HEAD -- spec Sources/CLI Sources/MacParakeetCore/Services/MeetingRecording Tests/CLITests Tests/MacParakeetTests/Services/MeetingRecording docs/cli-testing.md docs/telemetry.md plans/active/2026-06-18-meeting-audio-retention-ndays.md`
> If any of those paths changed since this plan was written, compare the
> "Current state" notes below against the live files before editing. If a
> matching contract framework already exists, update it instead of creating a
> parallel one.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: architecture / dx / trust
- **Planned at**: commit `225c61dfc`, 2026-06-19

## Why this matters

MacParakeet already has several public or semi-public boundaries: meeting
artifact folders, recovery lock files, CLI JSON output, telemetry event names,
and runtime settings. Today those contracts are split across code comments,
ADRs, changelog entries, active plans, and tests. That works while one person
has all the context loaded, but it is fragile for agents, reviewers, and future
features like retention sweeps or cross-meeting automation.

The useful lesson from StenoAI is not its Electron/Python subprocess stack. It
is the habit of keeping explicit boundary contracts close to the code and
requiring matching tests when a PR changes them. This plan adds that habit in a
MacParakeet-shaped way: narrow `spec/contracts/*.md` documents, each tied to
specific XCTest coverage. The first slice covers the highest-trust surfaces:
meeting artifacts, recovery/retention safety, and CLI JSON/spec output.

## Current state

- `spec/contracts/` does not exist.
- `spec/01-data-model.md:154` already says meeting session folders are the
  first-class local artifact contract and names `manifest.json`,
  `transcript.json`, `notes.md`, `prompt-results.json`, and
  `prompt-results/`.
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingArtifactStore.swift:25-37`
  defines `MeetingArtifactSnapshot`; `:68-74` defines schema/file constants;
  `:82-146` materializes files; `:157-190` writes prompt-result JSON and
  Markdown.
- `Tests/MacParakeetTests/Services/MeetingRecording/MeetingArtifactStoreTests.swift:24-68`
  asserts the main artifact files and selected manifest/transcript fields;
  `:70-103` asserts stale notes and prompt-result files are removed.
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingLockFileStore.swift:4-7`
  models `recording` and `awaitingTranscription`; `:183-208` reads any valid
  lock in a folder; `:218-234` splits orphan vs active sessions by PID liveness.
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift:83-107`
  discovers dead-PID recoveries; `:125-214` recovers audio; `:306-317` cleans an
  `awaitingTranscription` lock when a completed transcript already exists.
- `plans/active/2026-06-18-meeting-audio-retention-ndays.md:75-86` already
  states the key retention safety rule: skip any `recording.lock` in any state,
  live or dead PID.
- `Sources/CLI/CHANGELOG.md:35-85` documents exit codes and the `--json`
  failure envelope; `:142-166` documents meeting artifact and meeting audio CLI
  additions; `:331-332` says `spec --json` prints the machine-readable CLI
  contract.
- `Sources/CLI/Commands/SpecCommand.swift:31-64` defines `CLISpec.current`;
  `:45-60` names JSON conventions, failure envelope fields, and exit codes.
- `Sources/CLI/Commands/CLIHelpers.swift:221-235` owns JSON encoding; `:244-260`
  defines `CLIErrorEnvelope`; `:441-490` maps JSON-mode errors to public exit
  codes and stdout envelopes.
- `docs/cli-testing.md:119-124` documents JSON/stdout and `--envelope`
  conventions for humans.
- `docs/telemetry.md:637-648` states the app enum plus website allowlist sync
  rule; `:840-844` points to the telemetry allowlist guard plan.

## Scope

### In scope

- Create `spec/contracts/` as the canonical home for boundary contracts.
- Add `spec/contracts/README.md` describing the contract-doc format and the
  rule that PRs changing a boundary must update the contract doc and tests.
- Add the first three contract docs:
  - `spec/contracts/meeting-artifacts-v1.md`
  - `spec/contracts/meeting-recovery-retention.md`
  - `spec/contracts/cli-json-v1.md`
- Add or tighten tests that enforce the contract claims already made in code.
- Add lightweight pointers from existing docs so readers land on the canonical
  contract instead of duplicating schema prose.
- Update `plans/README.md` when this plan ships.

### Out of scope

- Implement meeting audio retention, back-to-back recording, or new meeting
  workspace UX. This plan only creates contract scaffolding those features can
  rely on.
- Redesign CLI output or break existing JSON shapes. Contract docs capture
  current behavior; additive shape changes still require normal changelog/spec
  updates.
- Add a generic JSON schema generation system. Start with human-readable
  contracts plus focused semantic tests.
- Move all telemetry and settings docs into `spec/contracts/` in this slice.
  Telemetry/settings are listed as follow-ups unless a touched file forces a
  pointer update.
- Add snapshot tests that require byte-for-byte JSON stability for fields that
  are intentionally non-stable, such as generated timestamps.

### Invariants

- Contract docs are repo-relative and test-linked. Every contract must name the
  files/tests that enforce it.
- The DB row stays canonical for meetings. The session folder is the durable
  local artifact surface, not the source of truth for all meeting metadata.
- Recovery input is protected. Any `recording.lock` means "do not sweep this
  folder automatically" until recovery or explicit user action resolves it.
- CLI stdout remains machine-readable in JSON mode. Human progress/status stays
  on stderr.
- Contract docs describe stable and non-stable fields separately so additive
  evolution remains possible.

## Requirements

### Contract framework

- R1. `spec/contracts/README.md` defines the contract-doc format, naming
  convention, and required test linkage.
- R2. Each contract doc names stable fields, non-stable fields, versioning
  rules, compatibility rules, and verification tests.
- R3. Existing docs that currently carry boundary-contract prose point to the
  new contract docs instead of drifting with copy-pasted schema details.

### Meeting artifacts

- R4. The meeting artifact contract documents the v1 session folder layout,
  `MeetingArtifactSnapshot`, manifest/transcript/notes/prompt-result files, and
  the rule that the DB row remains canonical.
- R5. Tests assert the stable artifact filenames, schema string/version,
  manifest file references, transcript essentials, note deletion behavior, and
  prompt-result file refresh behavior.
- R6. The contract states which values may change on every materialization
  (`generatedAt`, ordering tied to prompt result input, absolute folder paths)
  so tests do not freeze incidental details.

### Recovery and retention safety

- R7. The recovery/retention contract documents `recording.lock` fields,
  `recording` vs `awaitingTranscription`, PID-liveness semantics, and the
  difference between recovery orphan discovery and retention sweep safety.
- R8. The contract requires retention-like code to skip any valid
  `recording.lock` in any state, regardless of PID liveness.
- R9. Tests assert `MeetingRecordingLockFileStore.read(folderURL:)` returns
  dead-PID `awaitingTranscription` locks and that `discoverActiveSessions` is
  not the generic "safe to mutate" predicate.
- R10. Existing recovery tests continue to prove completed
  `awaitingTranscription` sessions clean their lock without deleting completed
  audio.

### CLI JSON / spec output

- R11. The CLI contract documents the stable `--json` error envelope, exit
  codes, stdout/stderr split, `--json` vs `--envelope`, and the role of
  `macparakeet-cli spec --json` as the machine-readable catalog.
- R12. Tests assert `CLISpec` still exposes JSON conventions, failure-envelope
  fields, exit codes, and the agent-facing meeting commands.
- R13. Tests assert mutually exclusive `--json`/`--envelope` flags stay
  validation failures and that JSON-mode runtime failures emit the public
  envelope shape.

### Contributor workflow

- R14. `AGENTS.md` and `spec/README.md` gain short pointers: if a PR changes
  one of these boundaries, update the matching `spec/contracts/*.md` and tests
  in the same change.
- R15. `plans/README.md` marks this plan `VERIFY-THEN-ARCHIVE` after the
  contract docs and tests land.

## Key technical decisions

- **Start with three contracts, not every boundary.** Meeting artifacts,
  recovery/retention, and CLI JSON are the surfaces most likely to be consumed
  by agents, automation, and future destructive workflows. Telemetry and
  settings remain follow-ups so this first slice proves the pattern.
- **Use Markdown contracts plus semantic tests.** The repo already has Swift
  models and XCTest coverage. Hand-authored Markdown is reviewable; semantic
  tests prevent the docs from becoming unchecked prose.
- **Keep `spec --json` as the CLI machine contract.** Do not create a second
  JSON catalog in docs. `spec/contracts/cli-json-v1.md` explains the public
  rules and points to `SpecCommand` as the generated/encoded surface.
- **Treat any lock as retention-protected.** PID liveness is useful for
  recovery discovery and active-session CLI refusal, but destructive automatic
  sweeps must skip valid lock files even when the owner PID is dead.
- **Document non-stable values.** Contract tests should avoid freezing
  generated timestamps, absolute user paths, or incidental pretty-printing
  beyond the existing CLI encoder conventions.

## Implementation units

### U1. Contract directory and framework

- **Goal:** Create the canonical home and contribution rule.
- **Files:**
  - `spec/contracts/README.md`
  - `spec/README.md`
  - `AGENTS.md`
- **Details:**
  - Define a compact contract-doc skeleton: purpose, producers, consumers,
    stable fields, non-stable fields, versioning, compatibility, tests.
  - Add a pointer in `spec/README.md` so the contracts are discoverable from
    the main spec index.
  - Add a short `AGENTS.md` rule under Architecture Orientation or Where to
    Look Next: contract boundary changes require doc and test updates.
- **Tests:** None directly; this unit is documentation structure.
- **Verification:** `rg -n "spec/contracts|contract" AGENTS.md spec/README.md spec/contracts/README.md`.

### U2. Meeting artifact v1 contract

- **Goal:** Make the meeting session folder contract explicit and test-linked.
- **Files:**
  - `spec/contracts/meeting-artifacts-v1.md`
  - `spec/01-data-model.md`
  - `Sources/CLI/CHANGELOG.md`
  - `Tests/MacParakeetTests/Services/MeetingRecording/MeetingArtifactStoreTests.swift`
  - `Tests/CLITests/MeetingsCommandTests.swift`
- **Details:**
  - Document producers: `MeetingArtifactStore`, meeting finalization,
    `macparakeet-cli meetings artifact`, meeting notes writes, prompt-result
    writes.
  - Document consumers: Finder/show-in-folder UI, CLI, hooks, future agents,
    support diagnostics.
  - Pin the stable folder entries: `meeting.m4a`, optional source audio files,
    `meeting-recording-metadata.json`, `manifest.json`, `transcript.json`,
    optional `notes.md`, `prompt-results.json`, and `prompt-results/*.md`.
  - State that `prompt-results/` is refreshed from the supplied prompt results,
    so stale result Markdown is removed when the input set changes.
  - Keep the current data-model note because it orients readers in place, but
    add a "canonical contract: ..." pointer so future schema detail lives in
    `spec/contracts/meeting-artifacts-v1.md`.
- **Test scenarios:**
  - Existing materialization test still asserts stable filenames and selected
    JSON fields.
  - Add assertions for `schemaVersion`, `promptResultsPath`,
    `promptResultsDirectoryPath`, and the per-result Markdown filename/index.
  - Add a negative test that non-meeting rows cannot materialize artifacts
    unless it is already covered sufficiently by the current test.
  - In `MeetingsCommandTests`, keep `meetings artifact --envelope` coverage and
    assert the returned `data` includes `schema`, `schemaVersion`, and the
    expected path fields.
- **Verification:** `swift test --filter MeetingArtifactStoreTests && swift test --filter MeetingsCommandTests`.

### U3. Meeting recovery and retention safety contract

- **Goal:** Make the lock/recovery semantics impossible to misread when adding
  retention or back-to-back meeting behavior.
- **Files:**
  - `spec/contracts/meeting-recovery-retention.md`
  - `spec/adr/019-crash-resilient-meeting-recording.md`
  - `spec/05-audio-pipeline.md`
  - `plans/active/2026-06-18-meeting-audio-retention-ndays.md`
  - `Tests/MacParakeetTests/Services/MeetingRecording/MeetingRecordingLockFileStoreTests.swift`
  - `Tests/MacParakeetTests/Services/MeetingRecording/MeetingRecordingRecoveryServiceTests.swift`
- **Details:**
  - Document lock fields and current schema-version rule.
  - State the three predicates separately:
    - recovery orphan discovery: valid lock plus dead owner PID
    - active-session CLI refusal: valid lock plus live owner PID
    - automatic destructive safety: any valid lock, live or dead PID
  - State that `awaitingTranscription` means finalized audio waiting for
    transcription/recovery and is not safe for retention sweep deletion.
  - Add a pointer from ADR-019 or the audio-pipeline spec to the contract
    instead of duplicating every edge case there.
- **Test scenarios:**
  - Add `MeetingRecordingLockFileStoreTests` coverage that a dead-PID
    `awaitingTranscription` lock is still returned by `read(folderURL:)`.
  - Add a test name/comment making clear `discoverActiveSessions` is PID-live
    only and must not be reused as a retention safety predicate.
  - Keep or tighten the existing recovery tests that completed
    `awaitingTranscription` sessions delete the lock but keep the completed
    meeting folder/audio.
  - If the retention plan lands before this plan executes, add the retention
    policy test here: a completed row with a dead-PID `awaitingTranscription`
    lock is skipped by the sweep.
- **Verification:** `swift test --filter MeetingRecordingLockFileStoreTests && swift test --filter MeetingRecordingRecoveryServiceTests`.

### U4. CLI JSON and `spec --json` contract

- **Goal:** Make CLI automation guarantees explicit and tested in one place.
- **Files:**
  - `spec/contracts/cli-json-v1.md`
  - `docs/cli-testing.md`
  - `Sources/CLI/CHANGELOG.md`
  - `Sources/CLI/Commands/SpecCommand.swift` if the spec text needs additive
    contract wording
  - `Tests/CLITests/SpecCommandTests.swift`
  - `Tests/CLITests/LLMJSONOutputTests.swift`
  - `Tests/CLITests/MeetingsCommandTests.swift`
- **Details:**
  - Document stdout/stderr rules, ISO-8601/sorted/pretty JSON encoder, exit
    codes, post-parse failure envelope, parse-time failure exception, and
    `--json`/`--envelope` exclusivity.
  - State that `macparakeet-cli spec --json` is the machine-readable catalog
    for agent-facing commands, while `Sources/CLI/CHANGELOG.md` remains the
    release-facing history.
  - Add pointers from `docs/cli-testing.md` and the changelog contract section
    to `spec/contracts/cli-json-v1.md`.
- **Test scenarios:**
  - `SpecCommandTests` asserts `conventions.failureEnvelope.fields` contains
    `ok`, `error`, `errorType`, `fix`, and `meta`.
  - `SpecCommandTests` asserts exit code entries for `0`, `1`, `2`, and `130`.
  - `LLMJSONOutputTests` keeps the `CLIErrorEnvelope` shape and exit-code
    normalization coverage.
  - `MeetingsCommandTests` keeps `--json`/`--envelope` mutual exclusion coverage
    for all meeting subcommands with both modes.
- **Verification:** `swift test --filter SpecCommandTests && swift test --filter LLMJSONOutputTests && swift test --filter MeetingsCommandTests`.

### U5. Final contract wiring and status update

- **Goal:** Make the new contract layer discoverable and close the plan loop.
- **Files:**
  - `plans/README.md`
  - `spec/contracts/README.md`
  - any contract doc touched above
- **Details:**
  - Ensure every contract doc has a "Tests that enforce this" section with
    exact test class names.
  - Ensure every contract doc has a "When this changes" section telling future
    PRs what else to update.
  - Mark this plan `VERIFY-THEN-ARCHIVE` in `plans/README.md` after docs/tests
    land and focused checks pass.
- **Verification:** `rg -n "Tests that enforce this|When this changes" spec/contracts/*.md`.

## Acceptance examples

- **AE1. Artifact field drift:** A future PR renames `prompt-results.json` or
  drops `schemaVersion`. The meeting artifact tests fail, and the reviewer sees
  that `spec/contracts/meeting-artifacts-v1.md` must be updated or the change
  reverted.
- **AE2. Retention safety drift:** A future retention sweep tries to use
  `discoverActiveSessions(...)` as its only in-flight guard. The contract says
  that is PID-live only, and the lock-store tests demonstrate why dead-PID
  `awaitingTranscription` locks still matter.
- **AE3. CLI automation drift:** A future command writes human progress to
  stdout in JSON mode or changes the failure-envelope fields. CLI tests fail,
  and `spec/contracts/cli-json-v1.md` points to the public compatibility rule.
- **AE4. Additive evolution:** A future meeting artifact adds
  `speakers.json`. The implementer adds it as an additive v1-compatible field
  in the contract, updates tests, and notes any CLI/changelog impact without
  breaking existing consumers.

## Verification plan

Focused checks after implementation:

```bash
swift test --filter MeetingArtifactStoreTests
swift test --filter MeetingRecordingLockFileStoreTests
swift test --filter MeetingRecordingRecoveryServiceTests
swift test --filter SpecCommandTests
swift test --filter LLMJSONOutputTests
swift test --filter MeetingsCommandTests
```

Final merge-readiness check:

```bash
swift test
```

For a docs-only subset while iterating, also run:

```bash
git diff --check
rg -n "spec/contracts" AGENTS.md spec/README.md docs/cli-testing.md Sources/CLI/CHANGELOG.md
```

## STOP conditions

- `spec/contracts/` already exists by the time execution starts. Update the
  existing framework instead of creating a second one.
- The retention implementation lands first. Fold U3's safety contract and tests
  into the live retention files rather than leaving a parallel future note.
- A CLI v2 / breaking JSON change is in flight. Rebase this plan around that
  branch so the contract captures the intended next public surface, not stale
  v1 behavior.
- Contract docs start duplicating whole ADRs or changelog sections. Replace
  duplicate prose with pointers; contracts should define boundaries, not become
  a second spec tree.

## Follow-up candidates

- `spec/contracts/telemetry-events-v1.md`: app enum, website allowlist, payload
  privacy categories, and the two-repo change rule. Coordinate with
  `plans/active/2026-06-12-telemetry-allowlist-ci-guard.md`.
- `spec/contracts/settings-preferences-v1.md`: UserDefaults keys, defaults,
  migration rules, notification names, and CLI config parity.
- Full-app meeting workflow smoke tests inspired by StenoAI's T2 suite. This is
  related but larger than boundary contracts.
