# Onboarding activation leak

Date: 2026-09-18 (Pacific). Live D1 queries 2026-09-19 05:00–05:15 UTC.
Status: **read-only**. Companion to
[2026-09-18-telemetry-user-landscape.md](./2026-09-18-telemetry-user-landscape.md)
and the July setup audit
[2026-07-04-onboarding-telemetry-review.md](../audits/2026-07-04-onboarding-telemetry-review.md).
Sources: Cloudflare D1 `macparakeet-telemetry`
(`7372263e-6a0b-4c70-8188-8f1d6d16bf31`), live `GET /api/stats`
(generated 2026-09-19T05:00:26Z), and current onboarding code
(`OnboardingViewModel`, `OnboardingFlowView`). No production writes.

This is not a Sparkle-DAU story. Installed-base usage is still compounding
([Sparkle note](./2026-09-18-sparkle-dau-measurement.md)). The leak is
**new-user activation**: people who start or finish setup without a first
successful dictation.

## Verdict

There are two stacked leaks, and only one of them is getting worse.

1. **Setup abandon is real and stable.** About **38%** of onboarding
   starters never emit `onboarding_completed`. Speech Model
   (`WarmUpStalled`) is still the largest measured blocker. Accessibility
   is second. This has not blown out since the July audit.
2. **Post-complete T0 is the growing leak.** Same-session
   `dictation_completed` after `onboarding_completed` fell from **~45–50%
   in June** to **32.8% in Sep 1–18**, and **27.6% in the week of Sep 14**.
   Public `/api/stats` 30d T0 is **34.3%** (610 / 1,778 completers).

The important volume fact: **absolute first-session successes are flat
(~21/day) while completers grew (~49/day in June → ~65/day in September).**
We are minting more “You’re all set” users and the same number of people
who actually dictate before quitting the process.

Do **not** divide rolling `first_dictation_completed` by
`onboarding_completed` and call the gap “never activate.” That pitfall is
documented in
[activation-metrics-cohort-caveats.md](../audits/2026-06-03-activation-metrics-cohort-caveats.md).
T0 below is always **same process UUID**.

## How to read the funnel

```text
install / first launch
  → onboarding_step welcome viewed     (starter)
      → permissions + hotkey + model
          → onboarding_completed       (completer; dashboard "new users")
              → dictation_started      (T0 try)
                  → dictation_completed (T0 success)   ← primary KPI
```

`session` dies on quit. A completer who comes back tomorrow and dictates
is invisible to T0. `first_dictation_completed` can catch that later, but
only once per install and only after 2026-05-23. Among people who *do*
emit that milestone in September, **62% do it within an hour** — so the
people who will activate usually activate immediately. The T0 miss is
mostly a miss, not a slow start.

## Historical trend

### Completers vs T0 (monthly)

From the landscape note, re-stated as daily rates so September’s 18-day
window is comparable:

| Month | Completers / day | T0 success / day | T0 success rate |
|---|---:|---:|---:|
| 2026-06 | 48.7 | 22.0 | **45.2%** |
| 2026-07 | 52.4 | 21.3 | **40.6%** |
| 2026-08 | 53.0 | 20.6 | **39.0%** |
| 2026-09 (1–18) | **65.4** | 21.4 | **32.8%** |

T0 *count* did not crash. Completer *count* did the growing. The rate
fell because the extra completers are not dictating in that process.

T0 try fell with it (53% in June → 43% in September). Try→success also
softened (June 660/781 = 85% → September 386/501 = 77%). The main hole
is **they never press the hotkey**, not “STT is broken after they try.”

### Weekly T0 (GUI, `app_ver != 0.0.0`)

Live D1, June 1 – September 18. Week labels are SQLite `%Y-W%W`.

