# Release-readiness review — 2026-09-04

## Verdict and scope

**PR review record; not a published-release approval.** This record
distinguishes code presence, executable verification, merged-main state, and
published-release state. [PR #953](https://github.com/moona3k/macparakeet/pull/953)
holds the subsequent source/CI/merge identities; historical local checks below
remain recorded with their actual outcomes.

- Reviewed main baseline: `9e849baf72b8f6939b618f584c3ca8c285ef497c`.
- Starting candidate: `b884c948`, branch `codex/release-readiness-20260904`.
- Execution checkout: `/Users/dmoon/orca/workspaces/macparakeet/release-readiness-20260904`.
- Scope: reliability, existing bugs, public CLI/agent contracts, and alignment of
  documentation/specifications/ADRs. No additive product roadmap or new capture
  architecture. Preserve user recordings and the normal database.
- Maintainer decisions: leave Discover unchanged; focus on the codebase and do
  **not** spend further effort on launching or visually checking the UI.
- No application release, DMG, Sparkle/appcast distribution, or
  hardware-certification claim is part of this review.

## Findings and disposition

“Implemented” means present in the reviewed development source. Executable
results are recorded below; inspection alone is not a reproduction claim.

| Finding | Evidence | Disposition |
|---|---|---|
| Recovery loses persisted silent-track status | `MeetingRecordingRecoveryService.reconciledCaptureReport` reconstructed a report without its silent sources. | Implemented and regression-verified: preserve silent sources while retaining failed/interrupted/unavailable precedence. |
| Silence verdict does not match retained stereo audio | Stop-time verdict used input channel-zero RMS rather than PCM successfully appended by `MeetingAudioStorageWriter`. Converter defaults also selected channel zero. | Implemented and regression-verified: measure retained PCM, including pre-pause audio; preserve ordinary averaging while retaining one whole dominant-energy channel under destructive cancellation. Right-only and inverse stereo retain signal. Live metering unchanged. |
| OpenCode Go requires conversation identity | [Issue #948](https://github.com/moona3k/macparakeet/issues/948), [provider documentation](https://opencode.ai/docs/go/). | Implemented and adapter/lifecycle-verified: opaque conversation UUID through existing chat APIs, scoped session header, isolated probes/one-shots, redirect protection. No live-provider validation claim. |
| Startup is presented as active recording before capture startup completes | `MeetingRecordingFlowCoordinator` presented recording before accepted startup. | Implemented and regression-verified: neutral `.starting` state across existing presentation models; preserve stop/cancel and stale-start guards. This does not fix an OS/hardware startup stall. |
| Meeting rename violates persistence and active library query | Synthetic success could follow a missing-row update; a separate fetch could fail after commit; unloaded rows could arrive from stale query snapshots. | Implemented and regression-verified: return the row from the write transaction, reject missing IDs before success/artifact work, and preserve the requested window when replacing in-flight meeting-capable loads. |
| Prompt preparation ownership survives transcript navigation | A view-local unscoped Boolean kept new-transcript actions disabled until stale work finished. | Implemented and regression-verified: existing rich-context loader owns request-scoped actions; stale completion cannot submit or clear a newer request. |
| Local CLI failures retain terminal control sequences | Actual CLI calls leaked escape finals, stderr controls and C1/control-string payloads; colored “command not found” was misclassified. | Implemented; real subprocess and CLI regressions pass. Sanitize stdout/stderr before classification; consume valid escape finals and bounded parser states for control strings. |
| Default CLI health probe repairs directories and opens a migrating database | Actual baseline CLI created an absent isolated state root; default database initialization migrates. | Implemented; focused tests and actual CLI confirm a non-creating probe. Read-only database open does not migrate/seed; use a repository count rather than loading transcripts. JSON/exit contract unchanged. |
| Integration and product docs drift from runtime | Duplicated command catalogs, incorrect JSON error guidance, stale release/default/flag statements, and unsafe database-reset instructions. | Reconciled canonical docs, subsystem contracts and integration entry points; local links/reference checks pass. Runtime `spec --json` remains authoritative. Discover behavior unchanged and explicitly documented. |
| Bounded writer finalization loses pending ownership | Zero-frame timeouts were absent from the report; consumers could read pending files or delete their folder while AVFoundation still owned them. | Implemented and regression-verified: carry pending source IDs, avoid all pending-source probes, preserve folders/locks on stop/cancel/failed-start/no-audio paths, and release ownership only on actual callbacks. |

### Reported artifact loss: evidence versus inference

[Issue #933](https://github.com/moona3k/macparakeet/issues/933) reports a roughly
20-minute meeting apparently replaced by a short recording. Its attached
`diagnostics/1787747923883-dictation-audio.log` contains:

- `2026-08-26T08:01:44.611Z`: microphone capture starting.
- `2026-08-26T08:22:55.309Z`: prepared engine start completed;
  `audio_engine_start_ms=1270682.209` (about 21 minutes).
- Capture ended around `08:23:47`, leaving roughly 52 seconds after startup.

This is evidence of severely delayed audio startup. It supports a short actual
capture despite a much longer apparent meeting duration; it **does not prove
file overwrite**, nor establish the cause of the blocked engine start. Correcting
startup presentation does not fix an operating-system/hardware startup stall.
Keep the issue open until source duration, session ownership, and the relevant
artifacts establish the reported failure mode.

[Issue #949](https://github.com/moona3k/macparakeet/issues/949) reports unprompted
dictation cancellation with an undo countdown. No triggering event sequence has
been established. Do not suppress Escape or infer that diagnostics constitute a
fix; preserve undo-window audio and require event-origin evidence.

## Complete open-issue reassessment

All **116 open issues** in the captured inventory were assigned exactly once and
reviewed with their full bodies and available comments (68 comments total).
Issue #952 arrived later and was separately assessed, bringing the ledger to
**117 issues**. Its supplied Core ML/ANE compiler wait chain is accepted as
evidence of a model-preparation stall. Whisper's progress watchdog only reports
progress; it cannot interrupt that synchronous load. The issue remains an open
release risk, not a fix delivered by onboarding error handling. Do not kill
system-wide compiler services or delete shared caches as automatic recovery.
The [structured issue ledger](2026-09-04-release-readiness-issues.json) preserves
each issue's title, severity, recommendation, evidence, uncertainty and next
step. These are review recommendations, not assertions that issues were closed.

Final source-evidence dispositions:

| Disposition | Count |
|---|---:|
| Product backlog | 64 |
| Code present on reviewed main | 4 |
| Needs additional evidence | 36 |
| Feedback-only closure recommendation | 3 |
| Duplicate recommendation | 3 |
| Code present only in candidate | 7 |
| Release-blocking correction | 0 |

The ledger is an assessment snapshot. Fixes made during this review are tracked
above and must be associated with final verification/PR evidence before issue
state is changed. Code presence is distinguished from a user-available or
field-verified feature: gated, partial, and hardware-dependent reports stay
open rather than being closed on source presence alone. Discover removal/opt-out
requests (#834, #891, #915) remain open, unchanged, by explicit maintainer
decision.

An initial pass conflated available features with gated source (#412),
complete fixes with partial workarounds or unverified hardware (#409, #432,
#481, #541, #604, #605, #947), candidate-only changes with reviewed main
(#888, #912), and actionable UX/ASR reports with praise-only feedback (#449,
#907); those rows were corrected to the conservative dispositions above, and
issue #948's ledger entry was corrected from a stale "zero hits, P0
release-blocker" evidence claim to `fixed-in-candidate`, matching this
document's own summary table (the header is implemented and
adapter/lifecycle-verified, without live-provider credential proof).

Separately, the following tracker actions were completed and confirmed against
live issue state: closed as praise-only feedback — #877, #886, #925; closed as
duplicate — #903→#460, #923→#900, #929→#527; closed as already-available —
#919; closed as reporter-confirmed — #942. All eight closures were verified
open-then-closed via the tracker API; no other issue state was changed by
these actions.

Local Greptile CLI review was unavailable for this pass (wrapper exited 127;
`npm exec` reported an expired session, so no local Greptile approval is
claimed for this candidate). The GitHub review bot and independent/no-mistakes
review remain the fallback coverage for this branch.

## Verification record

### Executed

The pre-correction candidate's release CLI reported **3.2.0** and completed:

1. `spec --json` command discovery.
2. `health --json`; detected a production database with a newer schema than this
   candidate understands. That database was left untouched.
3. `scripts/dev/release_demo_smoke.sh --cli <candidate-cli> --output-dir <temporary-dir>`:
   generated synthetic local speech, transcribed it into a test-owned SQLite
   database, and exported the persisted result as Markdown.
4. Search and transcript retrieval from that same isolated database: exit 0,
   parseable JSON.
5. Missing-record lookup: exit 1, JSON runtime failure envelope with `errorType`
   `lookup` on stdout.
6. Invalid arguments: exit 2; not misreported as a post-parse JSON failure.

These are baseline CLI observations, **not** validation of the later source
corrections. DEBUG state-root isolation covers app files/model caches, not shared
UserDefaults or Keychain. No configuration writes are required for this smoke.

### First focused correction run

The supported debug build completed in **435.17 seconds**. The focused command
below executed **501 XCTest cases, with 8 assertion failures across 7 cases**, in 131.16 seconds.
This is a failed intermediate gate, not release approval.

```bash
swift test --jobs 1 -Xswiftc -disable-batch-mode \
  --filter 'MeetingRecordingServiceTests|MeetingRecordingRecoveryServiceTests|LLMHTTPAdapterTests|LLMServiceTests|TranscriptChatViewModelTests|TranscriptionLibraryViewModelTests|MeetingRecordingFlowCoordinatorTests|MeetingRecordingPillViewModelTests|MeetingRecordingPanelViewModelTests|MeetingsWorkspaceViewModelTests|LocalCLIExecutorTests|ModelLifecycleCommandTests'
```

- All 21 HTTP-adapter, 63 LLM-service, 42 Local-CLI, 36 recovery, 43 model/health,
  61 transcript-context/chat, and 47 library tests passed, alongside the pill,
  panel and workspace suites.
- Five startup assertions raced accepted startup by waiting only for the mock
  service's call count. The controlled suspended-start tests passed; synchronize
  active-recording scenarios on accepted state rather than weakening expectations.
- Three stereo-source verdict regressions failed. Measuring written PCM exposed
  the converter's channel-selection/downmix assumption; fix the retained signal
  rather than relabeling silence or weakening the tests.
- Subsequent review found C1/control-string sanitation gaps. Real CLI calls
  reproduced control characters/payloads in success and failure output; a
  throwaway harness against the corrected verbatim sanitizer source passed six
  scenarios. The rebuilt CLI subsequently passed success/error/control cases.
- Independent spec review found no blocking alignment defects. Standards review
  identified pending-writer ownership and C1 sanitation gaps; both were corrected.

### Corrected-source verification

- Focused writer, recording-service, startup, health and subprocess regressions:
  **196 tests, 0 failures**, 30.049 seconds; build 48.64 seconds.
- One complete supported local run:
  `swift test --jobs 1 -Xswiftc -disable-batch-mode` executed **5,199 tests**,
  with **20 skipped and 3 assertion failures in one case**, in 360.179 seconds;
  build 50.80 seconds. Do not describe that command as green.
- The failing overlap fixture supplied identical simultaneous four-word phrases,
  which the short-echo policy introduced in `882ebddc` deliberately reconciles to
  the system source. Its distinct-overlapping-speech assertion was stale. The
  fixture now supplies distinct local/remote speech and retains both speakers,
  timestamps and interleaved text assertions; the existing short-echo and
  two-word-backchannel boundary tests remain intact. Focused confirmation passed:
  **82 tests, 0 failures**, 1.447 seconds; build 11.02 seconds. No second complete
  local suite is run; final CI remains the complete post-fixture gate.
- Corrected debug CLI completed synthetic speech → isolated SQLite → Markdown,
  then search/retrieval (JSON, exit 0), missing-record lookup (JSON, exit 1) and
  invalid arguments (exit 2). Transcript:
  `0230A2CF-D7B9-47B7-BED3-601811083A8E`.
- Corrected debug CLI passed five terminal-sanitizer scenarios and confirmed
  `health --json` leaves an absent isolated state root absent.
- `scripts/check-readme-references.sh`: pass. Local-link checks across 47 changed
  Markdown documents: zero unresolved paths.
- Changed Swift files formatted. Report-only repository `swift-format lint`
  exited 0 with **7,461 warnings and 0 errors**; this is existing tree-wide
  formatting debt, not a lint-clean claim.
- Throwaway sanitizer source harness and unsuccessful temporary GUI bundle/state
  removed. Synthetic CLI outputs remain outside the repository as local evidence.

### PR review correction checkpoint

- `no-mistakes` returned `checks-passed` at
  `c24c9a88d4bdea5a72ad62ee72ec501ed28ce4b5`. Hosted
  [push CI](https://github.com/moona3k/macparakeet/actions/runs/33948699389) and
  [PR CI](https://github.com/moona3k/macparakeet/actions/runs/33948702300) passed.
  This is a prior checkpoint, not approval of the follow-up corrections below.
- Follow-up source verification executed **566 XCTest cases, 0 failures** in
  **40.114 seconds**, after a **426.90-second build**. The focused command used
  `swift test --jobs 1 -Xswiftc -disable-batch-mode --filter` across writer,
  downmix, route recovery, meeting recording/recovery, repository, rename/query,
  prompt ownership, capture presentation, HTTP adapter and downloader suites.
- The writer now has one locked callback/deadline state instead of separate
  callback bookkeeping. Late callbacks retain ownership through timeout and
  release it before a completed outcome; duplicate callbacks cannot release a
  later owner's folder. Retired route callbacks and interrupted-source silence
  precedence also have focused regressions.
- Atomic rename returns current persisted content, not a stale reconstructed
  row. Missing IDs produce no success callback or artifact refresh. Gated
  initial/page-load regressions cover Library and Recent Meetings.
- Current same-transcript stale prompt actions show a retry notice; cancelled,
  replaced and navigated-away actions remain silent. Capture copy promises
  saved microphone audio only when reported written duration is positive.
- A standalone harness using the production OpenCode redirect implementation
  reproduced forwarding of synthetic credentials **and prompt bodies** to
  unapproved destinations. The corrected handler refuses those redirects while
  preserving approved requests; the post-fix harness and adapter tests passed.
  No live provider request or credential was used.
- The real downloader privacy regression passed with an isolated **5,000,000-byte**
  log. Rotation retained **2,500,157 bytes**, including the new failure record;
  the old fixed-offset slice would have been empty. First-buffer callback logs
  now use the existing asynchronous append path.
- The rebuilt debug CLI completed the synthetic transcription → isolated SQLite
  → Markdown smoke. Evidence remains in the test-owned `cli-post-review` folder
  outside the repository.
- Declined the broad read-only-health failure claim: actual current-schema CLI
  health returned `ok` without changing database bytes. Declined the diagnostic
  locale claim: with `AppleLocale=de_DE`, plain `String(format:)` emitted `0.123`,
  while the explicitly localized overload emitted `0,123`.
- Plan status modifiers, rotation guidance, unmeasured Raw latency, and matching
  database/artifact/UI/HTTP contracts were reconciled. Final follow-up commit,
  independent review and CI identities belong in PR #953 before merge.

### Verification boundaries

- Prior PR/CI proof is recorded above; merged-main identity is established only by the subsequent PR merge.
- Visual UI verification was waived by the maintainer.
- Teams/system-audio, USB/Bluetooth startup, signed-candidate upgrade and recovery
  are not certified by source review, unit tests or synthetic CLI smoke.
- No live cloud-provider credential request, DMG publication or appcast update
  was performed.

## Completion gate

Require final independent review and green CI,
then merge through a PR. Record PR/commit/CI identities in the PR and final
handoff. Keep hardware-dependent issues open without a demonstrated fix.
Neither a merged source branch nor these checks publish or certify a release.
