# Telemetry and observability audit

Baseline app: `f43f4bed2`; receiver repository: `6a9f8ffd48338820b83677a6fbe8137558278e71`.
Public read: 2026-10-02 19:06:51 UTC. No production events were submitted and no
production data, settings, credentials or deployments were changed.

## Verdict

The client has unusually substantial privacy and delivery engineering: typed
events, bounded queues, consent-generation invalidation, classified errors,
retry backoff, operation correlation and recoverable crash reports. The main
weakness is the operational contract between the app, receiver, aggregation
and dashboards. A passing client suite can coexist with a skipped compatibility
gate, missing receiver support or a chart that omits the current product flow.

## Confirmed findings

### OBS-01 — Onboarding dashboard omits current steps and overcounts actions

- Evidence: app `Sources/MacParakeetViewModels/OnboardingViewModel.swift:24-46`
  defines `welcome`, `permissions`, `practice`, `ready`; its `sendStepTelemetry`
  emits navigation, engine outcomes, practice outcomes and dismissal actions.
  Receiver `functions/api/stats.ts:390-398` counts all events, and
  `:1383-1398` selects the old eight-step names. `permissions` and `practice`
  disappear from the response. `src/pages/stats.astro:538` calls these users,
  while the tooltip compares raw event counts with the first step.
- Impact: the actual permission/model/practice bottleneck is invisible, and
  retries can look like additional people progressing. Live response had
  welcome=196 and ready=128, alongside nearly empty legacy middle steps.
  Those are observed old event counts, not a valid completion ratio.
- Confidence: HIGH, source plus live response plus failing route regression.
- Effort/risk: S / LOW; aggregation and display semantics only, no ingestion
  or identity changes.
- Repair: count distinct launch sessions per step, expose all four current
  steps, retain observed legacy steps separately, identify metric semantics,
  and remove misleading conversion percentages. Old cached snapshots remain
  explicitly labeled event counts. Fix/PR status is in the main report.

### OBS-02 — Hosted compatibility check silently skips

