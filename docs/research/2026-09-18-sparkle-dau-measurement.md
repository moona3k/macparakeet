# Sparkle DAU measurement: Sep 11 cliff is not a growth stall

Date: 2026-09-18 (Pacific). Queries ran 2026-09-19 00:50–01:30 UTC.
Status: **read-only research**. No app, website, D1, or Cloudflare config changes.
Question: did weekday Sparkle device-days falling from ~1,780 (Sep 9) to ~1,130
(Sep 18) mean MacParakeet DAU stalled?

## Verdict

**No. The Sparkle series broke as a WoW growth metric during the 0.8.x
release firehose. Product usage did not fall with it.**

Sparkle appcast fingerprints are still the best **steady-state DAU floor**
(telemetry-off users included, ~one ping per device per day). They are a
**bad WoW comparator** when Sparkle is offering a new build every 12–24
hours. Each successful update writes Sparkle's last-check time, so that
device goes quiet for ~24h while GUI sessions and launches **rise** (relaunch
after the update). Leftover 0.7.3 users are also selected for auto-check
off, so they keep showing up in telemetry and not in Sparkle.

Last trustworthy Sparkle weekday peak: **1,780 devices on 2026-09-09**.
Current Sparkle ~1,130 is a **depressed floor**, not the new true DAU.
Best current unique-device guess remains **~1,500–1,800** on a weekday.
Do not read Sep 11–18 Sparkle as “we lost 40% of users.”

## Method

Primary sources only:

- Live D1 `macparakeet-telemetry`
  (`7372263e-6a0b-4c70-8188-8f1d6d16bf31`, account
  `1542b0baf1922ec403cc44ef3fd39233`) via
  `wrangler d1 execute --remote`. Database size ~2.68 GB.
