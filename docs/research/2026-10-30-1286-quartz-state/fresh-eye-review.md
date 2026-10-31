# Fresh review of #1293 and #1298

Review date: 2026-10-30. Input code reviewed at
`2fa2f0090a7e7872c6f71625f9488684400a1b88`; the separate editor fixture at
`5172acd8207c3b9849c3b25032e68b8dbca574c6`.

## Scope and findings

The review read the complete input diff, surrounding posting and hotkey
recovery paths, the native experiments, tests, contracts, and all bot threads.
An independent adversarial review found no blocking code defect. It also
reviewed the editor fixture and confirmed that its readiness waits preserve
the substantive geometry assertions.

The ownership boundary is consistent: generated keyboard events are marked
and posted at the session entry point; all three hotkey listeners reject the
marker before consumption or gesture/release bookkeeping. Bare-Fn ordinary-key
reconciliation uses HID state. Custom-trigger synchronization and peer-claim
recovery retain session state. Both members of each keyboard pair are allocated
before either is posted, with no suspension between posts.

One contract claim was too broad: preserving unmarked event dispatch does not
preserve the old pre-held session-key veto. The follow-up explicitly documents
that session-only ordinary keys do not veto fresh Fn, even when unmarked, and
adds a regression that feeds an unmarked down through the actual input boundary
before Fn. The existing test still requires arriving unmarked ordinary typing
to interrupt a take. Peer exceptions remain unchanged. Production code did not
change during this clarification.

## Opus 5.5 review and disposition

Claude Code 2.1.311 ran in noninteractive mode with model
`claude-opus-5-5`, no fallback, and no enabled tools. The initial review and follow-up reviews
completed successfully; assistant response metadata and the
reported canonical model confirmed Opus 5.5 on the first-party provider.
Session: `e1d878ea-a68e-4039-b2e4-ab9c3493ea3c`. The bundle contained the diff,
relevant source/tests and evidence, not user audio, transcripts or credentials.

Opus found no merge-blocking code defect but identified one additional HID
writer worth repairing: streaming interruption replayed an intercepted session
event upstream at HID after flushing. The correction keeps replay at the
session entry point and preserves the original, unmarked metadata. A test
exercises the production replay helper for keyboard and mouse input, including
one-post behavior, copied fields, foreign metadata and posting location.
Independent review agreed with the correction; Opus's follow-up found no new
correctness issue.

The hosted probe now models original session down, replay at HID or session,
and the producer's session up. It records the old path without assuming the
cross-table release outcome and requires the corrected path to leave HID clear.
Both reviewers requested delivery-witness checks; each step now requires a
matching observed event. Failures after a possible HID replay retain HID
cleanup. This models table effects, not the production callback's live ordering
or intercepted-event metadata; the posting-boundary test covers the copy.

Two other concrete observations were addressed: the receiver's polling parser
now consumes only newline-terminated JSON records, and the feature spec
distinguishes live event flags from combined-session recovery flags. A local
parser check covered empty/partial/complete records and retained failure on a
malformed complete record.

The combined-session source is retained: the measured posting boundary works
and the native receiver accepted it; no destination/source-metadata failure was
established. Optional source-text scan tests and additional admission logging
were not added. The existing semantic tests, source review and bounded native
experiments address the concrete question without a new tracking framework.

## Bot findings

