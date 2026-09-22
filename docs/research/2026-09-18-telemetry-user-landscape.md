# Telemetry user landscape (Cloudflare D1 + HTTP analytics)

Date: 2026-09-18 (Pacific). Queries 2026-09-19 01:20–02:10 UTC, then a
fresh-eye / code-meaning pass the same evening.
Status: **read-only**. Companion to
[2026-09-18-sparkle-dau-measurement.md](./2026-09-18-sparkle-dau-measurement.md)
and [2026-09-18-sparkle-dau-daily.csv](./2026-09-18-sparkle-dau-daily.csv).
Sources: live D1 `macparakeet-telemetry`
(`7372263e-6a0b-4c70-8188-8f1d6d16bf31`) and Cloudflare GraphQL
`httpRequestsAdaptiveGroups` for zone `macparakeet.com`
(`4183d6a922545fb96269e3c24d1611a2`). No production writes.

`new_users` in `stats_daily_rollups` is **`onboarding_completed` count**,
not unique humans. GUI `session` is a process UUID (`ts` = client
ISO-8601 **GMT**). Sparkle `session` is a **daily** device hash
(`ts` = server now). There is no join across days by design
([spec/contracts/telemetry-v1.md](../../spec/contracts/telemetry-v1.md)).

## Verified against the Sparkle note

Re-queried live:

| Claim in the Sparkle note | Re-query | Status |
|---|---|---|
| Sep 9 Sparkle devices 1,780 | `COUNT(DISTINCT session)` `sparkle_check` = **1,780**; hits **2,428** | match |
| Sep 11 Sparkle 1,049 / Sep 18 1,130 | D1 hits 1,694 / 1,788 | match |
| Sep 1–10 weekday Sparkle mean 1,691 | recomputed from CSV | match |
| GUI rollups 2026-03-26 … 2026-09-17 | 176 closed days | match |
| `sparkle_check` from 2026-05-26 | min ts still that day | match |
| Sep new users/day ~63.6 | rollup onboarding ~1,170 / 18 days = **~65** (weekday **73.9**) | match (rounding) |
| Lifetime rollup (Mar 26–Sep 18) | **7,270** onboard, **860,215** dictations, **26,663** meetings, **107,865** session-days (sum of daily distinct sessions, **not** unique humans) | new |
| Public `/api/stats` `all_time.total_sessions` | **55,386** allowlisted distinct GUI process IDs ever | new |
| Sep 9 raw GUI distinct sessions | **1,441** (`surface='gui'`) | re-verified |

Rollup GUI sessions are **below** raw `surface='gui'` (published-version
allowlist). The cliff table used raw events on purpose. `107,865` is
**session-days**. Unique allowlisted processes ever are **55,386**.

## Cloudflare HTTP vs D1 (independent Sparkle series)

GraphQL filter: path `/appcast.xml`, `userAgent LIKE %Sparkle%`,
`requestSource=eyeball`. `count` is requests (sampleInterval ≈ 1.00–1.01,
so nearly unsampled). This is **hits**, not unique devices.

| UTC day | CF Sparkle appcast hits | D1 `sparkle_check` hits | D1 devices | D1 / CF hits |
|---|---:|---:|---:|---:|
| Sep 8 | 2,533 | 2,410 | 1,765 | 95% |
| Sep 9 | **2,591** | **2,428** | **1,780** | 94% |
| Sep 10 | 2,514 | 2,372 | 1,703 | 94% |
| Sep 11 | **1,846** | **1,694** | **1,049** | 92% |
| Sep 18 | 1,972 | 1,788 | 1,130 | 91% |

The Sep 11 hole is in **edge HTTP logs**, not a D1 INSERT bug. The
**91–95%** figure is **D1 rows / CF request hits** (2,428 / 2,591 on
Sep 9), not devices / hits. Unique devices fall harder than hits
(1,780 → 1,049 = −41% vs hits −29%) because chatty retries keep
hitting after the timer hole starts. Do not divide 1,780 by 2,591.

Sep 9 CF country hits (not unique): US 797, DE 279, GB 153, BE 85, AU 85,
FR 83, CA 79, NL 70. Rank order matches D1 device-days (US 529 / DE 201 /
GB 96).

