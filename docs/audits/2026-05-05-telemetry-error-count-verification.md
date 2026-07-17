# Telemetry Error Count Verification -- 2026-05-05

> Status: VERIFIED CURRENT SNAPSHOT. Follow-up to
> The original private working note was `journal/2026-05-05-telemetry-error-counts.md`
> (intentionally not tracked); this audit is the durable repository record.
> Source: direct Cloudflare D1 queries run with `npx wrangler d1 execute
> macparakeet-telemetry --remote --command ...`. Wrangler auth expired around
> 2026-05-05 02:11 UTC, then was refreshed and D1 access was restored around
> 2026-05-05 02:53 UTC.

## Bottom Line

The journal's main current finding is correct: the exact CoreAudio
`com.apple.coreaudio.avfaudio error -10868` bucket is real in `0.6.0` and has
not appeared in `0.6.1` or `0.6.2` telemetry so far.

This is stronger evidence than the YouTube hotfix telemetry because `0.6.1`
already has meaningful dictation exposure:

| Version | Dictation starts checked | Exact `-10868` events | Exact `-10868` sessions |
|---|---:|---:|---:|
| 0.6.0 | 287 | 35 | 9 |
| 0.6.1 | 41 | 0 | 0 |
| 0.6.2 | 0 | 0 | 0 |

Interpretation: `0.6.1` is a useful positive signal for the likely default
input-route fix, but `0.6.2` still has too little dictation telemetry to
confirm anything about CoreAudio.

## Verified D1 Results

### Exact `-10868` by version

Direct D1 query over `app_ver IN ('0.6.0','0.6.1','0.6.2')` and
`error_detail LIKE '%-10868%'` returned:

| Version | Events | Sessions | First seen | Last seen |
|---|---:|---:|---|---|
| 0.6.0 | 35 | 9 | 2026-05-04T07:42:11Z | 2026-05-04T21:06:36Z |
| 0.6.1 | 0 | 0 | n/a | n/a |
| 0.6.2 | 0 | 0 | n/a | n/a |

OS/chip split for the `0.6.0` rows:

| OS | Chip | Events | Sessions |
|---|---|---:|---:|
| 15.5 | Apple M4 | 15 | 1 |
| 26.5 | Apple M4 | 7 | 2 |
| 26.5 | Apple M3 Pro | 6 | 2 |
| 26.3 | Apple M1 | 3 | 2 |
| 26.4 | Apple M2 | 3 | 1 |
| 26.3 | Apple M1 Pro | 1 | 1 |

### Current 24h dictation exposure

Direct D1 query for the last 24h returned:

| Version | Dictation starts | `-10868` events | `-10868` sessions |
|---|---:|---:|---:|
| 0.5.5 | 711 | 0 | 0 |
| 0.5.6 | 17 | 0 | 0 |
| 0.5.7 | 1,332 | 0 | 0 |
| 0.6.0 | 287 | 35 | 9 |
| 0.6.1 | 41 | 0 | 0 |
| 0.6.2 | 0 | 0 | 0 |

### Since the `0.6.1` release

Direct D1 query for rows after `2026-05-04T18:49:06Z` returned only `0.6.0`
clients for exact `-10868`:

| Version | Events | Sessions | First seen | Last seen |
|---|---:|---:|---|---|
| 0.6.0 | 6 | 3 | 2026-05-04T19:58:44Z | 2026-05-04T21:06:36Z |

No `0.6.1` or `0.6.2` exact `-10868` rows appeared after the `0.6.1` release.

### `0.6.1` health caveat

`0.6.1` still had telemetry rows that look scary if grouped naively:

| Bucket | Count | Sessions | Interpretation |
|---|---:|---:|---|
| `dictation_failed` / `interrupted during subscribe` | 9 | 1 | Consistent with the false-failure telemetry race fixed for `0.6.2`; not the `-10868` CoreAudio bucket. |
| `dictation_operation` / failure / `STTError.transcriptionFailed` | 1 | 1 | Real but unrelated to CoreAudio engine start. |
| exact `-10868` | 0 | 0 | No recurrence in `0.6.1` so far. |

## Follow-up Re-verification

After Cloudflare auth was refreshed, the all-time exact `-10868` baseline was
re-run. Results: `0.5.6` has 1 event, `0.5.7` has 35 events from 10 sessions,
`0.6.0` has 35 events from 9 sessions, and there are still no exact `-10868`
rows for `0.6.1` or `0.6.2`.

