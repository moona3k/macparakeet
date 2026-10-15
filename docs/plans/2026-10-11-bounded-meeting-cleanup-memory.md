# Bound memory during meeting microphone cleanup

Status: implemented; focused checks, independent review and the full local suite passed; PR CI and hosted review pending. Base: `648d0b6f462f60520fccba402ef556c393791fd2`.

## Intent and scope

Reduce app-controlled RAM on all supported Apple Silicon Macs, especially 8–16 GB
systems sharing memory with a call application. Meeting cleanup currently retains
whole decoded microphone, system, and cleaned output arrays. At 16 kHz mono Float32,
three hour-long tracks contain about 659 MiB of PCM before allocation overhead.
This is a concrete post-stop allocation opportunity, not an attribution of #1199.

## Approach

1. Preserve sequential decoding/resampling, but spool decoded Float32 chunks into
   private temporary files opened and immediately unlinked. Open descriptors own
   lifetime, including failure, cancellation, and process exit. No persistent new
   recording artifact or cleanup-on-next-launch requirement.
2. Run the same echo probe using bounded range reads over those decoded samples.
3. Feed the same 4096-sample aligned chunks through the same conditioner, and
   encode output as it arrives. Accumulate RMS statistics instead of full arrays.
4. Retain array helpers for small test fixtures and parity checks; production
   rendering must never materialize a complete decoded track.

## Invariants

Raw source files and recovery metadata remain untouched. Preserve probe candidate
positions, energy thresholds, selected windows, correlation/lag thresholds, start
alignment, conditioner reset/flush, output trim/raw-tail fill, output duration,
statistics, cancellation propagation, and fail-open fallback to raw microphone.
No model, quality, settings, telemetry, public CLI, or hardware-default changes.
Disk failure remains a visible cleanup skip, not lost capture or failed meeting.

## Verification

Completed: focused real codec round trips, bounded-range reads, disk-vs-array
probe parity, stream-vs-array conditioning parity across offsets and flush edge
cases, decode limits and cancellation, scratch lifetime checks, a synthetic
long-track footprint comparison, one full local Swift test suite, formatting,
and independent correctness/maintainability/performance review. PR CI and final
hosted review remain pending; the live PR owns their current status.
No actual Air/Teams reproduction or claim of resolving #1199 from this patch.

## Follow-ups kept separate

Memory-pressure-aware model residency; durable capture ingress backlog; other
engines' full-file decode; library working-set bounds; measured hardware defaults.

## Evidence

See [native measurements and reproduction](../research/2026-10-11-bounded-meeting-cleanup/README.md).
One-hour synthetic renderer peak footprint fell from 987–988 MiB to 24–26 MiB;
two-hour candidate remained about 26 MiB. This is isolated pipeline evidence,
not a full-app or affected-hardware claim.

Full local suite on the initial implementation commit
`9b7c383299e583fdc71fb68e8c0e25d0852fcfbf`: 8086 XCTest cases (34 skipped) and
30 Swift Testing cases passed, zero failures. The suite is not rerun for later
review follow-ups, which rely on focused tests. PR CI and hosted review are not
yet recorded.

Review follow-ups passed 19 focused scratch/renderer tests, strict source lint,
60-second echo/no-echo harness runs, invalid-mode rejection, and independent
review of atomic scratch ownership and the strengthened bounded-read assertion.