## Growth (opt-in GUI rollups)

Closed UTC days through 2026-09-17. Dictations = `dictation_completed`.
Onboarding = `new_users` column.

| Month | Days | Avg sessions | Avg dictations | Avg onboard | Dictation hours | Meetings |
|---|---:|---:|---:|---:|---:|---:|
| 2026-04 | 30 | 111 | 827 | 19.2 | 151 | 1 |
| 2026-05 | 31 | 251 | 2,060 | 26.1 | 353 | 1,033 |
| 2026-06 | 30 | 542 | 4,294 | 48.1 | 836 | 3,361 |
| 2026-07 | 31 | 791 | 6,271 | 51.2 | 1,290 | 6,074 |
| 2026-08 | 31 | 999 | 8,339 | 52.5 | 1,689 | 8,757 |
| 2026-09 | 18 | **1,381** | **10,512** | **65.0** | 1,379 | 7,437 |

Weekday-only (Mon–Fri) averages:

| Month | Sessions | Dictations | Onboard | Meetings |
|---|---:|---:|---:|---:|
| Aug | 1,175 | 9,456 | 60.6 | 396 |
| Sep | **1,554** | **11,323** | **73.9** | **511** |

**Usage is still compounding through mid-September.** Sessions +32% vs
August weekdays, dictations +20%, onboarding +22%, meetings +29%. The
Sparkle device-day series is the one that broke, not the product.

Weekend dictation is real (~7.6k Sat/Sun in Sep vs 11.3k weekday) — this
is not a pure office-hours toy.

## Opt-out

Telemetry is **opt-out, default on**. After disable, only
`telemetry_opted_out` is POSTed. Sparkle still fires.

### Flow

| Window | Events | Distinct sessions |
|---|---:|---:|
| All D1 rows (from 2026-03-14) | **1,910** | **1,894** |
| Sep 1–18 | 271 | 269 |

Sep daily flow is **6–27/day**, weekend lower. **No spike on Sep 11**
(17). Lifetime 1,894 / public `all_time.total_sessions` 55,386 ≈ **3.4% of
allowlisted GUI process IDs ever**, not of current users and not of
the 107k session-day sum. It is a **flow**; opted-out devices vanish
from GUI. Telemetry **collection defaults to enabled**
(`AppPreferences.telemetryEnabled` defaults `true`). Debug / `0.0.0` /
`dev-*` builds are transport-ineligible unless `MACPARAKEET_TELEMETRY=1`.

Opt-out event countries (lifetime) follow usage: US 555, DE 266, GB 116,
FR 79, NL 71, AU 66, IN 60, CA 60. Not a Germany-only privacy revolt.

### Stock (Sparkle-visible, GUI-invisible)

UTC 2026-09-09, one day so hashes do not rotate:

| | Sparkle devices | GUI sessions | App launches |
|---|---:|---:|---:|
| Global | 1,780 | ~1,441 | 664 |

- Lower bound: `(1780 − 1441) / 1780 ≈ **19%**` if every opt-in device
  has exactly one GUI session. Relaunches make unique opt-in smaller,
  so true invisible share is **≥ ~19%**.
- Do **not** use launches (664) as unique opt-in. Menu bar already
  running still Sparkles and does not fire `app_launched`.

Working estimate: **~20–35% of Sparkle devices are invisible to GUI**
(opt-out + allowlist + failed POSTs). Call it **~1 in 4**.

People who disabled **both** auto-check and telemetry are in neither
series.

## Country

### Sep 1–17 GUI session-days (`stats_daily_dimensions` kind=`country`)

Allowlisted GUI only. Session-days, not humans.

| CC | Session-days | Share of top-10 sum |
|---|---:|---|
| US | 6,184 | ~29% |
| DE | 2,599 | ~12% |
| GB | 1,178 | ~6% |
| IN | 1,044 | ~5% |
| NL | 1,031 | ~5% |
| FR | 990 | ~5% |
| AU | 850 | ~4% |
| CA | 835 | ~4% |
| PL | 680 | ~3% |
| ES | 670 | ~3% |

