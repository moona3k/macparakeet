# Query local audio diagnostics

Run the offline maintenance utility from the MacParakeet checkout:

```sh
python3 scripts/dev/query_audio_diagnostics.py --since 2026-09-06T00:00:00Z --limit 100
python3 scripts/dev/query_audio_diagnostics.py --event dictation_capture_stop --event dictation_capture_unavailable
python3 scripts/dev/query_audio_diagnostics.py --path /tmp/copied-audio.log --process-session PROCESS_SESSION_FROM_A_RECORD
```

It reads `~/Library/Logs/MacParakeet/dictation-audio.log`, performs no network
requests, and never modifies the source. `--path` overrides
`MACPARAKEET_AUDIO_DIAGNOSTICS_LOG_PATH`, which overrides the usual location.
When `MACPARAKEET_DEBUG_APP_STATE_DIR` is set for a debug app, the default is
`<debug-root>/logs/dictation-audio.log`. Explicit paths are useful for copied
support attachments. The utility does not open audio, transcripts, or databases.

JSON output has `schema_version: 1`. `records` contains timestamp, event, and
parsed `fields`; field values stay strings, including booleans and numbers.
Quoted values such as `reason="no usable buffers"` remain one field. Historical
lines without process fields remain valid. Raw lines and unstructured text are
omitted; this is a local inspection tool, not a privacy scrubber for attachments.

The scan reads at most 5,000,000 tail bytes, plus one look-behind byte when the
file is larger. `scan.bytes_read` counts tail bytes and
`scan.boundary_probe_bytes` counts the separate boundary probe (zero or one).
Partial first/last lines and malformed UTF-8 or quoted fields are counted in
`scan` and omitted. `scan.changed_during_read` reports a detected concurrent
file change; retry the query if a stable copy is needed. Rotation can already
have removed older evidence, even when `scan.truncated` is false.

`--since` is inclusive and requires an explicit timezone. Repeated `--event`
values are alternatives, combined with the other filters. `records` returns
the newest timestamps first, with physical file order breaking timestamp ties;
the return limit is 1–1,000. The scan checks every complete line because async
appends and clock changes can make timestamps differ from file order.
`event_counts` and `matched_records` cover **all matching records in the scanned
tail**, before the return limit; they are not lifetime totals.

Always inspect `status` and the scan counters before drawing conclusions:

- `available`: matching records were read; this says nothing about capture health.
- `missing`, `empty`, or `unparseable`: no usable evidence was available.
- `no_matches`: parsed records exist, but the requested filters matched none.
- `unreadable`: the source could not be opened as a regular file; `scan.error_code`
  is the OS error number. The command exits 1 for this status and 0 for the other
  completed queries; invalid arguments exit 2.

New records carry `process_id`, a random per-launch `process_session`, and
monotonic `uptime_ns`. Filter by `process_session` to separate app/CLI launches.
Use `uptime_ns` within a process to reason about wall-clock corrections or
delayed writes. This local ID is distinct from the network telemetry session
UUID. It is not a user ID or a capture-operation ID.

For a dictation incident, inspect `dictation_capture_start`,
`dictation_capture_first_buffer`, `dictation_capture_stop`, and terminal
`dictation_capture_unavailable` / `dictation_capture_insufficient` events.
The stop record carries input/output buffer counts, input frames, effective
sample count, audio/wall durations, max RMS/level, non-silent buffers, invalid
formats, and the first-buffer timeout bit. Shared-mic recovery events explain
callback stalls, exact-zero input, route-change retries, and terminal recovery
exhaustion. Meeting mic and system-audio first-buffer/stall events distinguish
the two sources. Combine these observations; a missing stop record is unknown,
and low signal alone is not proof that an engine stopped.

The log retains only about 5 MB and best-effort writes can fail. New file sink
failures are reported through OSLog's `AudioCaptureDiagnostics` category as
`audio_diagnostic_write_failed`. Shareable file error fields contain classified
type and `bridged_error_code`; separately privacy-marked OSLog details may provide more
context locally. Legacy file contents retain their original privacy limitations.
The bridged code can be a Swift enum ordinal, not the underlying audio status.
For recognized CoreAudio wrappers, `error_type` retains the native domain/status.

App and CLI writers coordinate file creation, append and rotation through the
stable sibling `dictation-audio.log.lock`; preserve this file. The advisory lock
coordinates participating writers, including separate processes. It does not
lock readers or coordinate with older app versions that do not acquire it.
Main-thread writes that encounter contention or require log rotation are
deferred to the existing utility queue with their original timestamps and fields; OSLog reports
`audio_diagnostic_write_deferred`. A query before that queue drains can miss
those pending records, and process exit can prevent their best-effort write.

Run the deterministic synthetic-file tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/dev/tests -p 'test_query_audio_diagnostics.py'
```