- `sparkle_check` rows from website Pages middleware
  [`functions/_middleware.ts`](https://github.com/moona3k/macparakeet-website/blob/main/functions/_middleware.ts)
  (only `User-Agent` matching `^MacParakeet/<ver> Sparkle/`).
- GUI `surface='gui'` distinct `session` and `dictation_started` /
  `app_launched` on the same `events` table.
- GitHub releases `moona3k/macparakeet` `v0.8.0`–`v0.8.7`.
- Website `origin/main` history around 2026-09-09–12 (`functions/_middleware.ts`
  last changed in `b53776e`; no middleware commit on the cliff).
- Live `GET https://macparakeet.com/appcast.xml` headers
  (`cf-cache-status: DYNAMIC`, `Cache-Control: public, max-age=0, must-revalidate`).
- App Sparkle wiring: `SUEnableAutomaticChecks` true, no
  `SUScheduledCheckInterval` (Sparkle 2 default 86400s),
  `SparkleUpdateGuard`, Settings toggle.
- GUI long history: `stats_daily_rollups` (`day` 2026-03-26 through
  2026-09-17; published-version allowlist, same family as `/api/stats`).
- Joined daily extract:
  [`2026-09-18-sparkle-dau-daily.csv`](./2026-09-18-sparkle-dau-daily.csv)
  (178 calendar days). Rollup sessions/dictations are slightly below raw
  `surface='gui'` event counts because of the version allowlist.

No production writes. No Sentry. No Unblocked.

Coverage:

| Series | First UTC day | Last complete UTC day | Rows |
|---|---|---|---:|
| GUI rollups (sessions, dictations, new_users) | 2026-03-26 | 2026-09-17 | 176 |
| `sparkle_check` | 2026-05-26 | 2026-09-18 | 116 |
| Raw GUI events (sessions, launches, dictations) | 2026-05-26 | 2026-09-18 | 116 |

2026-09-19 is a partial UTC day and is omitted from averages.

## What Sparkle actually counts

| Signal | What it is | Opt-out users? | Per device per day |
|---|---|---|---|
| `sparkle_check` distinct `session` | Daily hash of coarse IP + UA + UTC date + pepper | Yes | ~1 if auto-check is on and the 24h timer is due |
| GUI distinct `session` | Telemetry session UUID, new on process start | No | Often >1 (relaunches) |
| `app_launched` | Launch events | No | Relaunch after Sparkle install inflates this |
| `dictation_started` | Usage | No | Independent of update checks |

The hash **rotates daily** and includes the UA, so a same-day
0.8.6 → 0.8.7 upgrade is two fingerprints. Do not add days together.

## The cliff, in numbers

UTC Sparkle device-days vs GUI sessions vs launches vs dictations:

| UTC day | Sparkle devices | GUI sessions | App launches | Dictations |
|---|---:|---:|---:|---:|
| Sep 8 | 1,765 | 1,468 | 703 | 12,895 |
| Sep 9 (0.8.0 ships 19:48Z) | **1,780** | 1,441 | 664 | 14,102 |
| Sep 10 | 1,703 | **1,805** | **981** | **14,362** |
| Sep 11 | **1,049** | 1,545 | 785 | 13,108 |
| Sep 12 Sat | 927 | 778 | 369 | 7,520 |
| Sep 13 Sun | 861 | 827 | 375 | 8,010 |
| Sep 14 | 1,231 | 1,686 | 917 | 12,377 |
| Sep 15 | 1,374 | 1,855 | 1,031 | 11,667 |
| Sep 16 | 1,209 | **1,905** | **1,063** | 12,906 |
| Sep 17 | 1,231 | 1,876 | 1,024 | 11,991 |
| Sep 18 | 1,130 | 1,713 | 877 | 11,094 |

Until Sep 9, Sparkle sat **above** GUI sessions (~1.2×), which is the
expected opt-out-inclusive floor. From Sep 11 it sits **below** (~0.65×)
while launches and sessions are **at or above** early September. Real
churn does not invert those series overnight while dictations stay in
the 11–14k weekday band.

Friday-to-Friday dictations (Sep 4 13,510 → Sep 11 13,108 → Sep 18 11,094)
are a modest softening, not a 40% user loss. Sep 18 also includes the
0.8.6 hold-to-talk abort; treat that Friday as contaminated.

## Why Sparkle went down while the app got busier

### 1. Rapid Sparkle updates reset the 24h timer (primary)

Shipped GUI tags:

| Tag | Published (UTC) |
|---|---|
| v0.8.0 | 2026-09-09 19:48 |
| v0.8.1 | 2026-09-14 22:09 |
| v0.8.2 | 2026-09-16 00:13 |
| v0.8.3 | 2026-09-16 06:44 |
| v0.8.4 | 2026-09-17 06:26 |
| v0.8.5 | 2026-09-17 16:57 |
| v0.8.6 | 2026-09-18 10:02 |
| v0.8.7 | 2026-09-18 19:28 |

A client that accepts an update pings as the **old** version, installs,
relaunches as the **new** version, and typically does not ping again for
~24h. GUI telemetry starts a new session on that relaunch immediately.

0.7.x vs 0.8.x Sparkle device-days (re-queried):

| UTC day | 0.7.x | 0.8.x | All |
|---|---:|---:|---:|
| Sep 9 | 1,689 | 19 | 1,780 |
| Sep 11 | 534 | 457 | 1,049 |
| Sep 18 | 243 | 826 | 1,130 |

The 0.7.x installed base collapsed because it **updated**. It does not
show up as 0.8.x Sparkle the same day. Cloudflare HTTP Sparkle hits
moved with D1 (2,591 → 1,846 on Sep 11), so this is not an INSERT bug.

Canonical hole on 0.8.0's first full day:

| 2026-09-10 | Sparkle devices | GUI sessions |
|---|---:|---:|
| 0.7.3 | 1,444 | 1,162 |
| 0.8.0 | **163** | **536** |

0.8.0 was already in use (536 sessions) while almost nobody had reached
the next Sparkle check as 0.8.0. By Sep 14 the same version had recovered
to 820 Sparkle vs 927 GUI (0.88), closer to the old 1.2× ratio — until
0.8.1+ started another hole.

With a release every 12–24h, a large cohort is always in “just updated,
next check tomorrow.” Sparkle device-days stay depressed; launches go
up.

### 2. Leftover 0.7.3 is selected for auto-check off

0.7.3 Sparkle vs GUI:

| Day | Sparkle | GUI | Ratio |
|---|---:|---:|---:|
| Sep 8 | 1,660 | 1,332 | 1.25 |
| Sep 10 | 1,444 | 1,162 | 1.24 |
| Sep 11 | 512 | 828 | 0.62 |
| Sep 18 | 230 | 410 | 0.56 |

People who still run 0.7.3 a week after 0.8.0 are disproportionately
people who **never got the prompt** (auto-check off, or never launched
through a due check). They still generate GUI sessions. They do not
generate `sparkle_check` rows. That is survivorship, not 0.7.3 logging
breaking.

### 3. Same-day version upgrades split fingerprints

The daily device hash includes the UA, which includes `MacParakeet/<ver>`.
0.8.6 → 0.8.7 on the same UTC day is two Sparkle fingerprints, not one
human. This **inflates** Sparkle slightly on release days and does not
explain the 40% drop.

## Hypotheses that did not hold

**CDN cache skipping middleware.** Live appcast is
`cf-cache-status: DYNAMIC` with `max-age=0, must-revalidate`. Cached
edge responses would skip Pages middleware and undercount; they are not
what production is serving now. A cache incident that started Sep 11 and
never lifted would also have required a cache-rule change; none landed
in `functions/_middleware.ts` (last commit `b53776e`).

**UA filter dropping 0.8.x.** Middleware still matches
`^MacParakeet/<ver> Sparkle/`. Sparkle library on those days is 2.9.0
both before and after the cliff (`props.sparkle_ver`). 0.8.0 rows exist
in D1; they are just late relative to GUI sessions.

**Website sharing deploy killed logging.** Encrypted-share commits start
2026-09-11 23:30 PT = 2026-09-12 06:30 UTC, **after** the UTC Sep 11
calendar drop. Hourly Sparkle on Sep 10 19:00Z was still 115 hits; the
sharing merge cannot be the cause.

**Debug/dev guard.** `SparkleUpdateGuard` blocks `0.0.0` / `dev` / `*pdx*`
and active meeting recordings. That is not a new 0.8.0 behavior that
would zero production UAs.

**Hourly 20:00Z step as a global outage.** Sep 8 19:00→20:00Z was 109→96
(diurnal). Sep 10 19:00→20:00Z was 115→57 (steeper). 20:00Z is ~24h after
the 0.8.0 cut (19:48Z Sep 9), so the extra drop fits the first update
wave going quiet, mixed with evening UTC taper. It is not a D1 outage
(GUI events keep flowing).

## Full historical series

Sparkle logging starts **2026-05-26**. GUI rollups start **2026-03-26**.
Do not add Sparkle days together (hash rotates). Device-days below are
**daily unique checkers, averaged**, not unique humans.

### Monthly (weekday vs weekend)

Sparkle weekday mean uses only days with `sparkle_check` (May is 4
weekdays + 2 weekend days). GUI means use rollups for the whole month.

| Month | Sparkle weekday | Sparkle weekend | GUI weekday sessions | GUI weekday dictations | New users | New users / day |
|---|---:|---:|---:|---:|---:|---:|
| 2026-03 (26–31) | — | — | 36 | 108 | 54 | 9.0 |
| 2026-04 | — | — | 123 | 904 | 576 | 19.2 |
| 2026-05 | 253 | 223 | 287 | 2,214 | 810 | 26.1 |
| 2026-06 | 476 | 434 | 612 | 4,725 | 1,443 | 48.1 |
| 2026-07 | 827 | 623 | 892 | 6,949 | 1,588 | 51.2 |
| 2026-08 | 1,385 | 1,204 | 1,175 | 9,456 | 1,629 | 52.5 |
| 2026-09 (1–18 mixed) | 1,482 | 980 | 1,533 | 11,415 | 1,081 (through 17th) | **63.6** |

Sparkle weekday month-over-month:

| Month | Weekday Sparkle | vs prior month |
|---|---:|---|
| May (26–31 only) | 253 | — |
| June | 476 | **+89%** |
| July | 827 | **+74%** |
| August | 1,385 | **+68%** |
| September 1–10 (pre-cliff) | **1,691** | **+22% vs Aug** |
| September 11–18 (hole) | 1,204 | do not use |
| September 1–18 mixed | 1,482 | +7% vs Aug (artifact of mixing peak + hole) |

**September is not a stall.** Pre-cliff weekday Sparkle is still up 22%
on August. New-user **rate** in September (63.6/day) is the highest
month in the series. Weekday dictations and GUI sessions are also
all-time highs. The mixed-month +7% Sparkle figure is what you get if
you average 1,691 with 1,204.

Peak Sparkle day: **1,780 devices on 2026-09-09**. First 1k weekday:
2026-07-28 (1,008). First 1.5k weekday: 2026-08-25 (1,541).

### ISO week, weekday averages

`sp` = Sparkle devices. `se` / `di` = GUI rollup sessions / dictations.
`nu` = new_users for the whole ISO week (including weekend). Sparkle
starts W22.

| ISO week | Ending | Sparkle wd | GUI sessions wd | Dictations wd | New users |
|---|---|---:|---:|---:|---:|
| 2026-W13 | Mar 29 | — | 56 | 131 | 51 |
| 2026-W14 | Apr 5 | — | 15 | 60 | 35 |
| 2026-W15 | Apr 12 | — | 101 | 757 | 153 |
| 2026-W16 | Apr 19 | — | 136 | 972 | 136 |
| 2026-W17 | Apr 26 | — | 160 | 1,273 | 165 |
| 2026-W18 | May 3 | — | 162 | 1,146 | 134 |
| 2026-W19 | May 10 | — | 228 | 1,855 | 177 |
| 2026-W20 | May 17 | — | 275 | 2,162 | 188 |
| 2026-W21 | May 24 | — | 334 | 2,333 | 187 |
| 2026-W22 | May 31 | 253 | 344 | 2,748 | 214 |
| 2026-W23 | Jun 7 | 336 | 503 | 4,096 | 351 |
| 2026-W24 | Jun 14 | 442 | 652 | 4,830 | 421 |
| 2026-W25 | Jun 21 | 517 | 626 | 5,377 | 296 |
| 2026-W26 | Jun 28 | 528 | 646 | 4,621 | 284 |
| 2026-W27 | Jul 5 | 720 | 644 | 4,843 | 281 |
| 2026-W28 | Jul 12 | 804 | 799 | 6,425 | 344 |
| 2026-W29 | Jul 19 | 701 | 971 | 6,280 | 421 |
| 2026-W30 | Jul 26 | 810 | 951 | 7,931 | 316 |
| 2026-W31 | Aug 2 | 1,040 | 1,001 | 8,352 | 398 |
| 2026-W32 | Aug 9 | 1,196 | 1,069 | 8,684 | 385 |
| 2026-W33 | Aug 16 | 1,347 | 1,138 | 9,062 | 370 |
| 2026-W34 | Aug 23 | 1,434 | 1,193 | 9,520 | 350 |
| 2026-W35 | Aug 30 | 1,535 | 1,266 | 10,543 | 362 |
| 2026-W36 | Sep 6 | **1,626** | 1,362 | 11,206 | 436 |
| 2026-W37 | Sep 13 | 1,596 | 1,470 | **11,805** | 428 |
| 2026-W38 | Sep 20 | **1,235** | **1,781** | 10,718 | 298 (partial week) |

W37 still looks healthy on Sparkle because Mon–Thu were the 1,680–1,780
peak; Friday Sep 11 is the only hole day in that average. W38 is the
first week where Sparkle and GUI **invert** (1,235 Sparkle vs 1,781
sessions) while dictations stay ~11k. That is the release-train
signature, not a demand crash.

W29 Sparkle dip (701) vs rising sessions (971) is a smaller historical
rhyme — likely the 0.7.3 ship week (tag 2026-07-17) plus a weekend
collapse (Jul 11–12, 18–19 around 500). Worth a footnote, not this
incident.

### Sparkle / GUI session ratio (weekday monthly)

| Month | Ratio (Sparkle devices / GUI sessions) |
|---|---:|
| May | 0.88 |
| June | 0.78 |
| July | 0.93 |
| August | **1.18** |
| September mixed | 0.96 |
| September 1–10 | ~1.24 on event-level GUI |
| September 11–18 | ~0.65 on event-level GUI |

August is the cleanest “Sparkle as DAU floor” month: more Sparkle
devices than GUI sessions, as expected with telemetry-off users.

### Daily Sparkle (complete)

Every UTC day with at least one MacParakeet Sparkle UA. 2026-09-19 is
incomplete.

| Day | Dow | Devices | Hits |
|---|---|---:|---:|
| 2026-05-26 | Tue | 239 | 390 |
| 2026-05-27 | Wed | 260 | 415 |
| 2026-05-28 | Thu | 250 | 486 |
| 2026-05-29 | Fri | 261 | 558 |
| 2026-05-30 | Sat | 241 | 512 |
| 2026-05-31 | Sun | 204 | 454 |
| 2026-06-01 | Mon | 272 | 539 |
| 2026-06-02 | Tue | 339 | 664 |
| 2026-06-03 | Wed | 356 | 707 |
| 2026-06-04 | Thu | 383 | 738 |
| 2026-06-05 | Fri | 329 | 622 |
| 2026-06-06 | Sat | 314 | 536 |
| 2026-06-07 | Sun | 348 | 590 |
| 2026-06-08 | Mon | 424 | 820 |
| 2026-06-09 | Tue | 474 | 913 |
| 2026-06-10 | Wed | 472 | 867 |
| 2026-06-11 | Thu | 418 | 789 |
| 2026-06-12 | Fri | 420 | 766 |
| 2026-06-13 | Sat | 388 | 734 |
| 2026-06-14 | Sun | 403 | 732 |
| 2026-06-15 | Mon | 550 | 893 |
| 2026-06-16 | Tue | 557 | 952 |
| 2026-06-17 | Wed | 489 | 819 |
| 2026-06-18 | Thu | 521 | 869 |
| 2026-06-19 | Fri | 468 | 764 |
| 2026-06-20 | Sat | 483 | 853 |
| 2026-06-21 | Sun | 479 | 840 |
| 2026-06-22 | Mon | 544 | 955 |
| 2026-06-23 | Tue | 450 | 786 |
| 2026-06-24 | Wed | 488 | 836 |
| 2026-06-25 | Thu | 587 | 977 |
| 2026-06-26 | Fri | 571 | 952 |
| 2026-06-27 | Sat | 532 | 941 |
| 2026-06-28 | Sun | 527 | 980 |
| 2026-06-29 | Mon | 657 | 1,096 |
| 2026-06-30 | Tue | 701 | 1,173 |
| 2026-07-01 | Wed | 732 | 1,285 |
| 2026-07-02 | Thu | 758 | 1,307 |
| 2026-07-03 | Fri | 750 | 1,230 |
| 2026-07-04 | Sat | 681 | 1,058 |
| 2026-07-05 | Sun | 693 | 1,081 |
| 2026-07-06 | Mon | 774 | 1,178 |
| 2026-07-07 | Tue | 818 | 1,381 |
| 2026-07-08 | Wed | 832 | 1,368 |
| 2026-07-09 | Thu | 921 | 1,484 |
| 2026-07-10 | Fri | 673 | 1,163 |
| 2026-07-11 | Sat | 529 | 972 |
| 2026-07-12 | Sun | 520 | 992 |
| 2026-07-13 | Mon | 691 | 1,118 |
| 2026-07-14 | Tue | 641 | 1,098 |
| 2026-07-15 | Wed | 705 | 1,170 |
| 2026-07-16 | Thu | 724 | 1,157 |
| 2026-07-17 | Fri | 744 | 1,170 |
| 2026-07-18 | Sat | 503 | 1,001 |
| 2026-07-19 | Sun | 493 | 1,106 |
| 2026-07-20 | Mon | 667 | 1,312 |
| 2026-07-21 | Tue | 795 | 1,396 |
| 2026-07-22 | Wed | 837 | 1,385 |
| 2026-07-23 | Thu | 882 | 1,418 |
| 2026-07-24 | Fri | 869 | 1,424 |
| 2026-07-25 | Sat | 783 | 1,311 |
| 2026-07-26 | Sun | 780 | 1,289 |
| 2026-07-27 | Mon | 963 | 1,542 |
| 2026-07-28 | Tue | 1,008 | 1,656 |
| 2026-07-29 | Wed | 1,053 | 1,698 |
| 2026-07-30 | Thu | 1,085 | 1,699 |
| 2026-07-31 | Fri | 1,093 | 1,691 |
| 2026-08-01 | Sat | 957 | 1,454 |
| 2026-08-02 | Sun | 985 | 1,502 |
| 2026-08-03 | Mon | 1,140 | 1,725 |
| 2026-08-04 | Tue | 1,168 | 1,821 |
| 2026-08-05 | Wed | 1,226 | 1,842 |
| 2026-08-06 | Thu | 1,214 | 1,920 |
| 2026-08-07 | Fri | 1,233 | 1,832 |
| 2026-08-08 | Sat | 1,114 | 1,516 |
| 2026-08-09 | Sun | 1,124 | 1,622 |
| 2026-08-10 | Mon | 1,298 | 1,971 |
| 2026-08-11 | Tue | 1,349 | 2,027 |
| 2026-08-12 | Wed | 1,380 | 2,047 |
| 2026-08-13 | Thu | 1,369 | 2,054 |
| 2026-08-14 | Fri | 1,337 | 2,036 |
| 2026-08-15 | Sat | 1,221 | 1,803 |
| 2026-08-16 | Sun | 1,224 | 1,835 |
| 2026-08-17 | Mon | 1,372 | 2,091 |
| 2026-08-18 | Tue | 1,442 | 2,171 |
| 2026-08-19 | Wed | 1,454 | 2,199 |
| 2026-08-20 | Thu | 1,481 | 2,287 |
| 2026-08-21 | Fri | 1,421 | 2,201 |
| 2026-08-22 | Sat | 1,304 | 1,959 |
| 2026-08-23 | Sun | 1,337 | 2,042 |
| 2026-08-24 | Mon | 1,494 | 2,190 |
| 2026-08-25 | Tue | 1,541 | 2,250 |
| 2026-08-26 | Wed | 1,530 | 2,197 |
| 2026-08-27 | Thu | 1,580 | 2,328 |
| 2026-08-28 | Fri | 1,530 | 2,301 |
| 2026-08-29 | Sat | 1,388 | 2,092 |
| 2026-08-30 | Sun | 1,382 | 2,111 |
| 2026-08-31 | Mon | 1,531 | 2,326 |
| 2026-09-01 | Tue | 1,643 | 2,504 |
| 2026-09-02 | Wed | 1,655 | 2,421 |
| 2026-09-03 | Thu | 1,648 | 2,396 |
| 2026-09-04 | Fri | 1,653 | 2,323 |
| 2026-09-05 | Sat | 1,554 | 2,127 |
| 2026-09-06 | Sun | 1,521 | 2,051 |
| 2026-09-07 | Mon | 1,681 | 2,231 |
| 2026-09-08 | Tue | 1,765 | 2,410 |
| 2026-09-09 | Wed | **1,780** | 2,428 |
| 2026-09-10 | Thu | 1,703 | 2,372 |
| 2026-09-11 | Fri | **1,049** | 1,694 |
| 2026-09-12 | Sat | 927 | 1,483 |
| 2026-09-13 | Sun | 861 | 1,523 |
| 2026-09-14 | Mon | 1,231 | 1,869 |
| 2026-09-15 | Tue | 1,374 | 2,031 |
| 2026-09-16 | Wed | 1,209 | 1,802 |
| 2026-09-17 | Thu | 1,231 | 1,856 |
| 2026-09-18 | Fri | 1,130 | 1,788 |
| 2026-09-19 | Sat | 36 | 56 |

GUI sessions, dictations, launches, and new_users for the same days are
in the CSV (rollups through Sep 17; raw events from May 26).

## How to query

Website checkout, production D1:

```bash
# UTC day Sparkle floor
npx wrangler d1 execute macparakeet-telemetry --remote --json --command \
  "SELECT substr(ts,1,10) AS day, COUNT(*) AS hits, COUNT(DISTINCT session) AS devices
   FROM events WHERE event='sparkle_check' AND ts>='2026-09-01T00:00:00Z'
   GROUP BY 1 ORDER BY 1"

# Do not trend Sparkle alone during a release train. Pair with:
#   COUNT(DISTINCT session) FILTER (WHERE surface='gui')
#   COUNT(*) FILTER (WHERE event='dictation_started' AND surface='gui')
```

Live cache posture:

```bash
curl -sI -A 'MacParakeet/0.8.7 Sparkle/2.9.0' https://macparakeet.com/appcast.xml
# expect cf-cache-status: DYNAMIC
```

## What to use for DAU

- **Steady-state weekday (no Sparkle train):** Sparkle distinct
  fingerprints, haircut ~10% for IP/VPN and same-day UA changes.
  Pre-0.8.0 that was **~1.6–1.8k**.
- **During a Sparkle train:** Sparkle is a **lower bound only**. Cross-check
  GUI sessions (inflated by relaunches) and dictations (usage). Current
  working range **~1.5–1.8k devices**, not 1.1k.
- **Never:** sum of daily fingerprints (hash rotates). Never treat
  public `/api/stats` `today.sessions` as unique humans.

## Follow-ups (not done here)

1. After 0.8.x settles (several days with no GUI tag), re-read Sparkle
   weekday device-days. If they return toward ~1.6–1.8k, this diagnosis
   is confirmed. Cloudflare GraphQL Sparkle hits should recover in
   parallel (Sep 9 = 2,591 requests; Sep 11 = 1,846).
2. Keep appcast `DYNAMIC` / `max-age=0`. A future cache rule on
   `/appcast.xml` would silently destroy the DAU proxy.
3. Optional: log a breadcrumb from the app when Sparkle **performs** a
   check (opt-in only) so the 24h hole is visible in GUI telemetry too.
4. Optional: dashboard annotation “Sparkle DAU unreliable during rapid
   releases.”
5. `audio_engine_lifecycle` hot loop on GB 0.8.4 (see landscape note).
6. Daily briefing should label Sparkle a **floor** and annotate release
   days rather than WoW-alerting it. Spec:
   [`docs/design/2026-09-18-daily-telemetry-observability.md`](../design/2026-09-18-daily-telemetry-observability.md).

Website operator notes live in the website repo at `docs/sparkle-dau.md`
(same findings, query-focused).

Opt-out, country, product mix, sessions, and Cloudflare HTTP analytics
(independent corroboration of the Sep 11 hole: `/appcast.xml` Sparkle
hits 2,591 → 1,846 while D1 insert rate stayed ~91–95%) are in
[2026-09-18-telemetry-user-landscape.md](./2026-09-18-telemetry-user-landscape.md).