Monthly GUI session-days (selected): US 995 → 2,360 → 4,524 → 7,051 →
8,765 → 6,614 in 18 Sep days (~367/day vs Aug ~283/day, **+30%**).
DE Aug 3,416 / 31 ≈ 110/day vs Sep 2,805 / 18 ≈ 156/day (**+42%**).
India and NL grew into the top five; they were not there in April.

### UTC 2026-09-09 Sparkle vs GUI (best DAU-shaped day)

| CC | Sparkle devices | GUI sessions | Launches | Dictations started | Sparkle / GUI |
|---|---:|---:|---:|---:|---:|
| US | 529 | 409 | 167 | 3,378 | 1.29 |
| DE | 201 | 151 | 59 | 2,058 | 1.33 |
| GB | 96 | 60 | 20 | 530 | 1.60 |
| FR | 72 | 62 | 29 | 712 | 1.16 |
| NL | 66 | 61 | 14 | 973 | 1.08 |
| AU | 66 | 52 | 21 | 632 | 1.27 |
| IN | 62 | 63 | 31 | 555 | 0.98 |
| CA | 55 | 50 | 17 | 313 | 1.10 |
| PL | 54 | 49 | 22 | 599 | 1.10 |
| ES | 46 | 44 | 32 | 291 | 1.05 |
| BE | 36 | 24 | 11 | 264 | 1.50 |
| JP | 18 | 17 | 9 | 27 | 1.06 |
| CZ | 16 | 12 | 3 | 345 | 1.33 |

US ~30% of Sparkle that day. Intensity: NL ≈ 16 dictations/session, DE
≈ 14, US ≈ 8, JP ≈ 1.6. India ratio ~1.0 (high GUI compliance). GB 1.60
is the chattiest large opt-out gap.

### Sep 18 Sparkle devices (firehose-depressed)

US 277 (52% of Sep 9), DE 142 (71%), FR 60 (83%), NL 56 (85%), GB 66
(69%), AU 39 (59%), IN 35 (56%). **US and AU dropped more than core EU**,
consistent with faster 0.8.x uptake resetting the 24h last-check, not
country-specific churn.

## Product behavior

Window unless noted: GUI `2026-09-11T00:00:00Z` → query time.

### Dictation is the product

80,103 completed / 88,984 started ≈ **90%**. Mean completed dictation:
**28.4s, 56.8 words** (4.55M words in the window).

**Mode:** hold 51,945 (65%) from 1,693 sessions; persistent 28,171 (35%)
from 1,411 sessions. Both are first-class. Country mix is not uniform:
AU is ~91% hold; **PL persistent is 3,738 dictations from 45 sessions**
(a power-user cluster, ~83/session, not “Poland as a culture”). DE is
nearly even (6,100 hold / 5,414 persistent).

**Trigger:** hotkey 87,102 (98%), pill_click 1,886, menu_bar 8.

**Engine (completed):** Parakeet v3 60,997 (76%); Whisper large-v3 turbo
8,583 (11%); Parakeet v2 4,853; unified 3,519; Nemotron ~1k; Cohere
~125. Default stack is winning; Whisper is the real alternative, not
Nemotron/Cohere.

**OS locale (`Locale.current` on the client, not inferred):** on Sep 9
every GUI session was `en*` (1,441/1,441). All of September: the only
non-English OS locale in D1 is **`fr_FR` (38 sessions / 157 events)**.
Germany shows up as `en_DE`, India as `en_IN`, Russia as `en_RU`. This
is the real Mac language, not just the ASR tag. The opt-in population
is **English-OS users worldwide**. That also explains dictation
`language=en` in DE/NL/PL (DE 10,768 en / 678 de since Sep 11). French
is the only market with a visible native-OS minority.

**Where it lands (`app_category`):** other 33,427, browser 15,145,
terminal 11,498, code 11,212, messaging 5,949, notes 1,356, docs 674,
email 607. Developer + browser + messenger. Docs/email are small.

**Intensity (UTC Sep 16, sessions with ≥1 completed dictation):**

