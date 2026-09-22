# Daily telemetry observability briefing

> Status: **PROPOSED SPEC** — not implemented. Design + operating policy for
> a morning health/usage briefing. Not an ADR. Concrete event semantics stay
> in [`spec/contracts/telemetry-v1.md`](../../spec/contracts/telemetry-v1.md)
> and [`docs/telemetry.md`](../telemetry.md).
> Date: 2026-09-18 (Pacific). Written after the Sparkle/GUI landscape pass
> and two Fable 5.1 `claude -p` reviews (low + medium).

The question this note answers: **what should we look at every morning, how
do we look at it without inventing users, and what should interrupt vs.
narrate?**

We already have a public dashboard (`/stats`), 5-minute snapshots, daily
rollups, and a deterministic health reviewer. What we do not have is a
scheduled *product* briefing: reach, activation, mix, and “what changed,”
with yesterday plus longer windows, written as a 2-minute HTML file.

## Verdict

Build a **second artifact**, not a second warehouse.

| Plane | Job | Existing | New |
|---|---|---|---|
| **Health** | “Is anything broken?” Thresholds, crashes, watchlists | Website `scripts/telemetry-review.mjs` → `journal/YYYY-MM-DD-telemetry-review.{md,json}` | Schedule it. Do not rewrite it. |
| **Briefing** | “Is the product healthy and moving?” Trends, funnels, mix, outliers | Manual D1 archaeology (this week) | `scripts/telemetry-briefing.mjs` → private HTML + JSON + MD |
| **Live** | “What does the public page say right now?” | `/api/stats` every 5 min | Leave it. The briefing is yesterday’s closed UTC day. |

Three things **page**. Everything else is a two-minute weekday read plus a
Monday deep. Do not buy PostHog. ADR-012 already chose owning the pipeline;
the defect is cadence and statistic choice, not missing a vendor.

Fable 5.1 low and medium independently landed on the same split: reviewer
owns binary/thresholded health; briefing owns trends and judgment; HTML is
static, self-contained, private first; Sparkle is a **floor**, never DAU;
no cross-day identity.

## Why this exists

The 2026-09-18 investigation
([Sparkle DAU](../research/2026-09-18-sparkle-dau-measurement.md),
[user landscape](../research/2026-09-18-telemetry-user-landscape.md),
[percentiles/gaps](../research/2026-09-15-telemetry-percentiles-and-observability.md))
took hours of live D1 + GraphQL and found things a dashboard tile will
never say out loud:

- Weekday GUI usage is still compounding (sessions +32% vs August weekdays).
  Sparkle device-days fell 1,780 → ~1,130 because the 0.8.x firehose resets
  Sparkle’s ~24h last-check, not because 40% of users left.
- T0 activation (same-process `dictation_completed` after
  `onboarding_completed`) decayed **45.2% Jun → 32.8% Sep**. That is the
  product leak. Public 30d agrees (34.2%).
- Screen recording is hostile (606 denied / 19 granted in Sep). Mic is fine.
  Do not mix those funnels.
- ~20–35% of Sparkle devices are invisible to GUI (opt-out + allowlist +
  failed POSTs). Absolute GUI counts are a subset.
- Two GB 0.8.4 sessions produced 16k lifecycle start/success events and
  would have corrupted any un-capped “event volume” chart.
- `dictation_failed` CancellationError is **0.7.3**, not 0.8.x. Version
  split is mandatory.
- Means lie. Dictation duration mean 26s vs p50 11s. Onboarding duration
  mean is hours because people leave the window open.
- License/trial/purchase events are allowlisted and **unwired**. Zero D1
  rows, all time.
- There is still **no pager**. Reviewer is manual. Website `origin/main`
  has no `.github/workflows` for this.

The briefing’s job is to make that investigation cheap enough to run every
day, including the traps.

## What already exists (do not rebuild)

| Piece | When | What it is |
|---|---|---|
| D1 `events` | ingest | Typed allowlisted events. GUI `session` = process UUID. Sparkle `session` = daily hash. |
| `stats_daily_rollups` | 01:30 UTC | Allowlisted GUI day: sessions, dictations, meetings, `new_users` = **onboarding_completed count**. |
| `stats_daily_dimensions` | same | `country`, `speed_all`, `speed_chip`, `app_category`. |
| Snapshot Worker | `*/5` | Public `/api/stats` JSON. 30d T0 already in the snapshot. |
| Rollup Worker | 01:30 daily; Sun 03:00 90d reconcile | Named worker, observability on. |
| Retention Worker | designed, **undeployed** | Do not assume deletion. |
| `pnpm telemetry:review` | **manual** | 24h vs 7d baseline. Failure rates, crashes, watchlists. Writes gitignored journal. |
| Public `/stats` | live | Product marketing + coarse health. Not an operator briefing. |
| CF GraphQL `httpRequestsAdaptiveGroups` | on demand | Independent Sparkle `/appcast.xml` **hits** (not devices). |
| Sparkle middleware `sparkle_check` | every appcast | Best DAU **floor** in steady state; bad WoW during a release train. |

Cron today:

```text
*/5        snapshot refresh → /api/stats
01:30 UTC  daily rollup of yesterday
03:00 UTC  Sunday 90-day rollup reconcile
(none)     telemetry-review.mjs
(none)     briefing
(none)     ingest 5xx / freshness pager
```

Proposed addition, after the rollup lands:

```text
02:30 UTC  telemetry-review.mjs  → journal health md/json
           telemetry-briefing.mjs → journal briefing html/md/json
           page only if the three alerts fire
```

## Identity and privacy (hard rules)

Copied from the contract so this spec cannot drift:

- **No persistent user ID.** GUI `session` dies on process exit. Menu bar
  left up overnight is one session. Relaunch is a new session.
- Sparkle `session` is SHA-256(coarse IP + full UA including version + UTC
  date + pepper). It **rotates daily**. Same-day 0.8.6 → 0.8.7 is two
  fingerprints. Do not add days together.
