# 0.8 first-run regression diagnosis

Date: 2026-09-18 (Pacific). Live D1 2026-09-19 05:15–05:25 UTC.
Status: **read-only diagnosis**. No app, D1, or website writes.
Question: is the September T0 gap (0.7.3 **37.5%** vs 0.8.0 **29.8%**) a
shipped first-run regression?

Companion: [2026-09-18-onboarding-activation-leak.md](./2026-09-18-onboarding-activation-leak.md).
Sources: tags `v0.7.3` (`d6321f87`, 2026-07-16) and `v0.8.0`
(`76c126b1`, 2026-09-09), GitHub PRs
[#984](https://github.com/moona3k/macparakeet/pull/984) and
[#1099](https://github.com/moona3k/macparakeet/pull/1099), D1
`macparakeet-telemetry`, current `HotkeyManager` at those tags.

## Verdict

**Yes, 0.8.0 shipped a real first-run-relevant regression. It does not
explain the whole 8-point headline by itself.**

The hole is **T0 try**, not STT. Same-session `dictation_started` after
onboarding: 0.7.3 **47.4%** (258/544) vs 0.8.0 **38.2%** (124/325). Of
people who *did* start, success is identical (**79.1%** vs **78.2%**).
First-load wait, model warm-up, and empty/cancel quality are not the
0.8.0 gap.

What changed that can produce “they never start”:

1. **Confirmed shipped bug (PR #984, merged 2026-09-08, in 0.8.0 the next
   day).** Built-in Fn became a listen-only tap with a physical-key
   ledger that fail-closes on any key `CGEventSource.keyState` reports
   down. **Caps Lock (key 57) stays “down” while latched.** Every Fn
   hold and double-tap is rejected. Onboarding teaches exactly those
   two gestures. No `dictation_started` fires. Fixed in
   **[#1099](https://github.com/moona3k/macparakeet/pull/1099) /
   v0.8.7** (2026-09-18). 0.8.0–0.8.6 all have the bug.
2. **Launch-week mix, also real.** 0.8.0’s first full day (Sep 10) is
   **32.5%** T0 — only ~5 points under 0.7.3 weekdays. Sep 11 and 14
   drop to **~24%**. Weekends recover to **34–43%**. Later 0.8.3 / 0.8.5
   sit at **33–34%**. The raw 37.5 vs 29.8 comparison mixes a full-month
   0.7.3 cohort (including a 61% Sunday) with 0.8.0’s launch weekdays.

0.8.6’s 15% T0 is a **later, separate** hold-to-talk abort, not the
0.8.0 hole.

Onboarding copy, default Fn/Fn shared gesture, and the Ready-screen
“Open MacParakeet” finish path are **unchanged** from 0.7.3 to 0.8.0.
The long-running Ready-screen leak is still there; it is not new in 0.8.

## What the 8 points actually are

September 1–18, same-process T0 (`onboarding_completed` session also has
`dictation_completed`):

| app_ver | Completers | T0 try | T0 success | Try % | Success % | Success \| try |
|---|---:|---:|---:|---:|---:|---:|
| 0.7.3 | 544 | 258 | 204 | 47.4 | **37.5** | 79.1 |
| 0.8.0 | 325 | 124 | 97 | 38.2 | **29.8** | 78.2 |

Daily, 0.7.3 vs 0.8.0:

| Day | 0.7.3 T0 | 0.8.0 T0 |
|---|---|---|
| Sep 1–8 (0.7.3 current) | 23+30+19+33+19+8+25+21 = **178 / 479 = 37.2%** | — |
| Sep 9 (0.8.0 ships 19:48Z) | 21/49 = 43% | 2/15 = 13% (n small) |
| Sep 10 | n leftover | **25/77 = 32.5%** |
| Sep 11 | leftover | **18/73 = 24.7%** |
| Sep 12 Sat | — | 12/35 = 34.3% |
| Sep 13 Sun | — | 18/42 = 42.9% |
| Sep 14 | leftover | **18/74 = 24.3%** |

Fairer reads:

- 0.7.3 as the then-current release (Sep 1–8): **37.2%**
- 0.8.0 first full weekday: **32.5%** (−4.7)
- 0.8.0 launch weekdays 10+11+14: **61/224 = 27.2%** (−10)
- Settled later 0.8.3+0.8.5: **43/129 = 33.3%** (−4)

So: a **~5 point** residual that survives mix, plus a **launch-weekday
dip** that looks like tire-kickers / update chaos. The original “8
points” is the blended number, not a single mechanism.

## Hypotheses and evidence

### H1 — STT / first-load / model not ready after 0.8.0

**Rejected.** Try→success is flat. Fleet `dictation_failed` sessions /
`dictation_started` sessions: 0.7.3 1314/3720 (35%) vs 0.8.0 232/1211
(19%) — 0.8.0 is *better* among people who start. First-load caption
volume is small (186 September sessions) and is not an 0.8.0-only
event. `HotkeyTrigger.swift` and `AppHotkeyCoordinator.swift` have
**empty diffs** `v0.7.3..v0.8.0`.

### H2 — Onboarding UX / default hotkey / Ready CTA changed

**Rejected as an 0.8.0 delta.** `OnboardingFlowView` still says
double-tap Fn / hold Fn, still has the no-STT “Try it now” preview,
still finishes on **“Open MacParakeet.”** Defaults remain
`.defaultDictation = .fn` and `.defaultPushToTalk = .fn`. The
Ready-screen leak exists on 0.7.3 too (37.5% is already bad).

### H3 — Launch mix only

**Partial.** Explains Sep 11/14 and why weekends look fine. Does **not**
explain the ~5 point residual on Sep 10 and on later 0.8.3/0.8.5, or
why the entire gap sits in try rate.

### H4 — Passive Fn + Caps Lock ledger (PR #984)

**Accepted as a shipped regression. Magnitude unquantified.**

[#984](https://github.com/moona3k/macparakeet/pull/984) “Make built-in
Fn dictation passive and reject mixed gestures” merged
**2026-09-08T07:31:56Z**, ~36 hours before `v0.8.0`. It extracted the
Fn-only half of open CRT-123 (#870). Design:

- Fn tap options: `.listenOnly` (0.7.3 used `.defaultTap` for every
  trigger, including Fn).
- On Fn down, snapshot every virtual key 0…127 via
  `CGEventSource.keyState`. Any reported-down key ⇒
  `passiveFnInputIsContaminated` ⇒ gesture cancelled, no start.
- PR text said “Stable latched Caps Lock remains allowed.”

[#1099](https://github.com/moona3k/macparakeet/pull/1099) (merged into
**v0.8.7**, 2026-09-18) found the opposite in the field while verifying
#1096/#1097:

> `CGEventSource.keyState` keeps Caps Lock (key 57) down while the
> latch is on. The ordinary-key ledger treated that as contamination
> and rejected the gesture.

0.8.0 `isTrackableNonFnKeyCode` is `0...127 && !isFnKeyCode`. It does
**not** exclude 57. 0.8.7 adds `&& keyCode != capsLockKeyCode` and
filters the snapshot through the same helper.

Tests for #984 stubbed every physical key as up, so CI never saw latch
behavior. That is why “Caps Lock remains allowed” shipped false.

This predicts exactly the telemetry shape: **try rate down, success
given try unchanged, fleet power-user volume still huge** (0.8.0 still
did 32k completed dictations — people with Caps Lock off, or who
already hold-to-talk from muscle memory). Onboarding preview uses the
same `HotkeyManager`, so the hotkey step’s “Try it now” is also dead
with Caps Lock on.

We cannot count Caps Lock-on new users in D1. A 5-point T0 residual is
plausible if a mid-single-digit to low-teens share of would-be-tryers
had the latch on. It is **not** proof the ledger is the entire residual.

Fleet mode mix does **not** show double-tap dying for people who
succeed (0.8.0 persistent share is slightly *higher* than 0.7.3). Caps
Lock blocks hold and double-tap equally, so mode mix among survivors
should stay similar. It did.

### H5 — 0.8.6 hold-to-talk abort

**Real, later, different.** 39 completers / 9 tries / 6 successes on
Sep 18. Do not fold this into the 0.8.0 story. Treat Friday Sep 18 as
contaminated, same as the Sparkle note.

## What 0.8.0 did *not* change (first-run)

`git diff v0.7.3..v0.8.0` is empty for `HotkeyTrigger.swift` and
`AppHotkeyCoordinator.swift`. Onboarding step order is already the
six-step dictation-first flow in 0.7.3. Discover-optional and menu-bar
visibility (#937 / #876) are settings, default-on, not the first
dictation path.

`HotkeyManager.swift` *did* change: +189 lines, all CRT-123 / #984.

## What to do

1. **Do not ship another 0.8.0-style Fn ledger change without a Caps
   Lock-latched unit test that uses a real `keyState` stub returning 57
   down.** 0.8.7 already has that exclusion; this checkout’s `main` is
   behind `origin/main` and still has the 0.8.0 helper. Pull before
   any hotkey work.
2. **Re-read T0 after 0.8.7 has a few weekdays** with no further
   firehose. If new-user T0 on 0.8.7+ returns toward ~37% (0.7.3’s
   September rate), #1099 was a material piece of the residual. If it
   stays ~33%, the rest is the Ready-screen leak + mix.
3. **Clean UserDefaults smoke** (not a developer Mac): Caps Lock on,
   0.8.6 vs 0.8.7, double-tap and hold on the onboarding hotkey step
   *and* after Finish. 0.8.6 should no-op; 0.8.7 should start.
4. **Keep the Ready-screen first-success work.** Even a fully fixed Fn
   path leaves ~63% of 0.7.3 completers without same-session
   dictation. That is not an 0.8 regression.

## Queries

Daily and version T0: `onboarding_completed` sessions in
`2026-09-01`…`2026-09-19` joined to same-session `dictation_started` /
`dictation_completed` for `app_ver IN ('0.7.3','0.8.0')`. Fleet mode
and start/empty/cancel/fail grouped by `app_ver` on
`dictation_*` (not T0-only; the T0 mode join hit D1 CPU limit 7429).