| Dictations that day | Sessions | Completions |
|---|---:|---:|
| 1 | 142 | 142 |
| 2–5 | 211 | 650 |
| 6–20 | 195 | 2,182 |
| 21–50 | 105 | 3,334 |
| 51–100 | 35 | 2,469 |
| 101+ | 19 | 2,833 |

707 dictating sessions; **19 sessions (2.7%) produced 24% of
dictations**. 51+ = 54 sessions ≈ 46% of completions. Classic
power-user product. DAU without intensity understates value.

### Meetings, files, LLM

Same-process overlap Sep 11+ (sessions that completed at least one
capture event):

| | Sessions |
|---|---:|
| Any capture | 4,241 |
| Dictation | 2,648 |
| Meeting recording | 1,440 |
| Transcription completed | 2,042 |
| Dictation ∧ meeting | 380 |
| Meeting ∧ transcription | 1,389 |
| All three | 374 |

Meetings almost always emit `transcription_completed` with
`source=meeting` (1,389 / 1,440). Only **26%** of meeting processes also
dictated that process. Dictation-only remains the majority.

`transcription_completed` sources: meeting 3,434, drag_drop 1,122, file
902, youtube 265, podcast 31. File/URL ingest is real but smaller.
Diarization 5,444 ≈ meeting+file work, not dictation.

LLM/transform: 4,418 formatter + 3,404 prompt + 391 chat + 173
transform, **728 distinct sessions** of 7,625 GUI sessions in Sep 11–18
(~10% of processes). Chat and Transforms are niche; formatter/prompt
are the LLM that matters.

Calendar auto-start 570 vs 3,346 meeting completions — used, minority.

### Activation (correct KPI)

Do **not** divide rolling `first_dictation_completed` by
`onboarding_completed` and call the gap “never activate.” That event
ships 2026-05-23, is one-shot per install, and is not retroactive. The
governing audit is
[2026-06-03-activation-metrics-cohort-caveats.md](../audits/2026-06-03-activation-metrics-cohort-caveats.md).

**T0** = `dictation_completed` in the **same process UUID** as
`onboarding_completed`.

| Month | Onboard sessions | T0 try (`dictation_started`) | T0 success | T0 success rate |
|---|---:|---:|---:|---:|
| Jun | 1,460 | 781 | 660 | **45.2%** |
| Jul | 1,624 | 786 | 660 | **40.6%** |
| Aug | 1,642 | 789 | 640 | **39.0%** |
| Sep 1–18 | 1,177 | 501 | 386 | **32.8%** |

Public `/api/stats` 30d window agrees: T0 try **43.4%**, T0 success
**34.2%**, onboarding abandon **38.7%**. The June ~45–48% headline has
**decayed**. Same-session `first_dictation` in Sep (378) ≈ T0 success
(386); the other 675−378 first-dicts happened after relaunch.

T0 try falling (53% in Jun → 43% in Sep) means more completers never
even start a dictation in that process — not only that STT fails.

`first_dictation` activation windows (install-scoped, Sep): under_1m
143, under_1h 279, under_1d 92, under_1w 68, over_1w 79. Among people
who *do* emit the milestone, **62% do it within an hour**. That is a
different population than T0.

### Onboarding funnel (Sep)

`onboarding_step` sessions: welcome viewed **1,888** → ready completed
**1,179** (62% finish; 38% abandon, matching public stats).
`speech_model` `engine_failed` **330 sessions** / `engine_ready` 1,362.
Speech model is still the largest measured setup blocker (same as the
July onboarding audit).

### Permissions (Sep)

| Permission | Prompted | Granted | Denied |
|---|---:|---:|---:|
| microphone | 1,341 | 1,243 | 107 |
| accessibility | 850 | 670 | 24 |
| screen_recording | 857 | **19** | **606** |
| calendar | 171 | 146 | 24 |

Mic consent is fine. **Screen recording is hostile** (meetings). That
is a different funnel from dictation T0.

### Meetings

Since Sep 11: started 3,446, completed 3,347, failed 198, cancelled 75.
**~97% of starts complete.** Calendar auto-start 570 vs 3,346
completions — used, minority. Auto-stop: 374 proposed, 293 confirmed,
11 vetoed (people mostly accept).

