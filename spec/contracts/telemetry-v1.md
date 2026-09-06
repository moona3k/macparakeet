# Telemetry and diagnostic evidence

This contract governs the existing typed telemetry surface. The event catalog
and envelope are in [docs/telemetry.md](../../docs/telemetry.md); this document
records the September 2026 tightening of privacy and outcome semantics.

## Network event boundary

- Preserve random per-launch sessions, event UUID idempotency, and optional
  telemetry. Audio, transcripts, prompts, filenames, device identities and
  persistent user identifiers are excluded.
- Omit `error_detail`, `error_occurred.description`, and crash `reason` from
  serialized events. Retaining factory parameters does not permit transmission.
  The paired website ingestion change drops these fields for older clients.
- Retain bounded error categories and safe numeric codes. CoreAudio domain/code
  information may be recovered from the recognized Foundation wrapper format;
  arbitrary numbers, domains and descriptions are not error categories.
- Opt-out clears the queue and invalidates retries and batches waiting behind
  another flush, including batches encoded but not started. Request admission
  and URL task resume share the queue-clear lock. In-flight requests can complete. An explicit final
  `telemetry_opted_out` event is the only disabled-preference exception.
- A thrown cancellation is `cancelled`, not `failure`. Exactly one canonical
  outcome should describe an operation. Breadcrumb counts are separate evidence.
- A successful CLI early exit has `outcome=success`, `exit_code=0` and no
  `error_type`, even when ArgumentParser implements it by throwing.

## Aggregate evidence

The website's `/api/stats` keeps its existing aggregate fields. Additive
`freshness` metadata reports snapshot generation, expiry, serving time, age and
`fresh`/`stale` status. A stale fallback is `200` with usable historical data,
`reason=refresh_failed` and `Cache-Control: no-store`; it is not live health.
Public failure rows retain `error_detail: null` for compatibility and merge
historical detail groups into error-category counts. No free-form error text
should be added back to the public response.

Snapshots last 15 minutes; the page polls every five minutes. Time-window counts
are not matched start/completion cohorts. Terminal failure rates require the
corresponding operation denominator, with lifecycle actions separated. Missing
denominators, missing durations, absent local reports and missing telemetry are
unknown evidence. They must not be presented as zero failures or proven health.
`meeting.by_trigger[].both_tracks_present` counts successful meeting outcomes
whose same event reports both tracks. Separate microphone and system-audio
totals cannot establish that intersection. `track_samples` counts successful
outcomes with both track statuses known and supplies the rate's denominator;
show its coverage against successful outcomes. `duration_samples` counts the
successful outcomes with a measured duration. Older snapshots without these
fields have unknown aggregate duration and dual-capture coverage.

Telemetry is best effort: opt-outs, offline events, queue limits, process death
and crashes without a later launch prevent complete population accounting. A
fresh stats snapshot proves a successful read/aggregation, not ingestion health.

## Local diagnostic evidence

The bounded local audio log records event occurrence time, process ID, a random
per-process session, monotonic uptime and audio lifecycle fields. These process
correlation fields are not transmitted as telemetry; an explicit diagnostic
export includes the log. Legacy lines without them remain readable.
The shareable log records structured error type and explicitly named
`bridged_error_code` rather than raw exception text. A bridged Swift enum code
is not an underlying CoreAudio status; recognized native status is retained in
the classified type. File-write failures use the independent system logger.

The [offline query utility](../../docs/local-audio-diagnostics-query.md) returns
bounded JSON evidence with explicit missing, truncated and unparseable states.
It reads the log only. It does not record audio, change app settings, upload
diagnostics or claim that the absence of logged failures means successful audio.

## Rollout

App changes require a new app/CLI build. Website changes are in the separate
`macparakeet-website` repository and require deployment. Existing stored private
rows and previously cached public responses are not deleted by source changes.