- Evidence: CI run [37041613709](https://github.com/moona3k/macparakeet/actions/runs/37041613709)
  `check-telemetry-allowlist.log` says `SKIPPED` because it cannot read the
  private website repository. `scripts/ci/check-telemetry-allowlist.sh:80-83`
  deliberately exits zero in that condition. The workflow's step is green.
- Independent current check with the freshly fetched receiver succeeded:
  **104 app events, 110 receiver events**, all app names accepted.
- Impact: current event-name compatibility is verified locally, but the
  mandatory CI verdict does not protect future producer-only event additions.
  The receiver rejects an entire batch for an unknown event, while the client
  discards permanent 4xx responses. A single mismatch can lose unrelated
  telemetry in the same batch.
- Confidence: HIGH. Effort/risk: S-M / MED; a fail-closed change without
  provisioning a readable contract would break first-party CI.
- Recommendation: publish/version a nonsecret receiver contract or provision
  the existing read-only secret. Require successful validation on first-party
  main/release runs; retain an explicit unavailable state for forks. Check
  property/value schemas as well as names, and attach receiver revision to
  release qualification. Do not make all current builds fail merely to remove
  the word SKIPPED.

### OBS-03 — New crash producer has an outstanding receiver dependency

- Evidence: current app `spec/contracts/telemetry-v1.md` requires receiver-first
  deployment for persisted crash IDs, original sessions and bounded context.
  Fetched receiver main lacks `crash_id`/`crash_session` handling. Website
  [PR #101](https://github.com/moona3k/macparakeet-website/pull/101),
  “Validate private crash context and deduplicate retry incidents,” is OPEN.
- Impact: a future release containing app #1196 cannot claim the new full
  crash-observability contract is operational merely because app CI passed.
  Stable 0.8.9 predates that main-branch change; this is a next-release
  coordination gap, not proof that stable users lost these new fields.
- Confidence: HIGH for code/PR state; deployed handler revision not independently
  proved. Effort/risk: S-M / MED, existing receiver PR rather than a duplicate.
- Recommendation: finish/review the paired receiver, deploy it, and perform a
  controlled staging ingestion → stored row → sanitized public response check
  before shipping the producer. A fresh stats page is not that check.

### OBS-04 — Diarization lacks outcome and backend provenance at the user boundary

The app emits failure telemetry but delivers usable text without a retained
speaker-detection warning/status. `diarization_completed` carries source,
speaker count, duration and prior, but does not distinguish actual Nemotron
execution from Community-1 fallback/model revision. See the diarization report
for exact branches. The same typed per-run outcome should feed result UI,
CLI JSON, local diagnostics and the bounded telemetry projection. This has
higher value than adding more event names that cannot explain a user's result.

## Current operational signals

The public endpoint returned HTTP 200 and a fresh snapshot generated at
19:00:47 UTC, age 364 seconds. Selected aggregates and the exact timestamp
are retained in `evidence/public-stats-selected.json`. These are best-effort
opt-in observations, mixed across published versions and configurations.

| Signal | Observed | Interpretation |
| --- | --- | --- |
| Stop to posted paste-event phase sum | 9,143 samples; p50 225 ms, p90 1,207 ms, p99 6,645 ms | Tail deserves profiling; not proof that destination app inserted text, and excludes overlay pause |
| Native microphone start | 11,207 successful samples; p50 175 ms, p90 307 ms, p99 1,549 ms | Engine-start evidence, not microphone correctness or end-to-end latency |
| Model warm-up | 672 successful samples; p50 2 s, p90 71.6 s, p99 598.7 s | Cold/cache/download/device cohorts need separation; mixed metric cannot establish root cause |
| File/meeting transcription processing | 1,159 samples; p50 30.5 s, p90 273.3 s, p99 1,384.1 s | Audio durations also vary; compare matched length/engine/hardware and finalization stages |
| Diarization requested/applied | 1,120 requested, 1,035 applied among 1,159 successful transcriptions | Difference is not automatically 85 model failures; no-speech and source/policy paths need distinction |
| Recorded activation sessions, 30 days | 2,881 starters; 1,839 completers; 1,042 without same-session completion | Process sessions, not people. Resumption, consent and loss affect counts |
| Same-session completed dictation | 718 of 1,839 completion sessions (39%) | Useful activation signal, not proof that 61% could not dictate |
| Canonical dictation outcomes, 24h | 12,374 success; 88 failure; 601 empty; 1,850 cancelled | Prefer these terminal categories over mixing breadcrumb/event counters |

The `transcription_rtf` API field is **audio seconds / processing seconds**
(faster-than-real-time multiplier), the inverse of common benchmark RTF
conventions. Preserve API compatibility but label this explicitly in reports
and charts; do not compare its p99 directly with the diarization benchmark's
elapsed/audio ratio.

The observed 0.8.9 crash row has 838 sessions and 13 incident-like crash counts.
The receiver's current grouping is an estimate based on crash occurrence data;
it is not guaranteed one-to-one with launched sessions. Do not turn that row
into a precise crash-free-user percentage. Missing next launch, opt-out,
SIGKILL and OS-level termination remain outside reporter coverage.

## What is working

- `TelemetryService.swift` bounds queue/batches, coalesces automatic flushes,
  preserves UUIDs on retry and respects Retry-After. Its generation and
  request-admission lock prevent new stale-consent requests; already admitted
  requests may finish, as documented.
- `TelemetryPolicy.swift` suppresses ordinary debug/CI/dev traffic and honors
  persisted opt-out. Audit commands force telemetry off.
- Crash reports use a bounded, leased spool, bounded signal-time records and
  next-launch recovery. Known signal-safety/stack/SIGKILL limits are explicit.
- Audio lifecycle diagnostics distinguish queue entry from actual native
  engine readiness and keep workflow correlation across overlapping consumers.
- Receiver source strips free-form error text, uses bounded public dimensions,
  parameterized inserts and idempotent event IDs. The sampled public failure
  rows contain `error_detail: null`.
- Freshness metadata and no-store stale fallback prevent old data from being
  silently represented as fresh. Receiver handler tests exercise stale/no-store
  behavior; the recorded public GET confirmed only the fresh metadata branch.

## Verification and limits

Current app targeted selection passed 190 XCTest cases plus 26 Swift Testing
cases across diarization/attribution/telemetry; 88 were TelemetryService tests.
The receiver route regression exercises real aggregate SQL against in-memory
SQLite, not string matching; related handler/response/metric/DOM tests passed.
See the validation log for final counts after changes.

No authenticated production D1 query, production POST, provider call, crash on
this user's app, or deployment was performed. Public freshness proves read and
aggregation availability only. Source checks are not a comprehensive security
certification or proof that every dynamic property is safe under every input.

## Highest-value next work

1. Make release-facing producer/receiver checks non-skippable with a readable,
   versioned contract; complete existing receiver PR #101 before producer release.
2. Use current-step session reach to measure permission and practice outcomes;
   retain explicit skip, failure and successful-practice events.
3. Give diarization a durable typed outcome/provenance and a visible recoverable
   warning, keeping all speech/text and identities off telemetry.
4. Profile p90/p99 stop-to-result on fixed synthetic workloads by cold/warm
   model, processing mode, engine, audio length and memory-pressure scenario.
   Preserve the distinction between posted paste event and observed insertion.
5. Add private ingestion accepted/inserted/rejected/failure monitoring with a
   staging canary; never infer ingestion health from the aggregate GET alone.