- Country is `CF-IPCountry` at ingest, not the client.
- `ts` GUI = client ISO-8601 GMT. `ts` Sparkle = server now.
- Audio, transcripts, prompts, filenames, IPs, device identities stay off
  the wire.
- Opt-out: default **on**. After disable, only `telemetry_opted_out`.
  Sparkle still fires.
- Debug / `0.0.0` / `dev-*` / `swiftpm-*` are transport-ineligible unless
  `MACPARAKEET_TELEMETRY=1`. Exclude `0.0.0` from every product number.
- CLI `cli_operation` = one session per invocation. Do not add CLI to DAU.

**Forbidden metrics** (they look like PostHog and are fiction here):

- D1 / D7 / D30 retention, returning users, stickiness, new vs dormant.
- Unique humans ever. (Public `all_time.total_sessions` is distinct
  **process IDs**, 55k as of Sep 18 — not humans.)
- Cross-day funnels or paths.
- Session replay, person profiles, experiments, surveys.

**Honest substitutes:**

- Sparkle daily hash = **device-day floor** (auto-check on).
- GUI distinct session = **process-day**, often > devices.
- Dictating session = process with ≥1 `dictation_completed`.
- Same-process T0 = the only activation rate that is exact.
- Dictations-per-session histogram + top-5% share = intensity / power-user
  dependence (a retention proxy we can actually measure).
- Version adoption curve ≈ size of the updating base.

Every rate prints its **denominator**. Every Sparkle comparison during a
release in the last 48h is labeled **measurement hole**, not churn.

### Analyst SQL name traps

Fable and other agents repeatedly invent columns and events. The briefing
script must use the live names or it will silently return empty:

| Invented | Live |
|---|---|
| `app_version` | `app_ver` |
| `crash` | `crash_occurred` (attribute with `crash_app_ver`, not `app_ver`) |
| `first_dictation` | `first_dictation_completed` |
| `settings_changed` / `props.key` | `setting_changed` / `props.setting` |
| `mic_stall` | `mic_stall_detected` |
| `llm_formatter` | `llm_formatter_used` / `llm_operation` with `feature=formatter` |
| `meeting_recording_completed` | `meeting_recording_completed` is live; confirm before aliasing |
| `date(ts)` × GUI session as “one device-day” | Long-lived menu-bar processes span UTC days. Intensity = `date(ts)` × session (**session-days**), not one row per process. |

Unknown `event` **400s the entire batch**. `audio_engine_lifecycle` is on
website `origin/main` allowlist; a stale local website checkout (this
machine’s `main` has been 70 commits behind) will not show it. Do not
conclude “not ingested” from a dirty or behind worktree. Dead allowlist
peers with no Swift enum: `app_updated`, `paywall_viewed`,
`llm_summary_used`, `llm_summary_failed`.

`INSERT OR IGNORE` on `event_id` means retries do **not** inflate counts.
Do not hunt `session||ts||props` “dupes” as a volume bug.

### Outcome traps (code, not SQL)

- `dictation_failed` is the error path only. `CancellationError` on
  start/stop/undo in current 0.8.x → `dictation_operation` `cancelled`,
  **no** `dictation_failed`. Residual CancellationError rows are 0.7.3.
- `dictation_cancelled` fires in `cancelRecording` **before** confirm.
  `undoCancel` can still emit `dictation_completed` in the same process.
  A cancel + later complete is undo, not abandon.
- Empty / too-short audio → `dictation_empty` (`emptyTranscript` or
  `insufficientSamples`). After the 0.8.6 PTT change, watch **empty
  rate by version**, not cancelled.
- `audio_engine_lifecycle`: `scope=shared_subscription_queue` success =
  queue entry, not mic ready. `outcome=slow` is a 5s checkpoint, not a
  failure. Native rates: scope absent/null, exclude `slow`.
- `llm_provider_unavailable` is **instead of** `*_failed` when config
  or reachability is the issue. `feature=knowledge_card` is not in the
  website `LLM_FEATURES` allowlist and normalizes to `"unknown"`.
- `model_download_started` is attempts (retries double-count).
  `completed` fires once.
- `processing_mode_changed` is its own event (`raw`/`clean`), not a
  `setting_changed` row.
- `voice_return` has no usage event; adoption is `setting_changed`
  `setting='voice_return'` with **value** true/false. Counts without
  direction can be flapping.

## Two jobs, one registry

**Dividing line (Fable, both passes):** if a metric has a fixed threshold
and a wrong answer should wake someone, it belongs in the reviewer. If it
needs a denominator, a trendline, and a human, it belongs in the briefing.

The briefing **embeds** the reviewer’s JSON verdict as one badge and a
link. It never recomputes a failure rate or crash threshold.

One shared **metric registry** (small YAML or JS map in the website repo)
should name events, denominators, minimum-n, and “reviewer vs briefing”
ownership so the two scripts cannot drift on `app_ver` vs `crash_app_ver`
or `new_users` vs humans. That is the only coupling.

## What PostHog-like products actually do here

PostHog (and Mixpanel, Amplitude, Heap) sell a bundle. Mapped onto
MacParakeet’s privacy model and D1 cost:

| PostHog surface | Verdict | MacParakeet shape |
|---|---|---|
| Trends | **Keep** | Daily counts from rollups + Sparkle. Most of the report. |
| Funnels | **Adapt, same-session only** | T0, onboarding steps, permission prompt→grant. Say “session funnel” everywhere. |
| Stickiness (DAU/WAU/MAU) | **Drop** | Needs a stable id. Substitute: Sparkle floor + dictations/session histogram. |
| Lifecycle (new/returning/resurrecting) | **Drop** | Sparkle hash is daily, so “returning” is unobservable. Substitute: version adoption. |
| Retention | **Drop, and say so in the header once** | D0 same-session completion is the only honest retention. |
| Paths | **Adapt narrowly** | First N onboarding steps aggregated. No general path analysis. |
| Insights / HogQL | **Keep as ranked deltas** | Same-weekday + 7d mean + 28d mean, min-n gated. No learned anomaly model. |
| Dashboards | **Keep as one static HTML/day** | `/stats` is already the live dashboard. Do not build a query UI. |
| Alerts | **Keep exactly three** | Ingestion dead, latest-stable crash/fail (reviewer), one session >20% of an event. |
| Cohorts / persons / replay / feature flags / surveys / experiments | **Drop** | Contract forbids the identity they need. |
| Session recordings, heatmaps, error tracking (Sentry-class) | **Drop** | We have `crash_occurred` + fingerprints. Do not send stacks to a third party. |
| Autocapture | **Drop** | Typed allowlist is the product. |
| SQL warehouse sync | **Drop** | D1 is the warehouse. Bounded queries + rollups. |

