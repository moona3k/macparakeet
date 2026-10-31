# Issue #1286: measured keyboard output boundary

The indefinite rejection is caused by using combined-session key state as a
physical-key veto, with only process-local observed-release exceptions. The
original rare Jump Desktop trigger remains unproven. This change prevents our
own keyboard output from contaminating the state used for bare-Fn admission.

## Native experiment

[Run 41115055321](https://github.com/moona3k/macparakeet/actions/runs/41115055321)
executed the standalone C probe at commit
`8273a6e5c5f99dd99f117442825ca31cbb882c70` on macOS 15.8.2 (24H232).
[Raw observations](quartz-key-state.jsonl) contain only the designated F20 test
key, source IDs, process IDs, state Booleans, and marked-event witness counts.
No text, clipboard contents, or general keyboard history was captured.

| Posting point | Source state | Session after unmatched down | HID after unmatched down | Session tap witnessed down |
| --- | --- | --- | --- | --- |
| HID | HID | Down | Down | Yes |
| HID | Session | Down | Down | Yes |
| HID | Private | Down | Down | Yes |
| Session | HID | Down | Up | Yes |
| Session | Session | Down | Up | Yes |
| Session | Private | Down | Up | Yes |

With the two shared sources, a child posted at HID and exited without release.
Both tables remained down in the parent and a fresh reader process. Controlled
cleanup releases restored both. This reproduces persistent synthetic state
across producer exit; it does not reproduce Jump Desktop losing a release.

Changing only the source ID does not solve the problem. Changing only the
reader to HID also fails for the old HID-posted output. The measured repair is
to move application keyboard posting downstream to the session point **and**
use HID key state for bare-Fn admission. Apple recommends a combined-session
source for normal login-session posting; a private state table adds no benefit
in this experiment. See [Apple source-state documentation](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid).

## Scope and limits

### Final replay evidence

[Run 41141415735](https://github.com/moona3k/macparakeet/actions/runs/41141415735)
passed at `556ce1dea0ffa0c2ed6c1f646be5f2c681eb6642`. Its expanded probe
posted an original session down, a second down at either replay point, and
the original producer's session up. Each step had an event-delivery witness.

| Replay point | HID after replay down | Session after producer's session up | HID after producer's session up |
| --- | --- | --- | --- |
| HID (old path) | Down | Up | Down |
| Session (fixed path) | Up | Up | Up |

This confirms that promoting session input into HID can leave the HID table
stale even when its producer delivers a session release. The fixed replay
stays at session and leaves both tables up after release. Cleanup restored
both tables in each experiment. [Exact raw state artifact](quartz-key-state-556ce1dea.jsonl)
and [native paste artifact](quartz-paste-556ce1dea.jsonl) are retained here.
The AppKit receiver again observed the generated paste.

This is a sequential state-table experiment, not a reproduction of the live
interrupt callback or the reporter's Jump Desktop setup. It narrows the cause
of the replay defect without proving the original rare incident's trigger.

### Behavior boundaries

The shared factory marks events and preserves layout-resolved key codes,
Command flags, pairing, and clipboard behavior. Hotkey listeners ignore the
marker before consuming input or modifying gesture/release state. The existing
streaming marker value/name remains compatible. Custom shortcuts, peer-claim
recovery, and modifier flags retain their existing semantics.

Pre-held session-only ordinary keys are excluded from the HID admission
snapshot even when unmarked. Unmarked events still reach gesture handling;
ordinary typing retains its existing interruption behavior. Remote-input or
remapping configurations that use session-only injection therefore need their
own acceptance test; preserving event dispatch does not preserve the old
session-based pre-held-key veto.

Old versions or other software can still contaminate HID state. The two Quartz
tables cannot distinguish that from a real held key. Existing observed-release
recovery is retained; pressing and releasing the affected key can restore Fn.
There is no unconditional key-up, timeout, or key-specific bypass. Upstream
interception/reposting by another app may also contaminate HID and is outside
the proven direct-post boundary.

Hosted-runner source/table observations do not prove physical held-key detection,
non-US native layout behavior, or Jump Desktop compatibility. Session posting
bypasses upstream HID taps; the target application must still be qualified.
The additional AppKit receiver probe passed ordinary native paste delivery in
[run 41118721047](https://github.com/moona3k/macparakeet/actions/runs/41118721047)
at `2c8cd30df92f4572d2260627833e682822be8aa8`. A focused native NSTextView
received the marked session-posted Command-V from a separate process.
[Raw receiver result](quartz-paste.jsonl): `receiver_ready`, then
`native_paste_observed`. The same run repeated the state-table experiment.
Initial receiver attempts could not activate a command-line app, then lacked
posting permission when launched as an app bundle. Those precondition failures
were not paste-delivery failures. The final probe launches the receiver through
Launch Services and posts from the runner-authorized producer.
Physical V/Command holds, tap interruption, a supported non-US layout, and the
reporter's Jump configuration remain release acceptance gates. Keep #1286 open
until that evidence supports closure.

## Verification

Regression tests exercise production event construction/posting through a
capture seam (no OS injection), marker handling before hotkey dispatch, stale
session versus held HID keys, new managers and tap recovery, delayed/missing
synthetic releases, and legacy recovery. Existing physical-input, peer,
Command-layout, and clipboard restoration suites remain part of GitHub CI.
No local Swift build/test or no-mistakes test gate is run, as requested.

The final production head `556ce1dea0ffa0c2ed6c1f646be5f2c681eb6642`
passed [full CI](https://github.com/moona3k/macparakeet/actions/runs/41141415724):
8,269 xUnit cases with zero failures/errors, plus 30 Swift Testing cases.
The seven new replay, session-only-admission, and interrupt-failure regressions
were individually present and passing in the downloaded XML. Swift 6 and
release/bundle checks also passed. These are hosted checks, not the outstanding
native release acceptance cases below.

The first full input-branch suite executed 8,230 cases with one failure in the
new test's attempt to overwrite an already-stamped event's source user data.
A small local C experiment created event objects without posting input: after
writing our marker, replacing it with 123 still read the original marker; a
separate fresh event read 123 correctly. The test now checks foreign metadata
on a fresh event, with a raw-value assertion. Production only stamps new events
once and does not remove markers, so no production change was needed.

Independent initial correctness review confirmed the boundary design and
required the producer-exit and delivery-witness cases included in the probe.
Local Greptile is installed but unauthenticated; independent review and GitHub
review feedback provide the review loop. Jev was not used for this causal
code/API investigation.

## Review of effects outside the change

Applied p-stack's [blast-radius skill](https://github.com/cursor/plugins/blob/main/pstack/skills/blast-radius/SKILL.md)
as a focused review, without installing its Cursor workflow. The critical fact
is that session posting leaves HID key state up while delivering the output.
The hosted state probe and native receiver establish that fact for the tested
macOS image. They do not establish compatibility with an upstream HID-only
consumer, a remapper that reposts at HID, or the reporter's Jump environment.

Independent review preserved session-based peer pruning and added a regression
where the session table reports a claimed peer held while HID reports it up.
GitHub Greptile identified two developer probes that extracted the old marker
by text; both now compile the shared keyboard helper directly. The fresh Opus
review identified the interruption replay as another potential HID writer:
an intercepted event has already reached the session stage, so replaying it
upstream can promote session-only input into HID. Replay now uses the session
entry point alongside the flushed text, preserving the original metadata and
unmarked identity. Ordering against a release already queued during flushing
still requires native acceptance.

The input PR is [#1293](https://github.com/moona3k/macparakeet/pull/1293). As of
2026-10-30, the macOS runner prerequisite
[#1294](https://github.com/moona3k/macparakeet/pull/1294) is merged and the input
PR targets main. The test-only readiness follow-up
[#1298](https://github.com/moona3k/macparakeet/pull/1298) remains separate.
A [published walkthrough](https://macparakeet.com/dev/pr/1293) explains the same
boundary and acceptance limits. The subsequent [fresh review](fresh-eye-review.md)
records findings and the merge/release gates.
