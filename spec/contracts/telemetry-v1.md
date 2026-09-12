# Telemetry and diagnostic evidence

This contract governs the existing typed telemetry surface. The event catalog
and envelope are in [docs/telemetry.md](../../docs/telemetry.md); this document
records the September 2026 tightening of privacy and outcome semantics.

## Network event boundary

- Preserve random per-launch sessions, event UUID idempotency, and optional
  telemetry. Audio, transcripts, prompts, filenames, device identities and
  persistent user identifiers are excluded.
- The proposed sharing surface adds no recipient telemetry. Share content,
  selection details, locators, complete URLs and fragments, owner or recovery
  credentials, ciphertext, recipient identifiers, and view activity are
  excluded from this event boundary.
- Omit `error_detail`, `error_occurred.description`, and crash `reason` from
  serialized events. Retaining factory parameters does not permit transmission.
  The paired website ingestion change drops these fields for older clients.
- Retain bounded error categories and safe numeric codes. CoreAudio domain/code
  information may be recovered from the recognized Foundation wrapper format;
  arbitrary numbers, domains and descriptions are not error categories.
- `crash_occurred`'s optional `si_code`, `pc`, and `fault_addr` fields are
  narrow signal-context evidence (fault subtype, interrupted instruction
  pointer, faulting address), not free-form text. The on-disk report parser
  validates each before it reaches the typed event factory — `si_code` must
  contain at most 10 ASCII digits with an optional minus sign and parse
  as a signed 32-bit integer (`Int32`), covering the full range
  including the `-2147483648`/`2147483647` boundaries without signed
  overflow; `pc`/`fault_addr` must be a bounded `0x`-prefixed hex value — and
  drops a corrupted or out-of-range value rather than forwarding it. These
  fields are omitted from non-signal reports, even if present in the file.
- The C signal handler assembles that on-disk report with bounded manual
  byte-appending, not `snprintf` or another allocating/locale-aware
  formatter, and its write path retries on `EINTR` and short writes but gives
  up (without spinning) as soon as `write` reports `0` bytes accepted or a
  non-retryable error. Optional backtrace capture runs only after a complete
  minimum report write; failed writes skip that unsafe step. Persistence of the on-disk report is best-effort:
  `write`/`close` succeeding means the OS accepted the bytes, not that they
  survived a power loss, and a second thread crashing concurrently with the
  first gets no report of its own rather than the handler waiting for the
  first to finish.
- Opt-out clears the queue and invalidates retries and batches waiting behind
  another flush, including batches encoded but not started. Request admission
  and URL task resume share the queue-clear lock. In-flight requests can complete. An explicit final
  `telemetry_opted_out` event is the only disabled-preference exception.
- A thrown cancellation is `cancelled`, not `failure`. Exactly one canonical
  outcome should describe an operation. Breadcrumb counts are separate evidence.
- A successful CLI early exit has `outcome=success`, `exit_code=0` and no
  `error_type`, even when ArgumentParser implements it by throwing.

## Client delivery policy

GUI telemetry defaults off in debug builds, builds marked `dev-*` or `swiftpm-*`,
and versions `dev` or `0.0.0`. `MACPARAKEET_TELEMETRY=1/true/yes/on` explicitly
permits development/CI telemetry; `0/false/no/off` disables it. Without that
explicit override, `DO_NOT_TRACK=1` and recognized CI environments disable it.
The GUI's persisted opt-out remains authoritative even with explicit enablement.
Transport eligibility is separate from consent: environment/CI/development
disabling suppresses every request, including the final opt-out event. Eligible
production sessions may still send their final consent opt-out event. Explicitly
injected clients supply their own policy; omitted eligibility defaults to allowed
when a consent closure is injected, preserving CLI and isolated-client behavior.
The CLI retains its existing explicit-environment precedence. Versioned release
candidate bundles are not evidence of publication; the wire envelope does not
claim a release channel.

Automatic flush requests are coalesced. Network failures, HTTP 408/429 and 5xx
retain event UUIDs for retry with jittered exponential backoff (5 seconds initial,
15 minutes maximum), respecting a longer `Retry-After` delay (seconds or HTTP
date). These delays are minimum retry intervals, not exact delivery deadlines.
The existing 60-second GUI timer attempts eligible retries; explicit and
termination flushes also honor the delay, including for a final opt-out event.
The CLI makes its best-effort flush before exit and does not remain alive for a
later retry. Queued events are not persisted across process exit. Permanent HTTP rejections discard the rejected batch, including any
valid events in that batch, and report delivery failure rather than repeatedly
poisoning the queue. Consent changes invalidate retry timing and queued snapshots.
Local structured `telemetry_transport` logs contain outcomes, numeric status,
batch/drop counts and retry timing, never event props or response bodies.

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

## Enforcement and compatibility

- `TelemetryServiceTests` pins payload encoding, omitted free-form error/crash
  fields, and opt-out admission/queue-generation races.
- `CrashReporterTests` pins old/new/missing/malformed `si_code`/`pc`/`fault_addr`
  round-tripping through the report-file parser, including both `Int32`
  boundaries for `si_code`. `CrashReporterSignalProbeTests` runs the
  production C signal handler in a real subprocess (compiled from the
  checked-in `MPKCrashSignalHandler.c`) to confirm the on-disk report reflects
  the actual interrupted instruction pointer and a `SIG_DFL` process exit, not
  a synthetic value. It also links harness-side `write`/`backtrace`
  overrides ahead of libSystem at compile time (no production test flags) to
  prove the minimal report still lands under short writes, `EINTR`, and a
  failed/empty backtrace or abrupt exit from backtrace. A child-owned alarm
  bounds probe execution. A `write` that always reports 0 bytes
  accepted stops the write loop and skips backtrace instead of hanging.
- `TelemetryErrorClassifierTests` pins bounded error categories and recognized
  native CoreAudio status extraction.
- `CLITelemetryTests` pins successful thrown exits, environment overrides, and
  privacy-safe invocation metadata.
- `AudioCaptureDiagnosticsTests` pins local correlation fields, bridged error
  codes, and append/rotation behavior. The offline parser's synthetic-file
  tests live in `scripts/dev/tests/test_query_audio_diagnostics.py`.

Update the typed event factories, focused tests, and
[telemetry catalog](../../docs/telemetry.md) together when this boundary changes.
A new event name also requires the paired website ingestion allowlist before
clients ship. Preserve existing aggregate fields and the local query's
`schema_version: 1`; breaking changes need an explicit compatibility/version
plan. App-repo tests do not verify the deployed website contract or ingestion.

## Rollout

App changes require a new app/CLI build. Website changes are in the separate
`macparakeet-website` repository and require deployment. Existing stored private
rows and previously cached public responses are not deleted by source changes.