The useful PostHog idea is not the product. It is the **operating loop**:
a small set of trends, a couple of session funnels, a daily digest, and
almost no pages.

## Windows and comparisons

Primary window: **yesterday UTC** (closed day). Generate after 01:30
rollup, target **02:30 UTC**.

Always compute, even if the HTML hides some on weekdays:

| Window | Use |
|---|---|
| Yesterday UTC | Headline numbers |
| Same weekday last week (D−7) | Default WoW. Weekends exist so Monday has a Saturday. |
| Trailing 7 calendar days | Short trend, T0 7d rolling |
| Trailing 28 calendar days | Baseline, T0 28d, June reference kept as a **fixed** annotation not a window |
| Trailing 14 days | Version adoption stacked |
| Month-to-date vs prior month weekdays | Growth narrative (Monday only) |

**Release annotation:** if any GUI tag published in the last 48h (or the
comparison window overlaps a firehose week), Sparkle WoW is displayed
with a yellow “last-check hole expected” chip. GUI sessions and
dictations remain the growth series during those weeks.

**Partial today:** never mix an open UTC day into averages.

**Allowlist:** briefing product numbers use the same published-version
filter as rollups / `/api/stats`, plus an explicit `0.0.0` drop on any
raw scan. Sparkle has no allowlist (middleware). When comparing Sparkle
to GUI, say so.

**CLI:** own appendix. Never in the six tiles.

## Cadence

| When | What happens | Who cares |
|---|---|---|
| Every day 02:30 UTC, including weekends | Generate health + briefing | Machines |
| Weekdays, morning Pacific | Read the top fold (~2 min) | Maintainer |
| Monday | Read Saturday/Sunday files + weekly deep (concentration, mix, opt-out by country, 4-week T0) | Maintainer |
| Three alerts only | Push / email with verdict line + file path | Same person |
| After a stable DMG | Extra eye on latest-stable crash/fail in the reviewer section | Release |

Weekend generation is load-bearing: D−7 for next Saturday is this
Saturday. Skipping weekends poisons the comparison.

No Slack channel, no public page, no LLM required for v1. Templated
“what changed” bullets are enough. An optional later agent pass may
annotate the JSON; it must not recount.

## Three alerts (page) vs everything else (narrative)

Inherited from the reviewer unless noted. Minimum-n always applies.

1. **Ingestion sanity.** GUI session-days, Sparkle D1 checks, and CF
   GraphQL appcast hits, each vs 7d median. **Any one down >50% while
   the others hold** is a pipeline break, not churn. Also fires if
   yesterday’s rollup row is missing or `stats_rollup_state.status` is
   `failed`. Gates the rest of the report.
2. **Latest-stable health (reviewer).** Existing thresholds: count ≥ 3,
   sessions ≥ 2, rate ≥ 5%, +3pp, ×2. Status `watch` / `attention` on
   the latest stable GUI version. Known watchlist buckets (CoreAudio
   `-10868` on ≥0.6.1, etc.) still bypass. The briefing does not
   re-derive this.
3. **Outlier corruption.** One process accounts for **>20% of any
   event’s daily count** (the GB 0.8.4 start-loop class). Exclude that
   session from volume tiles and list it in the footer. Without this,
   every other number in the report is a lie.

T0 may **graduate** to a reviewer threshold later: 7d success more than
5pp below 28d with n > 50 onboardings, for three weekdays. Not in v1
paging — it is a slow leak, not a pager.

**Never page on:** Sparkle during a release train, weekend dips, country
mix, engine mix, opt-out flow, p50 duration, LLM/transform volume, CLI
volume.

## Monitor catalog

Curation principle: **expansive inventory, ruthless daily surface.**
Everything below is fair game for the appendix or Monday. Only the
marked subset is above the fold.

Legend: **H** = headline daily, **A** = daily appendix, **W** = weekly
deep, **R** = reviewer-owned (embed, don’t recompute), **X** = do not
build.

### A. Pipeline and data quality

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| A1 | Rollup row for yesterday + `rolled_through` | **H**, alert | `stats_rollup_state`, `stats_daily_rollups` | If missing, stop. |
| A2 | Snapshot freshness (`freshness.status`, `generated_at`) | **A** | `/api/stats` | Live plane. Stale >30 min is the Sept 6 class. Consider a Cloudflare notification separately from the briefing. |
| A3 | Sparkle D1 hits vs CF GraphQL appcast hits | **H**, alert | D1 + GraphQL | 91–95% is the healthy **hits/hits** band. Do not divide devices by CF hits. |
| A4 | GUI events yesterday vs 7d median | **H**, alert | rollup `events` | Combined with A3. |
| A5 | Max GUI `ts` lag vs now | **A** | bounded `MAX(ts)` | Clock skew vs ingest death. |
| A6 | `0.0.0` / non-semver event count | **H** footer | raw, yesterday | Exclude from all other numbers. |
| A7 | Unknown / non-allowlisted event names | **A** | ingest logs if cheap; else skip | Worker already drops them. |
| A8 | Ingest `duplicates` / `accepted` / `inserted` | **A** | ingest logs | Retry health. `INSERT OR IGNORE` on `event_id` — duplicates do not inflate D1 counts. |
| A9 | Future timestamps | **A** | raw yesterday | Client clock junk. GUI `ts` is client ISO-8601; there is no `received_at`. Offline flush can land a day’s work on the next UTC date. |
| A10 | D1 rows read / query ms for this run | **A** footer | script timing | Keep cost visible. Activation SQL used to read 18M rows. |
| A11 | Unwired catalog: `trial_*`, `purchase_started`, `license_activated` | **A** | `COUNT(*)` all time, cached | Show “0 rows, unwired” every day until it is false. Do not compute a conversion rate. Enum + immediate-flush; no product `Telemetry.send` except license paste. |
| A12 | Rollup vs raw allowlisted GUI (sessions, dictations) | **W** | recompute yesterday | Quantifies how much `/stats` understates raw. Drift = allowlist or rollup bug. |
| A13 | Allowlist drift: live enum events missing from Worker, dead Worker events missing from enum | **A** | CI already has a guard; briefing footnotes if the guard is red | Unknown event 400s the **whole batch**. `audio_engine_lifecycle` must stay on the deployed allowlist. |

