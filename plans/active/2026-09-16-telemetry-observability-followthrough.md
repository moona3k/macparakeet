# Telemetry observability follow-through

Date: 2026-09-16
Status: **PARTIAL** (website deployed 2026-09-16; app [#1059](https://github.com/moona3k/macparakeet/pull/1059) merged 2026-09-16, not in the 0.8.3 DMG; retention worker not deployed)
Repos: app (`feat/telemetry-observability-followthrough`) + website (same branch name)

## Context zone

Public `/stats` already publishes 24h p50/p90. Remaining gaps from the
2026-09-15 research note:

1. Dictation SLO is unmeasured (hold time ≠ paste latency).
2. Activation SQL joins unbounded session history (~18M rows_read).
3. Silent pipeline failure has no pager (Pages observability off; review is manual).
4. LLM `feature=unknown` is formatter labels scrubbed at ingest.

Must not: deploy the retention worker; add a feature×provider percentile
matrix; add a third analytics vendor; 400 telemetry batches by shipping a new
event name before the website allowlist.

## 1. Dictation e2e

**Producer (success only):**

| Field | Meaning |
| --- | --- |
| `capture_ms` | Stop request → WAV ready (`stopCapture`) |
| `transcribe_ms` | WAV ready → pasteable text (`processCapturedAudio`, includes formatter) |
| `paste_ms` | Clipboard Cmd+V posted (not AX proof of on-screen text) |
| `e2e_ms` | Phase sum `capture_ms + transcribe_ms + paste_ms` (excludes the 500 ms success UI pause) |

`dictation_operation` carries `capture_ms` / `transcribe_ms`.
`dictation_insert` is a latency breadcrumb (not a second outcome) with all four
fields, emitted only after a successful paste of text. Empty skip, action-only
Voice Return (keystroke with no Cmd+V), and paste failure omit it. Website
`ALLOWED_EVENTS` must include `dictation_insert` before the app ships.

## 2. Cheap snapshot SQL

Activation intersects windowed session sets on `idx_events_event_ts` (30-day
bind) instead of joining unbounded session history. Ingest liveness uses
`MAX(ts)` and a last-hour `COUNT` subquery, not a full-table `SUM(CASE)`.
Retention stays undeployed until `delete_safe_through` + alerting + backup
gates exist.

## 3. Silent failure

- Named snapshot/rollup Workers keep `[observability]`. Pages wrangler.toml
  cannot; ingest 5xx is paged via ingest quiet + GHA.
- Snapshot payload `pipeline.latest_event_at` + `events_last_hour`.
- Cron health probe: error if snapshot refresh failed, ingest quiet 12h, or
  rollup `last_success_at` older than 26h. History `degraded` is a warning
  (midnight UTC until the 01:30 rollup). Legacy snapshots without `pipeline`
  skip ingest-quiet so deploys do not page for 15 minutes.
- GitHub Action curls `/api/stats` every 6 hours with the same gates.
- One Cloudflare notification on Worker exceptions + Query Builder on
  `telemetry_ingest` / `telemetry_storage_failure` / `exceededResources` /
  `telemetry_ingest_zero_inserts`. No PostHog/Sentry.
- Retention worker is not deployed.

## 4. LLM feature

Ingest remaps `formatter_dictation` / `formatter_transcription` → `formatter`
so in-the-field builds heal inside the 24h window. App formatter
`llm_operation` emits `feature=formatter`. Dictation vs transcription stays on
`llm_formatter_*` `source`.