### Failures and crashes

`dictation_failed` since Sep 11: CancellationError 1,140,
`inputUnavailable` 837, silent_input 96, engine_start_failed 19, STT
17, mic denied 10.

Current `DictationService` maps `CancellationError` on start/stop/undo
to **cancelled**, not `dictation_failed`. The CancellationError pile is
**1,097 / 1,140 on 0.7.3** (plus a handful of 0.6.x / 0.0.0). **No
0.8.x rows.** Do not treat that bucket as an 0.8.6 PTT symptom.

Crashes since Sep 11, **with GUI session denominators**:

| app_ver | GUI sessions | crash sessions | rate |
|---|---:|---:|---:|
| 0.7.3 | 2,390 | 102 | 4.3% |
| 0.8.0 | 2,524 | 112 | **4.4%** |
| 0.8.1 | 780 | 18 | 2.3% |
| 0.8.4 | 319 | 9 | 2.8% |
| 0.8.5 | 318 | 4 | 1.3% |
| 0.8.6 | 216 | 2 | 0.9% |
| 0.8.7 | 48 | 2 | n small |

0.8.0 is **not uniquely crashy vs 0.7.3** once you use a rate. Of the
112 0.8.0 crashes, **71 are macOS 26.6** (Tahoe), 10 on 26.5, 9 on 27.0.

`audio_engine_lifecycle` is a **start/stop observability snapshot**,
not a product event. Fast prepare/stop are suppressed; **start
publishes a terminal**. Since Sep 11 the bulk is native
`operation=start outcome=success` (**34,264** events / 1,326 sessions)
— expected volume, one per engine start. `outcome=slow` is rare (83
start-slow). `scope=shared_subscription_queue` is almost unused (22
rows). The GB 0.8.4 anomaly is **two sessions with >500 events**
(16,173 of 18,380 0.8.4 lifecycle rows, max 12,502 **start/success**).
That is a start loop, not a fleet of slow checkpoints.

Raw GUI includes some `app_ver=0.0.0` (debug / `MACPARAKEET_TELEMETRY=1`).
Not one machine: Sep has US, BE, ES, CO, IN, … Rollups and `/api/stats`
drop `0.0.0`. Prefer that filter on raw cuts.

### Settings people actually change (Sep)

microphone_selection 684, menu_bar_only 454, calendar_auto_start_mode
404, calendar_included_calendars 380, launch_at_login 368,
dictation_insertion_style 351, hide_pill 341, live_dictation_preview
205, voice_return 156, instant_dictation 117, parakeet_model_variant
107. Capture chrome > model picker.

### Hardware (Sep 9 GUI sessions)

M4 190, M4 Pro 177, M1 142, M5 131, M1 Pro 122, M5 Pro 102, M2 102, …
M1 is still a large cohort. M5 is already material. Do not drop M1.

### CLI

Sep 1–19: **38,511 `cli_operation` events = 38,511 sessions** (one UUID
per invocation). Since Sep 11, command mix: `meetings` 5,156,
`transcribe` 708, `help` 483, export/llm/health/history/models ~100–160
each. This is automation (and/or a few polling agents), not 38k humans.
Do not add CLI sessions to DAU.

### Licensing

`license_activated` / `trial_*` / `purchase_started` / `restore_*` are
allowlisted and marked immediate-flush. **`trialStarted` / `purchaseStarted`
have no product send site** (enum only). `licenseActivated` fires from
Settings paste. **Zero rows in D1, all time.** Conversion is unobservable.

## Interesting sessions (anonymized)

GUI UUID lasts for the **process**. Menu bar left up overnight **is** a
continuous session. No join across relaunch.

Highest-volume sessions 2026-09-16–18:

| Session (prefix) | CC | App | Events | Dictations done | Span |
|---|---|---|---:|---:|---|
| `AD29DD9A…` | GB | 0.8.4 | **12,616** | 23 | ~12h Sep 17 |
| `79769346…` | GB | 0.8.4 | 3,705 | 7 | ~10h Sep 18 |
| `39668CA9…` | TH | 0.7.3 | 1,678 | **546** | ~2.5 days |
| `E0D83C9A…` | AU | 0.8.2 | 1,657 | **404** | ~2.4 days |
| `2F1FBB0F…` | KZ | 0.7.3 | 1,479 | **481** | ~2.5 days |
| `ABDD4FDF…` | MA | 0.7.3 | 980 | 251 + **10 meetings** | ~2.6 days |
| `86371AA3…` | MX | 0.8.3 | 923 | 0 / **148 transcriptions** | ~22h |
| `3C765583…` | BR | 0.8.3 | 867 | 0 / **139 transcriptions** | 3h |

GB 0.8.4 rows are **lifecycle spam** (see above). TH/KZ/AU/MA are the
real always-on dictators. MX/BR are batch transcribers.

`app_quit.session_duration_seconds` multi-million-second outliers are
clock junk or never-quit menu bar. Do not use max duration.

## Version mix (explains the Sparkle hole)

Sep 9 Sparkle devices were **almost all 0.7.x** (1,689 / 1,780) with
only **19** on 0.8.x (0.8.0 had shipped hours earlier). Then:

| UTC day | 0.7.x devices | 0.8.x devices | All Sparkle | Checks / device |
|---|---:|---:|---:|---:|
| Sep 9 | 1,689 | 19 | 1,780 | 1.36 |
| Sep 10 | 1,469 | 163 | 1,703 | 1.39 |
| Sep 11 | **534** | 457 | 1,049 | 1.61 |
| Sep 15 | 373 | 933 | 1,374 | 1.48 |
| Sep 18 | 243 | 826 | 1,130 | 1.58 |

The 0.7.x floor fell by **1,155 devices in two days** because they
accepted 0.8.x. They do not reappear as 0.8 Sparkle the same day: the
update resets last-check, and the UA-version change also splits the
daily hash. 0.8.x Sparkle on Sep 18 is still only 826, not ~1,500,
because 0.8.1–0.8.7 keep punching new 24h holes. Leftover 0.7.x (243)
is the auto-check-off / never-relaunch tail — which includes some of
the heaviest never-quit dictators (TH/KZ/MA on 0.7.3).

Sep 18 version spray: 0.7.3 230, 0.8.0 201, 0.8.4 183, 0.8.3 139,
0.8.5 111, 0.8.6 76, 0.8.7 8, plus 0.6.x.

## Current DAU opinion (unchanged, now with HTTP corroboration)

Best weekday unique-device guess remains **~1,500–1,800** (Sep 9 Sparkle
1,780 as last clean floor; GUI usage still above August). Current
Sparkle ~1,130 is a **depressed floor**. Opt-in GUI weekday sessions
~1,550 (rollup) plus ~20–35% Sparkle-only. Do not quote Sep 11–18
Sparkle as churn.

## What this DB cannot answer

- N-day retention, D1/D7, returning-user graphs.
- Identity across relaunch or Sparkle days.
- “How many humans ever.”
- Paid conversion (trial/purchase unwired; license paste unused in D1).

## How the telemetry actually works (code)

- GUI POST `/api/telemetry`. Session UUID is created in
  `TelemetryService.init` and lives for that process. `ts` is
  **ISO-8601 GMT** from the client clock. Country is **CF-IPCountry** at
  ingest, not the client.
- Sparkle `sparkle_check` is **website middleware**, not the app.
  `session` is SHA-256 of coarsened IP + **full UA (includes version)**
  + UTC date + pepper. `ts` is **server** `now`. `surface` is NULL
  (excluded from GUI rollups). Failed INSERT is silent.
- Consent: default **on**. Opt-out flushes `telemetry_opted_out` only.
  Debug / `0.0.0` / `dev-*` / `swiftpm-*` are transport-ineligible
  unless `MACPARAKEET_TELEMETRY=1`.
- Breadcrumbs (`dictation_started`) vs canonical operations
  (`dictation_operation` outcome). `dictation_failed` is not the
  attempt denominator; use started or operation rows.