### B. Reach and growth

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| B1 | Sparkle distinct `session` (device-days) | **H** | `sparkle_check` | Label **floor**, never DAU. Annotate release days. Last clean weekday: 2026-09-09 = 1,780. |
| B2 | Sparkle hits (D1) | **A** | same | Hits fall slower than devices during a hole (retries). |
| B3 | GUI distinct sessions (allowlisted) | **H** | rollup `sessions` | Process-days. |
| B4 | GUI dictating sessions | **A** | raw yesterday, bounded | ≥1 `dictation_completed`. Active usage, not launches. |
| B5 | `app_launched` | **A** | raw / future rollup | Inflates after Sparkle install. Do not use as unique opt-in. |
| B6 | Sparkle / GUI ratio | **H** | B1 / B3 | ~1.2 on a clean day (Sep 9: 1780/1441). Jump + inversion during firehose = expected. |
| B7 | Opt-out **flow** (`telemetry_opted_out` distinct sessions) | **A** | raw | ~6–27/day in Sep. Not stock. |
| B8 | Opt-out **stock** estimate | **W** | (Sparkle − GUI) / Sparkle on a non-release weekday, by country | Working band ~20–35% invisible. **IN ~1.0 is ambiguous** (low opt-out *or* frequent relaunch — same signature). **GB ~1.60 with low dictations/session** reads as installed-but-idle, not heavy use. Exclude release weekdays. |
| B9 | Onboardings (`new_users` column) | **H** | rollup | **Count of `onboarding_completed`**, not unique humans. Sep weekday ~74. |
| B10 | Dictations completed | **H** | rollup | Growth series during release trains. |
| B11 | Meetings completed | **H** | rollup | |
| B12 | Weekday-adjusted WoW and vs 28d | **H** | derived | Default comparison. |
| B13 | Month vs prior month weekdays | **W** | rollups | The compounding chart. |
| B14 | Unique humans / WAU / MAU | **X** | — | Impossible. |
| B15 | People who disabled **both** Sparkle auto-check and telemetry | **X** | — | In neither series. State in the header once. |

### C. Activation and onboarding (session funnels)

Governing audit:
[`docs/audits/2026-06-03-activation-metrics-cohort-caveats.md`](../audits/2026-06-03-activation-metrics-cohort-caveats.md).
June ~45–48% in that audit is now a **fixed reference line**, not “the
current number.”

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| C1 | T0 try: onboard session has `dictation_started` | **A** | same-session EXISTS, 7d | Fell 53% Jun → 43% Sep. Completers not even trying. |
| C2 | T0 success: onboard session has `dictation_completed` | **H** | same, 7d + 28d + June ref | **Headline product KPI.** 45.2% → 32.8%. Use `COUNT(DISTINCT session)` / EXISTS, never JOIN-then-COUNT(*). |
| C3 | T0 by app_ver | **A** | same | Setup regressions hide in the blend. |
| C4 | Onboarding step reach (welcome → ready) | **H** | `onboarding_step`, 7d | Sep: 1,888 viewed → 1,179 completed (62%; 38% abandon). |
| C5 | `speech_model` `engine_failed` vs `engine_ready` | **H** | same | Largest measured setup blocker since the July audit. |
| C6 | Permission microphone grant/deny | **A** | `permission_*`, 7d | Fine today (1243/107 in Sep). |
| C7 | Permission screen_recording grant/deny | **H** | same | Hostile. Meetings funnel, not T0. |
| C8 | Permission accessibility / calendar | **A** | same | |
| C9 | `first_dictation_completed` windows | **W** | install-scoped, onboard ≥ 2026-05-23 | Among emitters, ~62% within an hour. Different population than T0. **Never** divide rolling first_dictation by rolling onboard. |
| C10 | Onboarding `duration_seconds` mean | **X** | — | Left-open windows. Hours-to-days. Useless as SLO. |
| C11 | Cross-day “activated later” | **X** | — | No identity. |

### D. Reliability (headline only)

Reviewer owns the rates. Briefing shows the **per-version table** so a
new build’s first bad day is visible, and so 0.7.3 CancellationError
cannot be read as an 0.8.x regression.

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| D1 | Crashes per 1k GUI sessions by `crash_app_ver` | **H** / **R** | reviewer JSON + session exposure | Attribute to crashing build, not reporting build. 0.8.0 4.4% ≈ 0.7.3 4.3%; later 0.8.x lower. n-small after a fresh tag (0.8.7). |
| D2 | Crashes by `os_ver` for latest and 0.8.0 | **A** | raw 7d | 0.8.0 pile is macOS 26.x-weighted. |
| D3 | `dictation_operation` failure rate by version, excluding cancelled/empty/unavailable | **R** | reviewer | |
| D4 | `dictation_failed` reason mix by version | **A** | raw 7d | CancellationError = 0.7.3 residual. |
| D5 | Transcription / meeting / model_download failure | **R** | reviewer | |
| D6 | Mic-start `elapsed_ms` p50/p90 (native success) | **A** | raw yesterday, n>100 | Closest thing to F1 <500 ms we can see today. p50~180 / p90~380 as of Sep 15. |
| D7 | Dictation `capture_ms` / `transcribe_ms` / `e2e_ms` | **A** when shipped | `dictation_operation` success | Percentiles research: the product SLO is still unmeasured. Do not pretend p90 of speech duration is e2e. |
| D8 | Lifecycle: distinct sessions with native start `slow` or failure | **A** | raw yesterday, **per-session cap** | Filter `scope` null/absent; exclude `outcome=slow` from failure rates. Volume of start/success is expected (one per engine start). |
| D9 | Lifecycle spam sessions (>N start events, N≈200) | **H** footer / alert if >20% | raw yesterday | Exclude from volume. If all hot sessions share one `app_ver` (0.8.4 GB), it is a regression; if spread, device-class. |
| D10 | Watchlist: CoreAudio `-10868`, interrupted-during-subscribe, YouTube post-0.6.2 | **R** | reviewer | |
| D11 | `mic_stall_detected` **sessions** / GUI sessions by version | **A** | raw 7d | Raw stall counts lie (one process can spam). Ratio of distinct stall sessions is the friction number. |

