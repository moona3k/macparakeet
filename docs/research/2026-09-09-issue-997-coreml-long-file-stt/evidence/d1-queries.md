# D1 queries used for issue 997

Database: Cloudflare D1 `macparakeet-telemetry`
(`7372263e-6a0b-4c70-8188-8f1d6d16bf31`). Run from `macparakeet-website`:

```bash
npx wrangler d1 execute macparakeet-telemetry --remote --json --command "…"
```

Window unless noted: `app_ver='0.7.3'` and `ts >= '2026-08-10T00:00:00Z'`.
Issue timestamps are 2026-09-09T16:23Z–16:45Z.

0.7.3 `transcription_failed` / `transcription_operation` rows do **not** store
`error_detail`. The Core ML string exists only on the GitHub toast.

## Reporter window

```sql
SELECT ts, app_ver, os_ver, chip, locale, country,
       json_extract(props,'$.source') AS source,
       json_extract(props,'$.stage') AS stage,
       json_extract(props,'$.error_type') AS error_type,
       session
FROM events
WHERE event='transcription_failed'
  AND ts >= '2026-09-09T15:00:00Z'
  AND ts <= '2026-09-09T18:00:00Z'
ORDER BY ts;
```

Per-session `transcription_*` props (file session then YouTube session) used
`session='…'` filters on those two UUIDs from the window query.

## Long-file STTError.transcriptionFailed by source

```sql
SELECT json_extract(props,'$.source') AS source,
       json_extract(props,'$.stage') AS stage,
       COUNT(*) AS n,
       COUNT(DISTINCT session) AS sessions
FROM events
WHERE event='transcription_failed'
  AND app_ver='0.7.3'
  AND json_extract(props,'$.error_type')='STTError.transcriptionFailed'
  AND ts >= '2026-08-10T00:00:00Z'
GROUP BY 1, 2
ORDER BY n DESC;
```

## Hour-class file/YouTube/drag-drop outcomes by OS

```sql
SELECT CASE WHEN os_ver LIKE '14.%' THEN 'macos14' ELSE 'macos15plus' END AS os,
       json_extract(props,'$.outcome') AS outcome,
       COUNT(*) n,
       COUNT(DISTINCT session) sessions
FROM events
WHERE event='transcription_operation'
  AND app_ver='0.7.3'
  AND json_extract(props,'$.source') IN ('youtube','file','drag_drop')
  AND CAST(json_extract(props,'$.audio_duration_seconds') AS REAL) >= 3000
  AND ts >= '2026-08-10T00:00:00Z'
GROUP BY 1, 2
ORDER BY 1, 2;
```

## Hour-class meeting outcomes by OS

Same query with `json_extract(props,'$.source')='meeting'`.

## Observed 2026-09-09T18:00Z

File / YouTube / drag-drop, audio ≥ 3000 s:

| OS | success | failure | cancelled |
|---|---:|---:|---:|
| macOS 14 | 2 (1 session) | 33 (19 sessions) | 2 |
| macOS 15+ | 1412 (726 sessions) | 19 (14 sessions) | 44 |

Meetings, audio ≥ 3000 s:

| OS | success | failure | cancelled |
|---|---:|---:|---:|
| macOS 14 | 0 | 11 (9 sessions) | 0 |
| macOS 15+ | 2836 (1585 sessions) | 23 (15 sessions) | 30 |
