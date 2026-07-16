# MacParakeet v0.7.3 Release-Readiness Audit

> Date: 2026-07-16
>
> Baseline: `origin/main` at `6599603c0f775d32009422a7ddad6385a8a932df`
>
> Fixed point: public release `v0.7.2` at `afc2eff9`
>
> Candidate version: `0.7.3`

Canonical consolidated record:
[`2026-07-16-v0.7.3-comprehensive-codebase-release-architecture-audit.md`](./2026-07-16-v0.7.3-comprehensive-codebase-release-architecture-audit.md).

The app stays on the v0.7 release train by maintainer decision. The changes are
primarily reliability and workflow repairs; the bundled CLI's independent 3.0
contract version does not require a new minor app version.

## Verdict

The post-v0.7.2 code is a credible `0.7.3` release candidate. The reviewed
implementation has no known code-level release blocker after the dependency,
release-tooling, and canonical-documentation fixes in this audit branch.

This is **code ready**, not yet **ship complete**. A signed/notarized candidate
still needs the physical audio-route and long-meeting matrix in this document
before publishing the DMG, appcast, GitHub release, and Homebrew asset.

## Scope

The audit used a clean worktree from fetched `origin/main`; the user's dirty
archive checkout was not changed. Review covered:

- Every first-parent change from `v0.7.2` through merged PR #822 (143 changed
  files, 9,972 insertions and 1,416 deletions).
- Capture ownership and teardown, microphone routing, meeting recovery and
  finalization, speech-engine routing and leases, database migrations and
  repositories, auto-save, filename persistence, CLI contracts, telemetry,
  diagnostic logging, privacy, entitlements, update trust, and distribution.
- The repository's 462 source Swift files, 289 test Swift files, 28 ADRs, four
  boundary contracts, subsystem READMEs, current specs, release documentation,
  plans, scripts, package constraints, and live GitHub issue/release/CI state.
- Targeted static checks for unsafe casts, forced operations, crash paths,
  credentials, logging of user content, database migration ordering, stale
  release claims, README references, and diff hygiene.

## Release findings fixed

### 1. FluidAudio could resolve to a known breaking patch

`Package.swift` allowed `0.15.4..<0.16.0`, while FluidAudio 0.15.5 removes the
`DownloadUtils` API still used throughout MacParakeet. The lockfile currently
masked the risk. The dependency is now exact-pinned to 0.15.4 until a deliberate
`ModelHub` migration is implemented and tested.

### 2. Xcode package resolution could not run `git submodule`

On the release machine, Xcode 26.4.1's bundled Apple Git omitted the
`git-submodule` helper even though Homebrew Git had it. This caused strict
release builds to fail with the opaque package-resolution error "Couldn't
update repository submodules." The bundle script now detects that mismatch,
exports the shell Git helper directory for xcodebuild, verifies the repair, and
otherwise fails with an actionable explanation. The distribution preflight and
troubleshooting table document the behavior.

### 3. Canonical release truth lagged the shipped product

The README/spec still called `0.6.24` stable and described Cohere, cleaned-mic
finalization, activity-based meeting auto-stop, live dictation preview, and VAD
meeting chunking as untagged work. The canonical surfaces now identify `0.7.2`
as stable, record the shipped v0.7 behavior and default-off controls, and define
the post-v0.7.2 reliability train as the `0.7.3` release candidate. The three most
recent merged implementation plans are marked for archival rather than open.

## Recent-change review

No new correctness, privacy, persistence, concurrency, or CLI-contract defect
was found in PRs #775, #783, #785, #795, #801, #802, or #810-#822.

The highest-risk paths have explicit ownership and bounded state transitions:

- ScreenCaptureKit startup hands partial ownership to Stop immediately; late
  completion cannot revive or delete a stopped meeting.
- Audio callbacks target immutable capture state and are drained before that
  state is released.
- Live and final STT routes are snapshotted, leased, and attributed explicitly;
  final-model loading remains lazy.
- Auto-save bookmark updates retain race guards and failures are surfaced.
- Filename persistence continues to use parameterized GRDB updates.

## Live issue interpretation

| Issue cluster | Candidate interpretation | Release action |
|---|---|---|
| #796, #803, #820: Bluetooth/System Default input failures | #796 is consistent with the forced built-in-mic routing removed by PR #801. #803 is likely routing-related, but its evidence is incomplete; #820 does not yet isolate a route. PR #801 restores implicit System Default routing. | Must verify on physical Bluetooth hardware in the signed candidate. |
| #798: Instant Dictation fails after idle/repeat | PR #785 adds cold-start prewarming and lifecycle coverage. | Run idle, repeat, toggle, route-change, and sleep/wake matrix. |
| #808: stuck recording / meeting stop | PRs #810 and #814 address the stack overflow and unbounded capture lifecycle. | Run a meeting longer than the reporter's failure window, then stop/finalize. |
| #605: speaker bleed / no-headphones meeting capture | AEC assets and cleaned-mic finalization ship and pass artifact gates. | Run real Zoom/Meet/Teams calls without headphones; inspect raw and cleaned artifacts. |
| #562: weak very-short utterances | The reporter showed a distinct Parakeet v3 empty/dropped-phrase problem while v2/Unified worked, plus a short-utterance threshold complaint across other models. | Keep both concerns visible; document the v2/Unified workaround and do not overclaim closure. |
| #470: multichannel input | Current code downmixes all channels, tries the selected route first, and has regression tests. | No candidate code change; physically verify a multichannel USB interface before closing. |