### E. Product usage (shape)

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| E1 | Dictation started / completed / empty / cancelled / failed | **A** | raw or future rollup | Completed/started ~90% since Sep 11. Do not treat `cancelled` + later `completed` in one process as abandon (undo). |
| E1b | Empty rate by version (vs cancelled, vs 28d) | **A** | raw 7d | Post-0.8.6 PTT: too-short presses should land on `empty`, not `cancelled`. A jump in empty on latest vs 0.8.5 is the hold-timing signal. |
| E2 | Hold vs persistent | **A** | props | Both first-class (65/35). AU ~91% hold; PL persistent is a power-user cluster, not a culture. |
| E3 | Trigger mix | **A** | props | Hotkey ~98%. Pill/menu are rounding error. |
| E4 | Engine mix on completed dictation | **W** | props | Parakeet v3 ~76%, Whisper large-v3 turbo ~11%. Nemotron/Cohere niche. Optional engines must earn maintenance. |
| E5 | STT `language` mix (not OS locale) | **W** | props | Language signal. OS locale is almost 100% `en*`; DE speaks `en` in dictation too. French OS (`fr_FR`) is the only visible native-OS minority. |
| E6 | `app_category` | **W** | dimensions | other / browser / terminal / code / messaging. Docs/email small. |
| E7 | Duration p50/p90 dictation success | **A** | raw yesterday | Mean lies (26s vs p50 11s). |
| E8 | Transcription source mix | **A** | `transcription_completed` | meeting / drag_drop / file / youtube / podcast. |
| E9 | Transcription RTF p50/p90 | **A** | raw | Mean 60× vs p50 39×. |
| E10 | Meeting start/complete/fail/cancel | **A** | raw | ~97% of starts complete. |
| E11 | Calendar auto-start vs meeting completions | **W** | raw | Minority (~17%). |
| E12 | Auto-stop proposed / confirmed / vetoed, by `reason` | **W** | raw | `meeting_app_closed` vs `prolonged_silence`. Veto ≠ failure. People mostly accept. |
| E13 | Same-process overlap: dictation ∧ meeting ∧ transcription | **W** | EXISTS | Dictation-only remains majority. Meetings almost always emit transcription. MX/BR-style `t≥20 AND d=0` is a **batch-transcribe segment**, not a dictator. |
| E14 | LLM: formatter / prompt / chat / transform, distinct sessions | **A** | raw | ~10% of processes. Chat/Transforms niche. |
| E15 | LLM duration p50/p90 by `feature` | **A** | raw | Do not blend formatter (ms) with `prompt_result` (can be hours). |
| E16 | Settings **values**, not just keys | **W** | `setting_changed` `props.setting` + `props.value` | Capture chrome > model picker. Direction matters: 454 `menu_bar_only` toggles can be flapping. Split onboarding-session vs later. |
| E17 | Chip mix | **W** | envelope | M1 still large; M5 already material. Do not drop M1. |
| E18 | CLI command mix | **A** | `cli_operation` | Automation, not humans. 38k Sep events = 38k sessions. |
| E19 | `processing_mode_changed` (`raw` vs `clean`) | **W** | own event | Not under `setting_changed`. |
| E20 | Model download started vs completed vs failed by engine | **A** | raw 7d | Started = attempts. Pair with C5 `speech_model` `engine_failed`. |

### F. Intensity, concentration, interesting sessions

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| F1 | Dictations-per-**session-day** histogram | **W** | `date(ts)` × session | Never-quit menu bar spans days; a raw per-process histogram is pulled by TH/KZ/AU-type always-on sessions. Sep 16 process cut: 19 sessions (2.7%) → 24% of dictations; 51+ → 46%. Keep that as a process view; prefer session-days for intensity. |
| F2 | Top 5% share of dictations | **W** | same grain as F1 | Power-user dependence. Growth risk and the only retention-shaped number we have. |
| F3 | Classified interesting sessions (anonymized prefix) | **A**, capped 8 | yesterday | Classes: **lifecycle spam**, **always-on dictator**, **batch transcriber**, **never-quit old version**. Show country, app_ver, event count, dictations, span. No raw UUID in any future public variant. |
| F4 | `app_quit.session_duration_seconds` max | **X** | — | Multi-million-second clock junk / never-quit menu bar. Cap at 7d if you ever chart it. |
| F5 | Weekend vs weekday dictation ratio, and UTC-hour profile, by country | **W** | 28d | Work vs personal proxy. Shift hours by known offsets. US Labor Day and EU August holidays sit inside naive month means. |

### G. Geography and version mix

