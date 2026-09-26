# Issue #924 audio-only process-tap probe

Status: experiment only; not a production backend.

This probe answers one narrow question from issue #924: can a Core Audio
process tap capture deterministic system playback when MacParakeet does not
start a microphone or VPIO path? It does not reverse ADR-014, compare long-run
reliability with ScreenCaptureKit, or establish compatibility across macOS
versions and output devices.

The probe:

- creates a global Core Audio process tap and a tap-only private aggregate
  device, without a physical input or output subdevice;
- requests neither microphone input nor screen pixels;
- plays a generated 997 Hz stereo WAV through `/usr/bin/afplay`;
- records callback count, captured frames, RMS, peak, and 997 Hz amplitude;
- performs target-frequency analysis with a fixed oscillator recurrence rather
  than per-sample trigonometric calls on the Core Audio callback queue;
- checks removal of the IO callback, aggregate device, and process tap before
  accepting each lifecycle cycle;
- exits nonzero if tap creation fails, no frames arrive, or the measured signal
  does not clear the declared 0.005 RMS and target-amplitude floors;
- retains completed-cycle measurements and the failing cycle in failure JSON.

Run from the repository root:

```bash
scripts/run-process-tap-audio-only-probe.sh /absolute/output/directory
```

The runner compiles an ad-hoc-signed probe with a stable identifier and writes
`environment.txt`, `result.json`, stdout/stderr, the probe binary, and the
generated WAV into the supplied evidence directory. The directory must not
already contain any of those managed files; the runner fails instead of
deleting or reusing earlier evidence. Validation uses macOS's built-in
`plutil` and `awk`, so `jq` is not required. On deadline, the runner first
terminates the probe's `afplay` child and gives the Swift process a bounded
window to execute checked teardown before escalating process termination. Cleanup is confined to the probe and
its private process group, including orphaned children; it never searches for
unrelated players by WAV filename. A
deadline or SIGINT/SIGTERM after probe launch always leaves canonical
`result.json` with `status: FAIL`; any result written after the runner's
boundary is retained separately for diagnosis and cannot masquerade as the run
outcome. An interruption during compilation, signing, or environment capture
cannot leave a PASS result and requires a fresh output directory. A result from
one machine is
`SAFE-TO-TEST` evidence only. Product integration still requires maintainer
agreement, permission UX design, fallback policy, device/route coverage, and
reproduction of the previously documented VPIO conflict boundary.

By default the probe performs one create/capture/destroy cycle. Repeated cycles
exercise teardown and re-creation in the same process, so a later cycle exposes
stale aggregate-device or process-tap state instead of process exit hiding it:

```bash
MACPARAKEET_PROCESS_TAP_PROBE_CYCLES=20 \
MACPARAKEET_PROCESS_TAP_PROBE_DEADLINE_SECONDS=90 \
scripts/run-process-tap-audio-only-probe.sh /absolute/output/directory
```

`result.json` retains per-cycle format and signal measurements and requires
every requested cycle to capture the generated tone above the declared floors
and complete checked teardown. A failed later cycle keeps all earlier cycle
measurements and names the failing cycle.

## 2026-09-16 result

The probe passed twice as a fresh process on one physical Apple Silicon host:

| Run | Host/output | Format | Callbacks | Frames | RMS | 997 Hz amplitude |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | macOS 26.6.2 (25G83), `BuiltInSpeakerDevice` | 48 kHz stereo float32 | 328 | 167,936 | 0.186477 | 0.199056 |
| 2 | macOS 26.6.2 (25G83), `BuiltInSpeakerDevice` | 48 kHz stereo float32 | 287 | 146,944 | 0.199352 | 0.227493 |

Both runs created the Core Audio process tap, captured the generated tone above
the declared floors, and exited normally. The microphone and VPIO paths were
not started. The existing production path was not edited; its focused
regression suites also passed:

- `swift test --filter ScreenCaptureLifecycleTests`: 17 tests, 0 failures.
- `swift test --filter MeetingAudioCaptureServiceTests`: 36 tests, 0 failures.

This result directly demonstrates short, audio-only process-tap feasibility on
the named host. It does **not** demonstrate the first-run permission prompt or
permission migration for MacParakeet's signed app, coexistence with VPIO,
long-run stability, route/device changes, sleep/wake recovery, or support on
other macOS releases. `permissionOutcome: process_tap_created` records API
success, not a claim about which consent UI the user saw.

## 2026-09-17 same-process lifecycle result

The probe then completed 20 tap/aggregate create, capture, stop, and destroy
cycles in one process on the same physical host. All 20 cycles captured the
997 Hz tone and retained the same 48 kHz, stereo Float32 format and
`BuiltInSpeakerDevice` observed as the default playback-output UID:

| Cycles | Failed | Total frames | Frames/cycle min–max | Minimum RMS | Minimum 997 Hz amplitude |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 20 | 0 | 2,949,120 | 129,536–160,768 | 0.190588 | 0.207932 |

Because the cycles run without exiting the probe process, a broken teardown
that prevents a subsequent process tap or aggregate device from delivering
audio fails the next cycle. This adds bounded lifecycle evidence; it does not
establish long-duration stability or prove that Core Audio has removed every
internal object immediately after each public destroy call.

## Runner regression checks

`python3 scripts/tests/test_process_tap_runner.py` checks success, timeout,
SIGTERM, and an orphaned player after a probe crash. It requires Python 3 and
Xcode command-line tools. Build/sign steps and audio capture are substituted
with fixtures; real process groups, signals, and result validation are exercised.
A silent player fixture mimics `afplay` with the same WAV argument in another
process group, and must survive every cleanup path. These checks do not request
audio permissions or establish physical capture behavior.
