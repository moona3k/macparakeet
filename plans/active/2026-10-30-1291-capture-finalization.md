# Back-to-back meeting capture (#1291)

> Current status (2026-10-31): capture settlement and saved-meeting recovery
> are integrated through #1295 (`f0ef01df0`) and #1301 (`3b2b04bbc`), both
> ancestors of reviewed `79cf1ca92`. The dated checklist and CI narrative below
> are historical implementation evidence, not a fresh test of this later head.
> Physical capture/recovery qualification remains separate.

## Context and invariants

Stop currently awaits playback mixing before queue admission. Release capture only after callbacks/writers settle and source metadata/notes/lock are durable. Queue owns derived playback and final transcription. A must never clear B's capture, notes, selected engine, lease, or UI. Preserve source audio and retry/recovery ownership on failure, canonical row identity, source alignment/fallback, and completed playback duration.

Out of scope: activity detection, a pending-start queue, new capture engines, new generic schedulers, changes to STT priority, or releasing. The user subsequently authorized merging after final review and verification.

## Work

- [x] Split saved capture from prepared playback; reuse the existing builder and queue.
- [x] Cover admission, source-only Retry/recovery, and pending audio presentation.
- [x] Add behavioral regression tests and update contracts.
- [x] Review committed diff independently; address substantive findings. Greptile unavailable (not signed in).
- [x] Open [PR #1295](https://github.com/moona3k/macparakeet/pull/1295).
- [ ] Assess final GitHub compilation/test results before declaring merge readiness.

Validation: initial local disk pressure constrained fresh dependency builds. GitHub CI compiles/tests the complete change. Local parsing/format and focused checks that do not require a new build are permitted. Native long-meeting/device testing remains a separate qualification gate.

Initial base: a388b7d449c722875f24e26df35acecf881dd35e. Unrelated work in the original dirty checkout is preserved. no-mistakes is not on PATH; use the documented review workflow.

## Implemented shape

`MeetingRecordingCapture` holds saved sources/lock/metadata. `MeetingFinalizationInput`
distinguishes that capture from ready `MeetingRecordingOutput`. The additive
`stopForFinalization` interface returns capture early in production and preserves
ready-output adapters. The queue prepares playback before final STT, with the
existing per-folder ownership lease. Completed output duration stays measured.

Tests cover actual B source writes during blocked A playback, fallback and
cancellation, flow presentation after success/failure, queue FIFO/failure
isolation, missing-playback Retry, source-only crash recovery row reuse, lock
relinquishment, pending-audio eligibility, and CLI optional-duration output.
Existing settlement/writer-failure coverage remains intact. Compilation and
behavioral results are pending GitHub CI; local Swift syntax parsing and format
checks passed. No native audio qualification is claimed.

## Fresh-review findings addressed

- Defer cleaned-microphone writer creation until playback and final metadata
  succeed under queue ownership; stop snapshots only its configuration.
- A decodable artifact is insufficient preparation evidence: a row with unknown
  duration retries preparation even if a previous attempt installed playback.
- Reconcile missing/corrupt/truncated source media before building the output
  alignment and capture report, so STT does not retry vanished sources.
- Update the failed processing row while holding the folder ownership mutex,
  before publishing an unowned lock to recovery. Never demote a completed row.

The first hosted run was cancelled before compilation by the scheduled macOS 14
runner brownout. CI now uses macOS 15 with the same pinned Xcode 16.1 and all
existing lanes. GitHub documents both the [retirement](https://github.com/actions/runner-images/issues/13518)
and [installed Xcode versions](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).
Local Greptile was attempted but refused because it is not signed in; independent
agent reviews supplement GitHub review feedback.

The final review also caught a persisted-Retry gap: reloaded captures now rebuild
the existing cleaned-microphone preparation configuration instead of losing the
in-memory callback. The failure test reloads from disk and verifies a playable
cleaned source. Live and reloaded captures share the same scheduling function.

At the user's suggestion, p-stack's Separate Before Serializing Shared State,
Minimize Reader Load, and Prove It Works principles were applied to the final
review. They support separate per-session artifact ownership and the existing
queue. No broader scheduler or capture redesign is needed for this defect.

Boundary review aligned both Library and Meetings context-menu Retry actions
with the card's shared source-audio eligibility. Completed meetings with missing
playback retain the existing missing-audio state; they do not promise pending
preparation. CLI tests and documentation explicitly cover both canonical path
fields being present before playback exists.

## Final review before merge

Fresh review found that successful playback followed by failed entitlement
preflight could leave an unconsumed cleaned-mic renderer alive. Source-only
Retry would then start another renderer using the same session candidate path.
Cleaned readiness now starts its writer only when final STT consumes it after
preflight and row persistence. A small private actor shares one resolution across
handle copies, preserving cancellation and preventing duplicate publication.
Regression coverage checks early failure, deferred starts, and repeated resolution.

Opus 5.5 independently reviewed e525fc507 via `claude -p` and confirmed that
playback no longer blocks new capture. It identified the same cleanup overlap
and a lost meeting-type selection during asynchronous startup. Startup now
writes the current selection after capture starts, and a focused flow regression
pins that ordering. The duplicate CLI Unreleased heading is consolidated.

Opus's delta review also traced the same early-render overlap through recovery
of a source-only row. Recovery now uses the shared deferred readiness handle.
Its regression preserves canonical and candidate artifacts across rejected
preflight, then verifies one successful renderer on recovery retry. This keeps
the same ownership rule across Stop, Retry, and recovery without a new scheduler.

CodeRabbit's final pass tightened source-presence checks to reject directories,
hid pending-playback copy for failed/cancelled rows, aligned the earlier pipeline
diagram, and extended Artifact/Export coverage. Its proposed live `createdAt`
change was declined: the merge base also timestamps live rows at settlement;
changing chronology and retention fallback is separate from this fix.

Hosted CI on `b7f55890c` completed 8,235 XCTest cases and 30 Swift Testing cases.
Seven XCTest fixtures failed: the new lock assertion compared an in-memory Date
with its encoded round trip, four existing layout assertions hit macOS 15's
screen-fitting behavior, and two voice-control tests exhausted fixed yield loops
before the required event (one also failed on the merge base). The fixtures now
compare persisted bytes, preserve requested offscreen window geometry, and await
actual STT/transcript events. Original behavioral assertions remain. Release,
bundle, process-recovery, and Swift 6 checks passed; final-head CI is still required.

PR #1294 subsequently landed the runner and shared fixture corrections on
`main`, with green CI. The merge adopts those fixture files unchanged, removing
their duplicate changes and the CI-runner migration from this PR's final diff.
The meeting-specific persisted-lock assertion remains here.

CI run 41133395750 on `bd0d0082d` passed all 8,236 XCTest cases and 30 Swift
Testing cases, Swift 6, CLI qualification/persistence, meeting process recovery,
and release/bundle checks. While it ran, PRs #1296 and #1297 advanced main.
Integration retains both changelog and telemetry additions; meeting production
code and tests are unchanged. Independent review confirmed that processing rows
remain excluded from upstream knowledge-card generation. The integrated head
requires its own CI result before merge.

CodeRabbit's mixed legacy/current raw-filename salvage suggestion was declined:
the existing contract falls back only when the current name is absent, and no
normal capture/import/split/recovery path creates both raw-name generations.
Changing only eligibility and recovery would diverge from other artifact readers.
All review threads have documented dispositions. The implementation walkthrough
is published at <https://macparakeet.com/dev/pr/1295/>.