| Week start | Completers | T0 try | T0 success | Try % | Success % |
|---|---:|---:|---:|---:|---:|
| 2026-06-01 | 351 | 205 | 176 | 58 | **50** |
| 2026-06-08 | 422 | 222 | 183 | 53 | 43 |
| 2026-06-15 | 296 | 151 | 133 | 51 | 45 |
| 2026-06-22 | 286 | 155 | 129 | 54 | 45 |
| 2026-06-29 | 283 | 147 | 123 | 52 | 43 |
| 2026-07-06 | 346 | 176 | 148 | 51 | 43 |
| 2026-07-13 | 421 | 193 | 164 | 46 | 39 |
| 2026-07-20 | 316 | 158 | 137 | 50 | 43 |
| 2026-07-27 | 400 | 190 | 150 | 48 | 38 |
| 2026-08-03 | 386 | 214 | 163 | 55 | 42 |
| 2026-08-10 | 370 | 174 | 145 | 47 | 39 |
| 2026-08-17 | 351 | 157 | 136 | 45 | 39 |
| 2026-08-24 | 364 | 158 | 128 | 43 | 35 |
| 2026-08-31 | 439 | 216 | 165 | 49 | 38 |
| 2026-09-07 | 429 | 180 | 145 | 42 | 34 |
| 2026-09-14 | 387 | 147 | 107 | 38 | **28** |

June 13 shipped dictation-first onboarding (ADR-005 Part A: drop Meeting
+ Calendar). That week and the next settle around **44–45%**, not 50%.
Part A recovered people who used to die on Screen Recording; it did not
raise T0 among completers. Then a slow grind through August (into the
mid-30s), then a **0.8.x cliff in W37**.

### September T0 by app version

Same-session T0 for `onboarding_completed` in 2026-09-01 .. 09-18:

| app_ver | Completers | T0 try | T0 success | Success % |
|---|---:|---:|---:|---:|
| 0.7.3 | 544 | 258 | 204 | **37.5** |
| 0.8.0 | 325 | 124 | 97 | **29.8** |
| 0.8.1 | 89 | 36 | 22 | 24.7 |
| 0.8.3 | 85 | 33 | 28 | 32.9 |
| 0.8.5 | 44 | 22 | 15 | 34.1 |
| 0.8.4 | 32 | 13 | 10 | 31.3 |
| 0.8.6 | 39 | 9 | 6 | **15.4** |
| 0.8.2 / 0.8.7 | 10 | 4 | 2 | n small |

0.7.3 in September is still near the August blended rate. **0.8.x as a
group is 180 / 624 = 28.8%.** Follow-up diagnosis:
[2026-09-18-08-first-run-regression.md](./2026-09-18-08-first-run-regression.md).
The 8-point headline is partly launch-week mix; a real shipped bug
remains: PR #984’s passive-Fn key ledger treated Caps Lock as
contamination (fixed in #1099 / 0.8.7). 0.8.6 (Sep 18 hold-to-talk
abort) is a later, separate first-run landmine.

## Setup funnel (the other leak)

Step telemetry gained `action` in early July. Before that, only the
destination step was recorded (legacy human labels, no `welcome`).

### Reach (distinct sessions)

| Month | Welcome viewed | Mic forward / view | Ready completed | Finish rate |
|---|---:|---:|---:|---:|
| 2026-05 | — | 1,287 mic | 815 ready | 63% of mic |
| 2026-06 | — | 2,198 mic | 1,449 ready | 66% of mic |
| 2026-07 | 1,865 | 1,736 forward | 1,224 completed | 66% of welcome |
| 2026-08 | 2,654 | 2,411 forward | 1,620 completed | **61%** of welcome |
| 2026-09 (1–18) | 1,877 | 1,656 forward | 1,170 completed | **62%** of welcome |

Abandon is **~38%** and has been since welcome became measurable. The
June 13 meeting-step removal is visible in the raw labels: May/June still
have a Meeting Recording cliff; July+ meeting/calendar rows are leftover
old clients only.

### Where September starters die

Using `action` on `onboarding_step` (Sep 1–18):

| Signal | Sessions |
|---|---:|
| Welcome viewed | 1,877 |
| Welcome dismissed | 119 |
| Mic dismissed | 28 |
| Accessibility dismissed | 25 |
| Hotkey dismissed | 8 |
| Speech Model `engine_failed` | 330 |
| Speech Model dismissed | 84 |
| Speech Model `engine_ready` | 1,352 |
| Ready completed | 1,170 |

