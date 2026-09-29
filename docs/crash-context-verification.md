# Crash context verification

This change improves evidence for future crash investigations. It does not fix
the native crashes investigated in September 2026 or prove their root cause.
The [contract](../spec/contracts/telemetry-v1.md#crash-context-and-pending-reports)
defines the finite fields, ownership, privacy, and compatibility boundaries.

## Performance evidence

Measured on Apple M4 Pro, macOS 26.6.2, using optimized C and Swift 6 builds.
Lifecycle measurements use the actual adapter and observer with sink stubs;
they do not start an audio engine. They are batch means, not individual-call
tail latency or real-time deadline guarantees.

| Measurement | Observed result |
| --- | --- |
| Production C recorder, 101 batches of 10,000 calls | Median 2.70 ns/call, p95 batch mean 2.80 ns |
| Startup OS/cache snapshot | 14 microseconds; both metadata fields available |
| Actual typed adapter, 20 batches of 200,000 calls | Median 2.79 ns/call, p95 batch mean 2.83 ns |
| Mapping and packing | Median 17.46 ns/call, p95 batch mean 18.08 ns |
| Four competing adapter writers | Median 40.69 ns/call, p95 batch mean 46.38 ns |
| Paired previous/current observer, changed phase | Median batch means 78.51 / 81.23 ns/call |
| Paired previous/current observer, unchanged phase | Median batch means 26.19 / 25.13 ns/call |
| Prior existing-directory check, 1,000 samples | Median 2.75 microseconds, p95 3.46 microseconds |
| Empty spool reservation, 100 samples | Median 1.165 ms, p95 2.494 ms, max 11.806 ms |
| Full spool reservation with eviction, 100 samples | Median 2.791 ms, p95 5.625 ms, max 13.466 ms |
| Contended queue reservation declined, 1,000 samples | Median 0.491 ms, p95 1.419 ms, max 15.563 ms |

Paired lifecycle results were noisy under other host work; their paired deltas
do not establish a precise incremental cost. An earlier storage run during
compilation reached approximately 196 ms for one reservation. Nonblocking
locks eliminate deliberate waiting, not scheduler or filesystem latency.
There is a measured startup cost. No claim of zero overhead or universal
regression freedom is made.

The C benchmark is reproducible without launching the app:

```sh
xcrun clang -O2 -std=c11 -Wall -Wextra -Werror \
  -I Sources/MacParakeetObjCShims/include \
  Sources/MacParakeetObjCShims/MPKCrashSignalHandler.c \
  scripts/dev/tests/crash_context_probe.c -o /tmp/crash-context-probe
/tmp/crash-context-probe benchmark
```

There is no new callback instrumentation, lifecycle filesystem/network work,
timer, thread, retry queue, or asynchronous logging job per transition. The
32-slot ring uses fixed native storage. Recording drops on contention rather
than waiting for another lifecycle writer. Publication interruption is tested
in a disposable process, including interruption while replacing a full-ring
slot. Detailed history is diagnostic evidence, not a current-state machine.

## Review and verification

Independent reviews covered native publication ordering, late lifecycle
completion, storage ownership, privacy, wire compatibility, and deduplication.
Review found and fixed deletion after a transient report-read failure. A
second review correction preserves local-only history before uploaded reports
are discarded. The archive declines when the existing log requires rotation,
avoiding a large read/rewrite under a lock shared with ordinary logging.
Malformed optional metadata cannot poison a valid crash batch.

The receiver's full telemetry suite passed 151 tests and its website build
passed. The broad app focus exercised 320 XCTest cases plus 26 Swift Testing
cases; its single obsolete per-instance-session expectation was updated to the
new per-process contract. The final targeted rerun passed 88 XCTest cases with
two unrelated opt-in recording kill/recovery tests skipped. New crash/store/
archive/native probes passed. Final full-suite and CI results are recorded in
the PR. The companion receiver is
[website PR #101](https://github.com/moona3k/macparakeet-website/pull/101).
The receiver has no migration or additional database scan. A 1,000-row local
SQLite comparison showed roughly 8–11 ms query medians across old/new grouping;
this is a small synthetic check, not production-scale D1 qualification.

## Remaining release checks

- Deploy and verify the companion receiver before distributing the producer.
- Exercise dictation and overlapping meeting capture on physical microphone
  routes, including Bluetooth and start/stop/recovery transitions.
- Measure signed-app cold launch and ordinary capture under realistic load;
  compare with the previous build before release.
- Confirm a consented native crash/relaunch leaves local diagnostic history,
  sends the original process metadata once per incident after deduplication,
  and keeps those fields out of public stats.

These checks have not been claimed as passed. Existing best-effort backtrace,
SIGKILL/power-loss gaps, finite retention, and incomplete non-cache image
identity remain. A missing breadcrumb never proves that a transition did not
happen.