| ID | Monitor | Cadence | Source | Notes |
|---|---|---|---|---|
| G1 | Top countries by GUI session-days | **W** | dimensions `kind=country` | US ~29%, DE ~12%, then GB/IN/NL/FR. |
| G2 | Dictations per GUI session by country | **W** | join | Intensity: NL/DE high, JP low. Do not moralize. PL persistent cluster is n=45 sessions. |
| G3 | Sparkle vs GUI ratio by country | **W** | one clean weekday | Opt-out stock geography. |
| G4 | Version share GUI sessions, 14d stacked | **H** | raw or future dimension | Explains Sparkle holes and crash denominators. |
| G5 | Sparkle devices 0.7.x vs 0.8.x | **A** during trains | `sparkle_check` app_ver | Sep 9: 1689 vs 19. Sep 11: 534 vs 457. This **is** the cliff. |
| G6 | Leftover 0.7.x Sparkle floor | **A** | same | Auto-check-off / never-relaunch tail. Includes some heaviest dictators. Sparkle cannot update a process that never quits. |
| G7 | Sparkle checks / device-day | **A** during trains | hits / devices | >1 on release days quantifies last-check reset + UA-version hash split. |

## Insight rules (templated, no LLM)

The generator fills **0–5** bullets. Empty is fine. Rank by how many
comparison points they exceed, with min-n. Each bullet is one sentence.

| If | Then say |
|---|---|
| Sparkle floor down >20% WoW **and** GUI dictations up **and** a GUI tag in 48h | “Sparkle floor dropped while usage rose — last-check hole from {versions}, not churn.” |
| Sparkle, GUI, and CF hits all down >20% | “Reach down across independent sources — treat as real until proven otherwise.” |
| T0 7d ≤ 28d − 5pp, n>50 | “T0 success {7d}% vs {28d}% 28d (June reference 45%). Completers not dictating in-session.” |
| `speech_model` engine_failed / ready > 28d + 5pp | “Speech-model setup failures rose — this is still the onboarding blocker.” |
| Screen-recording deny rate > 80% | “Screen recording remains hostile ({denied}/{prompted}). Meetings funnel, not dictation T0.” |
| Latest-stable crash/1k > prior 7d ×2, n sessions ≥ 50 | Defer wording to reviewer status; briefing only quotes it. |
| One session >20% of an event | “Excluded session {prefix} ({cc}, {ver}) with {n} {event} events from volume tiles.” |
| CancellationError dictation_failed on 0.8.x > 0 | “Unexpected: CancellationError on {ver} (historically 0.7.3). Check mapping.” |
| Empty rate on latest ≥ 0.8.6 vs 0.8.5 +3pp, n started ≥ 200 | “Empty dictations rose on {ver} vs 0.8.5 — PTT too-short / hold timing, not cancel.” |
| Hot lifecycle sessions all on one version | “Lifecycle start-loop concentrated on {ver} ({n} sessions); excluded from volume.” |
| Heavy dictation on leftover 0.7.x processes | “Never-quit 0.7.x dictators are still on the old build; Sparkle cannot update a process that does not relaunch.” |
| 0.0.0 share > 1% of raw GUI | “Debug builds leaking into raw events ({n}); excluded from product numbers.” |
| License/trial still 0 | Skip daily. Mention once on Monday until wired. |
| Top-5% share of dictations > 28d + 10pp | “Concentration rose: top 5% of processes produced {pct}% of dictations.” |

## HTML report (2-minute top fold)

Single self-contained file. Inline CSS, inline SVG sparklines, **no
external JS**. Target: a phone or a mail.app preview. Same file can later
be published under `/dev` without rewriting.

Path (gitignored, private):

```text
journal/YYYY-MM-DD-telemetry-briefing.html
journal/YYYY-MM-DD-telemetry-briefing.md
journal/YYYY-MM-DD-telemetry-briefing.json
journal/latest-telemetry-briefing.html   # copy
```

Sibling to the existing `journal/YYYY-MM-DD-telemetry-review.{md,json}`.

### Above the fold

```text
Header
  date (UTC closed day)
  reviewer badge: CLEAR / WATCH / ATTENTION (from JSON, not recomputed)
  ingestion line: GUI · Sparkle D1 · CF hits · rollup ts
  one-sentence verdict

Row 1 — six tiles, each with D−7 delta and 28d sparkline
  GUI sessions (process-days)
  Sparkle floor (device-days)          [never labeled DAU]
  Dictations completed
  Meetings completed
  T0 success 7d (June 45% tick)
  Crashes / 1k sessions, latest stable

Row 2 — What changed
  0–5 templated bullets. Empty = “Nothing crossed a soft band.”

Row 3 — Health box
  Reviewer JSON as-is: latest-stable version, status, signal count,
  link to the day’s telemetry-review.md

Row 4 — Release context
  GUI tags in last 14 days: version, days since, share of yesterday’s
  GUI sessions. Yellow chip if last 48h.

Row 5 — Onboarding session funnel (7d bars)
  welcome → … → ready, with speech_model engine_failed called out

Row 6 — Version adoption 14d stacked (small)

Footer
  data hygiene (0.0.0, excluded outliers, unknown events)
  “Retention/WAU not computed (no persistent id).”
  query ms · D1 rows read · script git sha
```

### Appendix (`<details>` or page 2)

Every monitor in the catalog marked H/A, with columns:

`yesterday | D−7 | 7d mean | 28d mean | notes`

Plus:

- Funnel by version
- Failure mix by version (reasons)
- Duration p50/p90 tables
- Interesting-session table (capped, classified)
- CLI appendix
- Unwired events row
- SQL keys / rollup columns used

Monday extra (still in the same file, in a `weekly` section when
`weekday === 'Mon'`): F1–F2, F5, E4–E6, E16 values, B8, G1–G3, G7,
month-vs-month, license placeholder.

## First implementation slice

Smallest useful job, website repo, next to the reviewer:

`scripts/telemetry-briefing.mjs` + `pnpm telemetry:briefing`

**Slice 0 (one day of work, proves the rendering path):**

- Read yesterday + 28d from `stats_daily_rollups` only.
- Read the reviewer’s JSON if present (run reviewer first in the same
  job).
- One CF GraphQL call for `/appcast.xml` Sparkle hits yesterday vs 7d.
- Sparkle device-days: one bounded `COUNT(DISTINCT session)` per day for
  28d on `event='sparkle_check'` (event index; 28 tiny queries or one
  `GROUP BY date(ts)`).