Explicit dismiss events (~268) do not add up to the ~707 starter→completer
gap. The rest quit without tapping Exit Setup (force quit, crash, leave
the window up, or die on a blocked Continue). Speech Model is still the
biggest *named* graveyard.

Engine-failed sessions that later completed in the **same process**:

| Month | `engine_failed` sessions | Later completed | Recovered |
|---|---:|---:|---:|
| 2026-07 | 512 | 313 | 61% |
| 2026-08 | 982 | 649 | 66% |
| 2026-09 (1–18) | 330 | 198 | 60% |

About **40% of model failures never finish setup.** August was the worst
failure *volume* (982); September failure *rate* improved (330 / 1,877
welcome ≈ 18% vs August 982 / 2,654 ≈ 37%) **while T0 still got worse.**
Setup reliability is not what pulled September T0 down.

September `model_download_failed` sessions are almost all
`WarmUpStalled` (318). Network errors are tens, not hundreds. The 180s
warm-up watchdog in `OnboardingViewModel` is the dominant setup killer.

Continue is blocked until `engineState == .ready`
(`canContinueFromCurrentStep`). Failed users see Retry / Open Settings.
They cannot skip.

### How long setup takes (completers only)

`onboarding_completed.duration_seconds` is populated now (1 missing of
1,174 September rows). The mean (~47 min) is junk: 58 sessions are
`over_1h` (window left open / `startedAt` on a long-lived process).

| Duration | Completers | Share |
|---|---:|---:|
| under 1 min | 211 | 18% |
| 1–3 min | 341 | 29% |
| 3–10 min | 431 | 37% |
| 10–30 min | 105 | 9% |
| 30–60 min | 28 | 2% |
| over 1 h | 58 | 5% |

**84% of completers finish in under 10 minutes; 47% in under 3.** Part B
head-start (warm-up at window open) is doing its job for people whose
download works. Fast setup + a Finish button is exactly the “complete
and leave” shape.

## Why the product produces this shape

Current six-step contract (ADR-005): Welcome → Microphone →
Accessibility → Hotkey → Speech Model → Ready.

The Ready screen is a celebration, a tip list (hotkey / drop a file /
Settings / meetings), and a primary button **“Open MacParakeet”** that
writes `onboarding_completed` and opens the main window. It does not
require, or even host, a real dictation.

The Hotkey step already offers “Try it now” — a **no-STT live preview**.
That is a rehearsal of the gesture, not a first success. A user can
leave onboarding believing they already tried dictation.

Accessibility is required to continue. Mic is required. The model must
be `.ready`. Then we congratulate them and send them to a menu-bar app
whose core verb is a global hotkey they just practiced *without speech*.

July’s audit already ranked the follow-up as: (1) Speech Model recovery,
(2) Accessibility clarity, (3) **nudge the first successful dictation,
not just open the app.** (1) improved in September. (3) was never built.
T0 kept falling.

## What this is not

- **Not a DAU crash.** Weekday GUI sessions, dictations, and onboarding
  completions are above August. Sparkle Sep 11–18 is a last-check hole.
- **Not “76% never activate.”** That arithmetic mixes pre-2026-05-23
  completers into a `first_dictation_completed` denominator.
- **Not mostly Settings re-runs** as far as we could cheaply tell.
  Completer events ≈ distinct sessions (~1,180 in Sep). A same-session
  prior-dictation join hit D1’s CPU limit; treat re-run inflation as
  unquantified but not the headline.
- **Not screen-recording.** That permission is hostile (Sep: 19 granted
  / 606 denied) and lives on the meeting path, which onboarding no
  longer includes.
- **Not first-load caption as the main T0 hole.** 186 September sessions
  showed `dictation_first_load_caption_*` versus 501 T0 tries. Most
  completers never see it, because they never start a dictation.

## Measurement bugs to fix while we are here

