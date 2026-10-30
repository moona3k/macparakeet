# Bounded-memory meeting microphone cleanup

The renderer now decodes sequentially to private, immediately unlinked Float32
scratch files, probes bounded ranges, and conditions/encodes output incrementally.
This removes three recording-length PCM arrays without changing the speech model,
echo policy, source alignment, source recordings or user defaults.

## Native A/B evidence

Host: Apple M4 Pro, 48 GiB unified memory, macOS 26.7.1 (25G241), arm64. Baseline:
`648d0b6f462f60520fccba402ef556c393791fd2`. The optimized Swift harness compiles the
actual baseline and candidate renderers in one executable, with actual codec,
scratch and delay-estimator code. Adjacent app metadata/error types are minimal
stubs. A deterministic synthetic conditioner replaces LocalVQE. Source files are
created incrementally as 16 kHz mono Float32 CAF; output uses the real AAC writer.
Each arm is a separate process. No app database, user audio or models are used.

| Fixture | Baseline peak footprint | Candidate peak footprint | Candidate peak RSS |
| --- | ---: | ---: | ---: |
| 5-minute echo-positive source | not run | 23.99 MiB | 38.16 MiB |
| 60-minute echo-positive source | 987.10 MiB | 23.91 MiB | 38.06 MiB |
| 60-minute echo-positive repeat | 988.16 MiB | 25.61 MiB | 39.75 MiB |
| 120-minute echo-positive source | not run | 25.74 MiB | 39.88 MiB |
| 60-minute silent reference / no echo | 765.89 MiB | 20.81 MiB | 29.28 MiB |

A separate 60-second actual AAC encode/decode comparison produced **960,000
frames and identical decoded PCM SHA-256** in both arms:
`fc78034c1932a2bb2bd70c7f0123e11e0f5351c012babdaea2e0fb91793ba88d`.
The decoder initially attempted an extra read past the AAC file's declared frame
count and failed in the probe; the harness now stops at `AVAudioFile.length`.
This affected only the added verification digest, not either renderer.

Both renderers produced the expected exact source duration and 0.5 output/raw RMS
ratio for echo-positive fixtures, and the same `no_reference_energy` skip for the
no-echo fixture. Raw `/usr/bin/time -l` logs and [measurements.tsv](measurements.tsv)
record process peak footprint and RSS separately. The drop is about **97–98% for
this isolated stage**, not the whole app. Candidate memory remains roughly flat
across 5–120 minutes instead of scaling with decoded source duration.

These runs share a development host with other work, including tests during some
arms; they are not a controlled throughput or energy benchmark. First-pair render
elapsed times were 2.45 vs 2.66 seconds for echo-positive and 0.26 vs 1.19 seconds
for no-echo. The extra scratch I/O has a cost even when the echo probe skips. CAF
avoids source compression; production M4A input, real LocalVQE processing, slower
or nearly-full disks and actual Air hardware still require qualification.

## Correctness and bounds

- Focused renderer/scratch/readiness/artifact-cleanup tests: 26 passed.
- After review, 19 scratch/renderer tests passed again with atomic close-on-exec
  creation and the stronger probe-read assertion. The 60-second streaming
  echo/no-echo fixtures passed; the echo PCM hash remained identical. Invalid
  benchmark modes exit with status 2 before compilation or fixture creation.
- Independent extracted-old-vs-new conditioning probe: 640 exact-sample cases
  across offsets, empty/unequal tracks, chunk boundaries and flush behavior.
- Production conditioning reads at most 4096 samples per source per step. Probe
  reads at most a 10-second window (160,000 floats at 16 kHz), independent of
  duration. Tests exercise a synthetic 10-minute source without allocating it.
- Tests cover real AAC round trips, two-channel 44.1 kHz resampling parity,
  scratch range reads, decoded limits, missing scratch directory, read failures,
  raw-tail fill/over-flush trim, online RMS, and no-echo conditioner avoidance.
- Integrated cancellation after the first AAC append removes derived output and
  preserves source file bytes; writer-creation failure also preserves sources.
- Touched product code passes strict swift-format lint. The standalone reproduction
  script also compiles the changed rendering path in Swift 6 language mode.

The sequential converter is unchanged: compressed files are not randomly sought
and independently resampled for each probe window. The conditioner receives the
same 4096-sample cadence. Encoding pulls the next conditioned block only after
appending the previous one, so writer backpressure cannot queue a whole output.

## Storage and privacy tradeoff

Scratch uses approximately **220 MiB per hour per source**, released at render
completion/skip/failure/cancellation. The scratch file is owner-only, its
directory entry is removed immediately after creation, and its descriptor is
atomically created close-on-exec so an executed helper cannot retain it, even
when launched concurrently with scratch creation. Descriptor ownership
releases the storage on process exit, with no new discoverable persistent audio
artifact. Scratch I/O errors follow the existing observable raw-source fallback.
No audio or model cache is deleted to free RAM.

This does not repair unbounded capture ingress, speech/diarization model residency,
other engines' whole-file decoding, or Library caches. It does not establish the
root cause or resolution of issue #1199, whose reported trigger includes Teams
and meeting start. No default is disabled on older Macs by this patch.

## Reproduce

Run from the branch's own worktree on macOS:

```sh
docs/research/2026-10-11-bounded-meeting-cleanup/run.sh baseline 3600
docs/research/2026-10-11-bounded-meeting-cleanup/run.sh streaming 3600
docs/research/2026-10-11-bounded-meeting-cleanup/run.sh streaming 7200
docs/research/2026-10-11-bounded-meeting-cleanup/run.sh baseline 3600 no-echo
docs/research/2026-10-11-bounded-meeting-cleanup/run.sh streaming 3600 no-echo
```

The script creates and removes only its own temporary build and synthetic audio.
Allow roughly 440 MiB/hour for two input CAFs plus another 440 MiB/hour for candidate
scratch (not counting filesystem caches or the encoded output). The harness now
also prints a streaming SHA-256 of decoded AAC output for cross-arm parity;
initial footprint logs predate that added digest pass. The harness exits non-zero
if the echo fixture skips, or if the no-echo fixture renders or skips for any reason
other than `noEchoPath` with `no_reference_energy`.