- [Developer probes extracting the old marker](https://github.com/moona3k/macparakeet/pull/1293#discussion_r4427897023): both now compile the shared helper directly. Verified in source; thread resolved.
- [Unavailable native probe could pass](https://github.com/moona3k/macparakeet/pull/1293#discussion_r4428676721): both permission failure paths now exit nonzero. Verified in source; thread resolved and acknowledged by the bot.
- [Modifier source misstated in the spec](https://github.com/moona3k/macparakeet/pull/1293#discussion_r4428676731): the spec now distinguishes combined-session modifier flags from HID ordinary-key state. Verified against code; thread resolved and acknowledged by the bot.
- [Retry after failed interruption flush](https://github.com/moona3k/macparakeet/pull/1293#pullrequestreview-5719482607): CodeRabbit identified a pre-existing ordering defect at the touched replay boundary. A transient flush failure could let the user's click through, then retry text at the changed cursor or destination. Independent review confirmed it. A terminal failure latch under the existing playback lock now prevents later posts through normal, error, and cancellation drains. User input is not retained. `partialInsert` suppresses automatic paste even before the first committed chunk; recovery copy is worded without assuming any text landed. Regression cases use a one-time failure that would succeed on retry and cover zero/one committed chunks plus real task cancellation. The zero-commit error path stops posting under the playback lock, quiesces the tap without holding that lock, then chooses the recovery error; regressions cover interruption during the initial failure and during tap teardown. This prevents an in-flight callback from turning a previously selected availability error into a late automatic paste. Opus and the independent adversarial reviewer both reviewed the final teardown ordering and found no blockers. Five new regression cases cover the failure paths; their execution is delegated to GitHub CI.

## Native evidence replay

[Run 41134052540](https://github.com/moona3k/macparakeet/actions/runs/41134052540)
passed at the reviewed input head. Its downloaded JSON was checked explicitly:
six posting-point/source combinations, eight fresh readers, two producer-exit
cases, marked down-delivery witnesses, cleanup, and native AppKit paste
delivery all match the reported boundary. The probe is observational: its green
status alone is not the assertion that HID and session state separated. The
subsequent replay correction and expanded probe need their own current-head
GitHub checks; this earlier run does not qualify those changes.

The C probe passed a syntax-only compiler check, the edited Swift files parsed
through swift-format, and whitespace checks passed. No local Swift build/test,
input injection, or no-mistakes test gate ran.
The user's earlier instruction to use GitHub CI still applies. Current check
status belongs to the [input PR](https://github.com/moona3k/macparakeet/pull/1293)
and [fixture PR](https://github.com/moona3k/macparakeet/pull/1298), not an older
head's result.

## Merge and release boundary

At final review the user explicitly authorized merge without waiting for another
CI run. The production head `556ce1dea0ffa0c2ed6c1f646be5f2c681eb6642` had
already passed [full CI](https://github.com/moona3k/macparakeet/actions/runs/41141415724)
(8,269 xUnit cases and 30 Swift Testing cases, zero failures/errors), Swift 6,
release/bundle checks, and the expanded
[native probe](https://github.com/moona3k/macparakeet/actions/runs/41141415735).
The downloaded artifacts confirmed the replay boundary and all seven new
replay/admission/interruption regression cases. Earlier timeouts remain failures
to qualify those earlier runs; they are not reclassified as passes.

The final [CodeRabbit cancellation comment](https://github.com/moona3k/macparakeet/pull/1293#discussion_r4429228526)
identified overbroad contract wording. Cancellation intentionally returns quietly;
the coordinator checks `Task.isCancelled` before success, clipboard retention,
or post-insert actions, and its error handler also skips recovery when cancelled.
Throwing `partialInsert` would not enable recovery. The contract now limits
clipboard recovery to non-cancelled insertions and explicitly preserves quiet
cancellation with no retry. A test comment explains the existing assertion;
runtime behavior and assertions are unchanged. Independent review confirmed
this disposition.

The final fresh review used Claude Code with `claude-sonnet-5-5`, `xhigh`
effort, no fallback, and no tools. Session
`4152c82c-2470-42b4-bb14-0b91b14fcb78` completed successfully; response model
metadata confirmed Sonnet 5.5. It reviewed the complete diff, governing
source/tests/contracts, caller excerpts, and current bot feedback at the
production head. It found no P0/P1/P2 issue or merge blocker and agreed with
the cancellation clarification. Its requested caller inventory check confirmed
that `DictationFlowCoordinator` is the only production insertion caller.
The final follow-up changes only documentation, preserved probe artifacts,
and a test comment; production behavior and test assertions are unchanged.

The fix prevents our direct keyboard output from creating this admission veto.
It does not repair arbitrary old or third-party HID contamination. An unmarked
release retains the existing recovery path. Physical held V/Command, non-US
layout, copy/Unicode destinations, and the reporter's Jump Desktop setup remain
native release acceptance work. Live replay ordering against a keyUp already
queued during flushing is also unverified. Session-only remote/remapped input needs
acceptance because pre-held admission deliberately follows HID state.
The original lost-release trigger is still unproven; keep #1286 open.