- `audio_engine_lifecycle`: finite phases; `slow` is a 5s checkpoint
  not a failure; `scope=shared_subscription_queue` success means queue
  entry, **not** mic ready.
- `new_users` rollup column = `onboarding_completed` count.
- Locale is `Locale.current.identifier` (`en_DE`, not `de_DE`).

## Fresh-eye review (Sonnet 5 xhigh + code)

`claude -p --model sonnet --effort xhigh` (logged-in). Several of its
“high” findings were brief-skew, not data-skew; we still used them as
a checklist.

| Claim it attacked | Verdict |
|---|---|
| 1,441 GUI sessions on Sep 9 is undefined | **False.** Re-queried `surface='gui'` that UTC day = **1,441**. |
| 91–95% capture is devices/hits | **Doc was easy to misread.** It is D1 **hits**/CF **hits**. Clarified above. Devices falling faster than hits is expected. |
| 0.8.4 is not a real version | **False.** Shipped 2026-09-17. |
| Opt-out lower bound unverifiable | Bound is `(Sparkle devices − GUI sessions) / Sparkle` on one UTC day. **≥19%** if every opt-in device has one process. Relaunches make unique opt-in smaller, so stock is **higher**, not lower. |
| Activation 32% vs June 45–48% | **Real.** T0 success **45.2% Jun → 32.8% Sep**. Public 30d **34.2%**. |
| Crash count without denominator | **Fair.** 0.8.0 crash **rate** ≈ 0.7.3 (4.4% vs 4.3% of GUI sessions). Softened. |
| CancellationError “may” be stopRecording | **Current 0.8.x code does not.** Residual is **0.7.3**. |
| CLI leaking into top-5% dictation | **No.** That cut was `surface='gui'`. |
| Opt-out measured via `setting_changed` | **No.** We used `telemetry_opted_out`. |

## Fable 5.1 medium (round 2, `claude -p`)

Pursued: T0 by month, onboarding_step, permissions, lifecycle
outcome/scope, CancellationError by version, crash rate + `os_ver`,
meeting start/complete, 0.0.0 emitters, license send sites.

Still worth a later pass (not blocking this note): failure→complete
recovery in 10 minutes; launch-only session inflation; US hour-of-day
on client UTC; event first/last-seen inventory.

Measurement rules Fable proposed that we should keep:

- Failure rate = `dictation_failed` / attempts, **excluding** cancelled.
- Active GUI session = has `dictation_completed`, not merely launched.
- Lifecycle KPI = distinct sessions per outcome, per-session cap.
- Report GUI numbers as **within-GUI ratios**; absolute device counts
  belong to Sparkle, smoothed across the release train.

## Product implications (updated)

1. **Do not ship a growth-stall narrative.** Weekday GUI dictations,
   sessions, onboarding, and meetings are up vs August. Sparkle Sep
   11–18 is a last-check hole (0.7.x updated; 0.8.x has not all
   re-checked).
2. **T0 activation is the leak, and it is getting worse** (45% → 33%).
   Onboarding abandon is ~38%; speech-model `engine_failed` is still
   the setup blocker. Screen-recording denial is the meeting blocker,
   not the dictation blocker.
3. **English-OS worldwide.** Locale is not spoken language. STT
   `language` is the language signal; it is still mostly `en`.
4. **Hold and persistent are both real.**
5. **Capture chrome > new surfaces.** Hide pill / menu-bar-only /
   launch at login. Chat and Transforms remain niche.
6. **Quality:** two GB 0.8.4 start-loops; 0.8.0 SIGSEGV pile is
   **macOS 26.x-weighted**, rate similar to 0.7.3. Later 0.8.x crash
   rates look better. Wire trial/purchase if we want to talk revenue.
7. After the release train pauses, Sparkle weekday device-days should
   rebound toward ~1.6–1.8k. Re-read then.

## Follow-up: daily briefing

Do not re-run this archaeology by hand. The operating spec for a morning
HTML briefing (health vs product split, monitor catalog, three alerts,
PostHog mapping under the privacy contract) is
[`docs/design/2026-09-18-daily-telemetry-observability.md`](../design/2026-09-18-daily-telemetry-observability.md).