- GitHub `gh release list` for 14d annotation (or a static
  `releases.json` refreshed by the same job).
- Render Header, Row 1 (sessions, Sparkle floor, dictations, meetings;
  T0 and crash tiles can wait), Row 2 (volume deltas only), Row 3, Row
  4, hygiene footer.
- Write gitignored HTML/MD/JSON. No raw GUI event scans.

**Slice 1:** T0 + onboarding funnel + screen-recording outcomes.
Bounded `date(ts)` on the event index for yesterday and 7d **only**.
`COUNT(DISTINCT session)` / `EXISTS`. Never JOIN two event types then
`COUNT(*)`.

**Slice 2:** version adoption 14d, failure mix by version, crash/1k
table from reviewer exposure + crash events.

**Slice 3:** outlier cap (per-process group-by, yesterday only),
interesting-session classifier, concentration histogram.

**Slice 4:** schedule. GitHub Action in the website repo, or a fourth
cron Worker writing to R2. 02:30 UTC. Reviewer then briefing. Page via
email or GitHub issue only on the three alerts (reviewer already
describes issue-on-`watch`/`attention`; keep that policy).

**Slice 5 (rollups, so briefing stops touching raw events):** add daily
columns or `stats_daily_dimensions` kinds for T0 try/success, permission
outcomes, engine mix, version share, duration histogram buckets. Then
the briefing is rollup-only plus GraphQL plus reviewer JSON.

**Later, only if asked:**

- Redacted `/dev/telemetry/YYYY-MM-DD` after a month of private
  stability. Strip interesting-session prefixes, country tables, and
  any session-level row.
- Wire `trialStarted` / `purchaseStarted` send sites, then replace the
  placeholder.
- Cloudflare notification on Pages 5xx `/api/telemetry` and snapshot
  `freshness.reason=refresh_failed` > 30 min (pipeline, not product).
- Shared metric registry; move reviewer onto it.
- Dictation `e2e_ms` once the app ships it (percentiles research Phase
  C). Allowlist must deploy first.

**Skip until asked:** live dashboard, HogQL, chart library, email
digest beyond the three alerts, public page, any new identity, Workers
Analytics Engine, Sentry, PostHog.

## Query notes (copy for implementers)

D1: `macparakeet-telemetry`
`7372263e-6a0b-4c70-8188-8f1d6d16bf31`, account
`1542b0baf1922ec403cc44ef3fd39233`. Zone `macparakeet.com`
`4183d6a922545fb96269e3c24d1611a2`.

Prefer `event` + `ts` index. Bound every raw scan with
`ts >= '{day}T00:00:00Z' AND ts < '{day+1}T00:00:00Z'`.
`date(ts)` is ok for Sparkle (server timestamps). GUI `ts` is client
GMT; UTC day is still the reporting grain.

**T0 (never explode joins):**

```sql
SELECT
  COUNT(*) AS onboard_sessions,
  SUM(CASE WHEN EXISTS (
    SELECT 1 FROM events d
    WHERE d.session = o.session
      AND d.event = 'dictation_started'
      AND d.surface = 'gui'
  ) THEN 1 ELSE 0 END) AS t0_try,
  SUM(CASE WHEN EXISTS (
    SELECT 1 FROM events d
    WHERE d.session = o.session
      AND d.event = 'dictation_completed'
      AND d.surface = 'gui'
  ) THEN 1 ELSE 0 END) AS t0_success
FROM events o
WHERE o.event = 'onboarding_completed'
  AND o.surface = 'gui'
  AND o.ts >= :start AND o.ts < :end
  AND o.app_ver != '0.0.0';
```

**Sparkle floor:**

```sql
SELECT date(ts) AS day,
       COUNT(*) AS hits,
       COUNT(DISTINCT session) AS devices
FROM events
WHERE event = 'sparkle_check'
  AND ts >= :start AND ts < :end
GROUP BY date(ts);
```

**Outlier cap:**

```sql
SELECT session, app_ver, country, event, COUNT(*) AS n
FROM events
WHERE ts >= :start AND ts < :end
  AND surface = 'gui'
GROUP BY session, app_ver, country, event
HAVING n > 200
ORDER BY n DESC
LIMIT 20;
```

A session with `n > 0.20 * (SELECT COUNT(*) FROM events WHERE event = ?
AND ts range)` trips alert 3.

**CF GraphQL** (hits, not devices): path `/appcast.xml`,
`userAgent LIKE '%Sparkle%'`, `requestSource=eyeball`,
`httpRequestsAdaptiveGroups`. Compare to D1 hits, not D1 devices.

**Crashes:** use `crash_app_ver` (reviewer already has
`CRASH_ATTRIBUTED_VERSION_SQL`). Denominator = GUI distinct sessions
for that version in the same window.

**Failure rate:** attempts in the denominator, **exclude** cancelled.
`dictation_failed` is not the attempt count; use started or
`dictation_operation`.

## Cost and safety

- One briefing run per day. Bounded yesterday/7d/28d. No all-time
  `ORDER BY` on JSON props.
- Do not add window-function percentiles to the public snapshot path
  until activation SQL is cheap (already a known 18M-row hog).
- Briefing percentiles, if any, stay on yesterday’s partition (40–312 ms
  in the Sep 15 research).
- No production writes. Read-only `wrangler d1 execute --remote` / Worker
  bind.
- Journal is gitignored. Do not commit HTML with session prefixes.
- Do not delete user databases, meeting artifacts, or D1 rows as part of
  this work. Retention remains a separate, undeployed gate.

## Operating rules for humans and agents

1. Sparkle down + GUI up + recent tag = measurement hole. Do not file
   “we lost 40% of users.”
2. Quote rates with denominators. 0.8.7 with 2 crashes / 48 sessions is
   not a verdict.
3. Locale is `Locale.current` (`en_DE`). Spoken language is the STT
   `language` prop.