The previously blocked cancellation-rate check was also run. Lifecycle
`dictation_cancelled / dictation_started` was 4.0% for `0.5.5`, 9.2% for
`0.5.6`, 4.5% for `0.5.7`, 6.9% for `0.6.0`, 2.4% for `0.6.1`, and 0.0% for
`0.6.2` with only 2 starts. Canonical `dictation_operation(outcome=cancelled)`
is not comparable to pre-0.6 because operation events were introduced in
`0.6.0`.

## Monitoring Guidance

Track three separate health questions:

1. **CoreAudio `-10868`:** alert mentally on any exact `-10868` row for
   `app_ver >= '0.6.1'`, especially if it appears in more than one session.
2. **False dictation failures:** for `0.6.2`, `dictation_failed` rows with
   `interrupted during subscribe` should drop toward zero. Compare against
   `dictation_operation` outcomes, not only explicit `dictation_failed` rows.
3. **YouTube helper signing:** for `0.6.2`, monitor YouTube
   `transcription_operation` attempts. The first attempt succeeded, but there
   is not enough `0.6.2` YouTube usage yet for a statistical conclusion.

## Follow-up Fixes Applied

- The canonical `dictation_operation` event now carries `cancel_reason` for
  cancelled outcomes, matching `dictation_cancelled.reason`.
- The stats dashboard's "Top failures" query now only includes
  `outcome='failure'`. Cancelled, empty, and unavailable terminal states are
  grouped under a separate non-failure outcome view and are no longer ranked as
  red issues.
- GUI and CLI telemetry are separated by the top-level `surface` field. The D1
  `surface` migration has been applied before deploying Worker/stats code that
  reads or writes the new column.
- Main stats dashboard panels now default to the GUI app surface. CLI activity
  has its own section because each command gets a fresh session ID and should
  not inflate app sessions, version adoption, crash-free rates, or top failures.

After Cloudflare auth was refreshed, the D1 `surface` migration succeeded on
2026-05-05T02:53Z. The backfill verified `gui=133,638` and `cli=200`
historical rows. The website dashboard was deployed to Cloudflare Pages and
`https://macparakeet.com/api/stats` verified the new taxonomy at
2026-05-05T02:54Z: `today.surface='gui'`, `operations.failures` present,
`operations.non_failure` present, and `cli.invocations=23` for the current 24h
window.

## Useful Queries

Exact CoreAudio bucket:

```bash
npx wrangler d1 execute macparakeet-telemetry --remote --command "
SELECT app_ver, COUNT(*) AS coreaudio_10868_events,
       COUNT(DISTINCT session) AS sessions, MIN(ts) AS first_ts, MAX(ts) AS last_ts
FROM events
WHERE json_extract(props,'$.error_detail') LIKE '%-10868%'
GROUP BY app_ver
ORDER BY app_ver"
```

Current dictation denominator:

```bash
npx wrangler d1 execute macparakeet-telemetry --remote --command "
SELECT app_ver, COUNT(*) AS dictation_starts, COUNT(DISTINCT session) AS sessions
FROM events
WHERE event='dictation_started'
  AND app_ver IN ('0.6.0','0.6.1','0.6.2')
GROUP BY app_ver
ORDER BY app_ver"
```

Failure taxonomy for a release:

```bash
npx wrangler d1 execute macparakeet-telemetry --remote --command "
SELECT event, json_extract(props,'$.outcome') AS outcome,
       json_extract(props,'$.source') AS source,
       json_extract(props,'$.stage') AS stage,
       json_extract(props,'$.error_type') AS error_type,
       COUNT(*) AS count, COUNT(DISTINCT session) AS sessions
FROM events
WHERE app_ver='0.6.1'
  AND (
    event IN ('dictation_failed','transcription_failed','diarization_failed',
              'model_download_failed','meeting_recording_failed',
              'meeting_recovery_failed','calendar_auto_start_failed',
              'llm_prompt_result_failed','llm_chat_failed','llm_transform_failed',
              'llm_formatter_failed','license_activation_failed','restore_failed',
              'error_occurred','crash_occurred')
    OR (event LIKE '%_operation' AND json_extract(props,'$.outcome')='failure')
  )
GROUP BY event, outcome, source, stage, error_type
ORDER BY count DESC"
```