The public 24h `/api/stats` `onboarding` funnel still groups by legacy
labels (`speech model`, `meeting recording`). Live clients emit
`speech_model`. Today’s 24h snapshot showed `speech model: 0` and
`ready: 144`. The 30d `activation` block is the trustworthy setup KPI;
the 24h step chart is currently lying.

`new_users` is `onboarding_completed` count. Settings → “Run setup
again” constructs a new `OnboardingViewModel` and can emit another
completion. Add a `first_run` / `rerun` action before treating
completers as installs.

We cannot compute D1/D7 retention. Session IDs do not persist. Sparkle
hashes rotate daily. Any “churn” claim past T0 is a guess.

## What to change (priority)

### P0 — Make the first successful dictation the finish line

Highest expected T0 lift. Attacks the 57% of September completers who
never even `dictation_started` in that process.

- Replace Ready’s tip list + “Open MacParakeet” as the default path.
- Host a real in-window dictation (mic already granted, model already
  `.ready`). Primary CTA is “Try saying something.” Auto-complete
  onboarding on first `dictation_completed`.
- Keep an explicit “Skip for now” so we do not trap people, but do not
  make skip the default button.
- Stop treating the Hotkey no-STT preview as the “I tried it” moment.
  Preview can stay; it must not feel like success.

If even half of today’s non-tryers attempt a dictation and try→success
stays ~77%, T0 would move from ~33% to ~55% under that simplifying
assumption. This is a scenario, not a forecast.

### P0 — Diagnose the 0.8 first-run regression

Same calendar month, 0.7.3 T0 is 37.5% and 0.8.0 is 29.8%. 0.8.6 is
15% with almost no tries. This is a different bug from the Ready-screen
gap (that gap exists on 0.7.3 too). Likely surfaces: default hotkey /
shared double-tap gesture, pill vs menu-bar first chrome, first-load
wait after onboarding warm-up, 0.8.6 PTT abort. Verify with a first-run
smoke on a clean UserDefaults, not a developer Mac that already has
models cached.

### P1 — Recover Speech Model stalls

`WarmUpStalled` is still ~300 September sessions; ~40% of those
processes never complete. Head-start already overlaps the download with
permissions. Next levers are resume/heartbeat so the 180s watchdog does
not fire on a quiet-but-alive download, clearer Retry, and a bounded
“continue and finish download in the background” only if dictation can
fail with an actionable in-app repair instead of a dead hotkey.

Do not put Meeting Recording or Calendar back in the first-run path.
The 2026-05/06 meeting cliff was the last time we accidentally taught
new users that this is a meeting app.

### P2 — Welcome bounce and Accessibility

119 explicit welcome dismissals plus an unknown silent-quit tail. That
is smaller than Speech Model and much smaller than the T0 hole. Worth
copy/promise work after P0. Accessibility grant rate is already fine
when the prompt is shown; the remaining drop is “I don’t want to grant
this,” which we should not weaken (paste/hotkey need it).

### P2 — Dashboard hygiene

Map `speech_model` in the 24h funnel. Report duration as buckets, not a
mean. Tag re-runs. The daily briefing spec already says T0 is a product
alert, not a health-reviewer threshold
([2026-09-18-daily-telemetry-observability.md](../design/2026-09-18-daily-telemetry-observability.md)).

## Queries used

Weekly T0 (June–September) joined `onboarding_completed` sessions to
same-session `dictation_started` / `dictation_completed`. Step/action
and `engine_failed` recovery used `onboarding_step` props. Version split
is September only. Duration buckets and `model_download_failed` are
September only. A same-session “dictated before completing setup” join
was attempted for re-run contamination and hit D1 CPU limit 7429; do not
treat that as a zero.

## Related

- ADR-005 dictation-first onboarding: [`spec/adr/005-onboarding-first-run.md`](../../spec/adr/005-onboarding-first-run.md)
- Plan that shipped Part A/B: [`plans/active/2026-05-dictation-first-onboarding.md`](../../plans/active/2026-05-dictation-first-onboarding.md)
- Activation metric rules: [`docs/audits/2026-06-03-activation-metrics-cohort-caveats.md`](../audits/2026-06-03-activation-metrics-cohort-caveats.md)