4. `new_users` is onboardings. `all_time.total_sessions` is process IDs.
5. `audio_engine_lifecycle` start/success volume is expected. Watch
   per-session caps and native `slow` / failure, not the raw count.
   Do not join Sparkle `session` to GUI onboarding/dictation.
6. Do not divide `first_dictation_completed` by `onboarding_completed`
   on mixed ship-date windows.
7. Agents consume the JSON. They do not recount unless the report is
   internally inconsistent. Judgment: real user impact? which version?
   issue vs PR vs keep watching?
8. Do not generalize from “interesting sessions.” Volume ranking finds
   bugs and power users, never the median.
9. Column is `app_ver`. Event is `crash_occurred`. Setting key is
   `props.setting`. See Analyst SQL name traps.

## Related work (do not confuse)

| Doc | Role |
|---|---|
| [`docs/telemetry.md`](../telemetry.md) | Event catalog, philosophy, existing reviewer loop |
| [`spec/contracts/telemetry-v1.md`](../../spec/contracts/telemetry-v1.md) | Privacy + outcome semantics |
| [`spec/adr/012-telemetry-system.md`](../../spec/adr/012-telemetry-system.md) | Why we own the pipeline |
| Website `docs/telemetry-reviewer.md` | Health reviewer runbook |
| Website `docs/sparkle-dau.md` | Sparkle floor, CF vs D1 hits, cache posture |
| Website `docs/telemetry-rollups-plan.md` | Rollup cron; deletion still out of scope |
| [`docs/research/2026-09-18-sparkle-dau-measurement.md`](../research/2026-09-18-sparkle-dau-measurement.md) | Why Sparkle broke as WoW |
| [`docs/research/2026-09-18-telemetry-user-landscape.md`](../research/2026-09-18-telemetry-user-landscape.md) | What the 2026-09-18 pass actually found |
| [`docs/research/2026-09-15-telemetry-percentiles-and-observability.md`](../research/2026-09-15-telemetry-percentiles-and-observability.md) | Means lie; SLO gap; no second vendor |
| [`docs/audits/2026-06-03-activation-metrics-cohort-caveats.md`](../audits/2026-06-03-activation-metrics-cohort-caveats.md) | T0 vs first_dictation |
| [`docs/audits/2026-07-04-onboarding-telemetry-review.md`](../audits/2026-07-04-onboarding-telemetry-review.md) | Speech-model blocker |
| Public `/stats` | Live marketing dashboard |

The Sep 16 “telemetry observability followthrough” row in
`plans/README.md` (e2e timings, cheaper activation SQL, Pages
observability, health probe) is **instrumentation**, not this briefing.
Both should happen; they are not substitutes.

## Fable 5.1 consultation (2026-09-18)

`claude -p --model claude-fable-5-1` with `--effort low` and
`--effort medium`, no tools, against the same brief. They agreed on the
split, the three-alert cap, Sparkle-as-floor, same-session funnels only,
static HTML, and “first slice = rollups + reviewer JSON.” Differences
worth keeping:

| Topic | Low (ruthless) | Medium | This spec |
|---|---|---|---|
| Alert count | 3 (ingest, crash/1k, one session >20%) | 3 (ingest, crash, rollup stale) | **Union:** ingest triad, reviewer latest-stable, outlier >20%. Rollup-missing is part of ingest. |
| T0 paging | Narrative only | Narrative; optional 5pp/n>50 later | Narrative in v1; graduate later |
| Durations | Stay in reviewer, don’t repeat | p50/p90 in briefing; alert if p90 doubles | Appendix + D6/D7. No p90-doubling pager in v1 (n and mix make it noisy). |
| Paths | Drop | Onboarding first-10 only | Drop general; funnel bars are enough |
| Anomaly ML | Drop | Ranked same-weekday deltas | Ranked deltas, templated bullets |
| First slice | Rollups + reviewer JSON, Header/Row1/Row2/footer | Same + GraphQL + six tiles | Slice 0 as above |
| Public `/dev` | Skip | After a month, redacted | Skip until asked |
| Shared registry | Implied | Explicit YAML/JS | Slice 5-adjacent; not blocking Slice 0 |

Neither pass wanted a live dashboard, retention curves, or a new event
for v1.

A separate Fable 5.1 medium landscape pass (query ranking, not this
briefing brief) plus a code-meaning review of send sites added the
traps above: session-day intensity grain, empty-vs-cancelled after PTT,
`mic_stall_detected` as a session ratio, settings **values**,
batch-transcribe as a segment, never-quit 0.7.x as an update hole, and
the allowlist/idempotency facts. Treat that pass’s SQL as a backlog of
angles, not copy-paste — it used `app_version`, `crash`,
`first_dictation`, `settings_changed`, and `mic_stall`.

## Open decisions (not blocking Slice 0)

- Notification path for the three alerts: GitHub issue (reviewer already
  suggests this), email, or a local `osascript` banner on the machine
  that runs the cron. Pick whichever is already in the operator’s loop.
- Whether Slice 0 lives as a GitHub Action in `macparakeet-website` or a
  launchd job on a trusted Mac. Action is better once
  `CLOUDFLARE_API_TOKEN` + D1 execute are available to CI; until then a
  local cron matching `pnpm telemetry:review` is honest.
- Whether T0 belongs in `stats_daily_rollups` as columns (`t0_try`,
  `t0_success`, `onboard_sessions`) in the same change that adds Slice 1,
  or later in Slice 5. Prefer adding columns once the SQL is proven in
  the briefing script.
- June 45.2% reference: freeze as a constant in the registry, do not
  re-query 2026-06 every morning.

## What “done” looks like for Slice 0

A weekday morning you can open one HTML file and in two minutes know:

1. Ingestion is alive (or you were already paged).
2. Usage went up or down vs last Tuesday, with Sparkle labeled correctly
   if a build shipped.
3. Latest stable is CLEAR/WATCH/ATTENTION, with a link to the counts.
4. Nothing in the footer is eating the tiles (debug leak, start-loop).

That is the whole product. The rest of this catalog exists so the Monday
read, and the second week of implementation, do not have to rediscover
what to query.
