# Agent-debug telemetry and local logging

Date: 2026-09-13. Status: implemented in this change. Reference:
[Logging Sucks](https://loggingsucks.com/).

## Verdict

MacParakeet already uses the right desktop translation of wide events:
one `*_operation` outcome per product workflow, plus the bounded
`audio_engine_lifecycle` snapshot for native microphone work that may
never return. The remaining holes are joinability, build provenance, and
delivery. They keep agents from answering “what happened to this
recording?” from telemetry or `dictation-audio.log` without grepping.

This change enriches those existing records. It does not add per-phase
log lines, user identity, sampling, crash-safe telemetry persistence, a
ScreenCaptureKit observer, or a new diagnostic-export product surface.

## What an agent needs

A future agent watching production or a user-supplied log should be able
to:

1. Identify the exact binary (`app_ver` + `git_commit` + `build_number`).
2. Join engine snapshots to the meeting or dictation that owned capture.
3. Distinguish “capture start never completed” from “capture started and
   later failed,” without inferring from missing tracks.
4. Follow the same join in the local audio log when telemetry is off or
   the process never flushed.
5. Trust that a new event name cannot ship without the website allowlist.

## Approaches considered

1. **Enrich the current wide events and local lines** (chosen). Add
   `workflow_id` / `consumer` to engine snapshots, `capture_start_completed`
   to `meeting_operation`, build identity on the envelope, and the same
   correlation on local audio lines. Pair with a website validator update
   and the allowlist CI guard.
2. **New diagnostic events for every subsystem.** Rejected: that recreates
   the article’s 17-line request. The engine already has a checkpoint plus
   a terminal; product workflows already have `*_operation`.
3. **Docs-only query recipes.** Rejected: agents still cannot join or tell
   builds apart.

Assumption that would falsify the top pick: the website Worker’s strict
`audio_engine_lifecycle` validator would drop `workflow_id` / `consumer`,
and unknown envelope fields would 400 the whole batch. Both are true
today, so the website companion is required before an emitting app
release.

## In scope

| Gap | Record | Why this field |
| --- | --- | --- |
| GCD drops TaskLocal at the audio queue | `audio_engine_lifecycle.workflow_id`, `consumer` | Process-wide capture correlation stamped before `queue.sync`. `workflow_id` matches the parent `*_operation`. `consumer` is `meeting` or `dictation` so slow starts are filterable without a join. Idle prepare/stop omit both. |
| Failed start looks like a bad source mode | `meeting_operation.capture_start_completed` | Explicit boolean on the product event. `false` on `stage=start_recording` with no recording output; `true` when output exists. |
| `app_ver` cannot tell notarized vs `main` vs local | Props `git_commit`, `build_number` on every queued event | `BuildIdentity` already has these. D1 only persists known envelope columns, so identity is copied into `props` rather than new envelope fields. Hex SHA or `unknown`; build number is the existing plist/env value. |
| Local log cannot join to telemetry | `workflow_id` / `consumer` on audio log lines while capture correlation is active | Same IDs as the network snapshot. Captured at append time so a deferred write cannot pick up a later session. |
| Unknown event names 400 mixed batches | `scripts/ci/check-telemetry-allowlist.sh` | Recovers the existing guard and fails CI when Swift emits a name the Worker will reject. |

## Out of scope

- Diagnostic export bundle (feedback can already attach `dictation-audio.log`).
- ScreenCaptureKit lifecycle observer (no evidenced hang after the mic-gated start).
- Worker-side email/API-key redaction (defense in depth, not this gap).
- Tail sampling (volume is still low).
- Counting `slow` checkpoints as meeting failures.
- Putting `build_source` or paths on the envelope.

## Rollout

Deploy the website validator **before** releasing an app that emits the
new lifecycle props. Extra `meeting_operation` props and ordinary-event
`git_commit` / `build_number` keys are accepted by the existing
ordinary-event path. Unknown `audio_engine_lifecycle` keys are dropped
silently, which would hide the join and build identity on that event.

## Query recipes

Telemetry (after both deploys):

- Slow meeting mic starts: `event=audio_engine_lifecycle` `consumer=meeting`
  `outcome=slow`.
- Same attempt: group by `attempt_id`, then join `workflow_id` to
  `meeting_operation` / `dictation_operation`.
- Capture never started: `meeting_operation` `stage=start_recording`
  `capture_start_completed=false`.
- Build: group failures by `git_commit` / `build_number`, not `app_ver`
  alone.

Local:

```sh
python3 scripts/dev/query_audio_diagnostics.py --event audio_engine_lifecycle --limit 100
```

Group by `attempt_id`. The same `workflow_id` appears on neighboring
capture lines in that process while the correlation is active.