## Verification evidence

- Exact-main hosted CI run `29532380793`: green, including release build, CLI
  smoke, bundle smoke, Swift 6 first-party build with WhisperKit excluded from
  that language-mode check, concurrency-warning scan, and the full parallel
  Swift suite.
- Focused high-risk matrix: 1,220 tests, zero failures. It covered microphone
  routing/prewarm, capture lifecycle, meeting service/recovery/finalization,
  STT routes/scheduler/leases, auto-save, CLI config/search, settings, and text
  processing.
- Strict unsigned `0.7.3` xcodebuild bundle at the pre-#822 baseline: passed
  with required meeting echo
  assets, pinned LocalVQE runtime/model checksum, static FFmpeg, yt-dlp, Node,
  Sparkle trust anchor, legal notices, and matching dSYM.
  PR #822 only changes Settings presentation/search/spec surfaces; rebuild the
  signed candidate from the final audited SHA.
- Self-healing release-script replay: passed from a shell with
  `GIT_EXEC_PATH` unset. The script detected Xcode's missing `git-submodule`
  helper, selected Homebrew Git's helper directory, and completed the strict
  bundle without manual environment repair.
- `git diff --check`: clean.
- Subsystem README reference check: passed.
- The full suite was not repeated locally: exact-main hosted CI had already run
  it successfully, and the local focused matrix covered 1,220 high-risk tests.
  Bundled-CLI demo smoke remains part of the signed `/Applications` candidate
  matrix rather than this unsigned audit build.

### Current-toolchain caveat

The hosted Swift 6 gate is green on its pinned Xcode 16.1 toolchain, but a
separate strict-language build on the release machine's Xcode 26.4.1 / Swift
6.3.1 found three isolation errors in `SettingsViewModel` calls through the
non-`Sendable` `CommandLineToolInstalling` protocol. The actual strict Release
bundle passes in the package's Swift 5.9 language mode, so this is not a 0.7.3
release-configuration blocker. It is P1 toolchain debt: make the service
isolation contract explicit, update test doubles, and add a current-Xcode gate.

The exact-main hosted log contains 9,785 unique swift-format diagnostics after
full path/line/message deduplication (6,269 indentation, 2,011 add-lines, 825
line-length, 363 spacing, 228 trailing-comma, 67 remove-line, and 22
trailing-whitespace). Separately, 136 unique non-format compiler warnings are
predominantly concurrency or `Sendable` findings across production and tests.
The current concurrency step reports rather than fails on warnings. Treat both
sets as baselines to ratchet, not as a claim that the tree is warning-clean or
that each entry is a separate runtime bug.

## Physical signed-candidate matrix

Run from a notarized app copied to `/Applications`, not from the DMG volume:

1. **System Default + Bluetooth output:** verify real input buffers and correct
   transcription with system-default input, explicit built-in input, AirPods,
   and a USB microphone.
2. **Instant Dictation:** after five minutes idle, record five immediate cycles,
   turn Instant Dictation off/on, change routes during the session, and repeat
   after sleep/wake. Confirm no idle orange microphone indicator when disabled.
3. **Meeting lifecycle:** run beyond the #808 failure window, stop during normal
   capture and during startup, and confirm finalization, recovery artifacts,
   auto-save feedback, and no stuck recording state.
4. **No-headphones AEC:** run Zoom, Google Meet, and Teams samples; compare raw
   microphone, system audio, playback, cleaned microphone, and final transcript.
5. **Installed CLI:** run installer/permissions checks and the release demo smoke
   against `/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli`.

## Non-blocking follow-ups

These deserve separate, bounded work and should not expand the release patch:

- Reconcile and archive the older stale `VERIFY-THEN-ARCHIVE` plan-board rows.
- Add repository-wide local-link/ADR/contract documentation CI; docs-only
  changes currently bypass the main workflow.
- Replace the 9k+ informational formatting warnings with a changed-files or
  baseline-aware ratchet rather than formatting the whole tree at once.
- Deliberately migrate FluidAudio 0.15.5+ (`ModelHub`) and Argmax/WhisperKit 1.x,
  then remove the WhisperKit Swift 6 exception if the migration proves clean.
- Enable GitHub dependency alerts/security updates, secret scanning, validity
  checks, and push protection after deciding the repository policy.
- Stop committing raw diagnostic logs; use private attachments or explicitly
  redacted/synthetic fixtures. The currently reviewed recent logs did not expose
  transcript text, prompts, URLs, emails, paths, or credentials.
- Bound the podcast RSS episode array, make the meeting live chunker's
  single-consumer serialization invariant executable, and revisit scheduler
  quiesce/cache-clear mutual exclusion if cache clearing becomes an in-process
  GUI operation.

## Publish sequence after physical QA

Build from the exact approved SHA, sign/notarize/staple, run the installed-app
smoke, upload the one immutable DMG, generate the Sparkle signature from that
same file, update/deploy the appcast, attach the same DMG to the `v0.7.3` GitHub
release for Homebrew, and verify remote size/signature/version consistency.
