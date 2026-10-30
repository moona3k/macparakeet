# Back-to-back meeting capture (#1291)

## Context and invariants

Stop currently awaits playback mixing before queue admission. Release capture only after callbacks/writers settle and source metadata/notes/lock are durable. Queue owns derived playback and final transcription. A must never clear B's capture, notes, selected engine, lease, or UI. Preserve source audio and retry/recovery ownership on failure, canonical row identity, source alignment/fallback, and completed playback duration.

Out of scope: activity detection, a pending-start queue, new capture engines, new generic schedulers, changes to STT priority, merging or releasing.

## Work

- [x] Split saved capture from prepared playback; reuse the existing builder and queue.
- [x] Cover admission, source-only Retry/recovery, and pending audio presentation.
- [x] Add behavioral regression tests and update contracts.
- [ ] Review exact committed diff independently and with Greptile if available.
- [ ] Open PR and inspect exact-head GitHub CI/review results.

Validation: fresh local dependency builds are avoided (7 GB disk available). GitHub CI compiles/tests the complete change. Local parsing/format and focused checks that do not require a new build are permitted. Native long-meeting/device testing remains a separate qualification gate.

Initial base: a388b7d449c722875f24e26df35acecf881dd35e. The original dirty checkout is untouched. no-mistakes is not on PATH; use the documented review workflow.

## Implemented shape

`MeetingRecordingCapture` holds saved sources/lock/metadata. `MeetingFinalizationInput`
distinguishes that capture from ready `MeetingRecordingOutput`. The additive
`stopForFinalization` interface returns capture early in production and preserves
ready-output adapters. The queue prepares playback before final STT, with the
existing per-folder ownership lease. Completed output duration stays measured.

Tests cover actual B source writes during blocked A playback, fallback and
cancellation, flow presentation after success/failure, queue FIFO/failure
isolation, missing-playback Retry, source-only crash recovery row reuse, lock
relinquishment, pending-audio eligibility, and CLI optional-duration output.
Existing settlement/writer-failure coverage remains intact. Compilation and
behavioral results are pending GitHub CI; local Swift syntax parsing and format
checks passed. No native audio qualification is claimed.
