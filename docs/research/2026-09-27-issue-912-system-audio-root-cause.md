# Issue #912: missing system audio in Phone and FaceTime calls

Date: 2026-09-27. Status: investigation; call-capture fix not yet qualified.

## Verdict

The Phone/FaceTime report most strongly points to a macOS call-audio path that
MacParakeet's ScreenCaptureKit stream does not receive on the reporter's setup.
The supplied system recording contains two short signal bursts and long runs
of exact zeros. The microphone, source-file writer, and finalization keep
working. Missing speech is already absent from the saved system source, before
final transcription, diarization, or playback mixing can affect it.

That localizes the failure but does **not** establish the exact macOS mechanism.
There is no capture of the original stereo ScreenCaptureKit callbacks, no
timestamp for call connection, no output-route trace, and no controlled
ScreenCaptureKit/Core Audio comparison on the affected machine. Treat the
daemon-routing explanation as a corroborated hypothesis, not an Apple-confirmed
restriction or proof that a particular replacement will work.

The original issue and the later comment must remain separate investigations:

| Report | Distinguishing evidence | Conclusion |
| --- | --- | --- |
| Original, 0.7.3 | Whole system tracks reportedly zero; long-lived process; a separate SCK probe worked; app restart restored a `say` control | Consistent with process-local capture state; native cause unresolved. The control was not the same failing call. |
| Rodentia, 0.8.3 | Phone/FaceTime specific; ringing retained; call speech absent; restarts/reinstall do not help | Stronger fit for a call-specific capture/route limitation than stale app state. |

Sources: [original issue](https://github.com/moona3k/macparakeet/issues/912) and
[Rodentia's report](https://github.com/moona3k/macparakeet/issues/912#issuecomment-5704649136).

## Scope and invariants

This investigation compares the report's exact 0.8.3 revision
`1340d0b476650ec5dc99c2160ed809ea6f60df45` with fetched development revision
`67e06d2e366a4af92a39bf7866754169132fb9bc`. The original 0.7.3 report identifies
`d6321f87dccecf29bd4792113f522bb0c98d1f35`.

Preserve source audio, source selection, pause/mute semantics, capture ownership,
and local processing. Silence alone must not stop, restart, or discard a
recording. A passing synthetic-tone probe must not be described as successful
Phone/FaceTime capture. No transcript or raw attachment belongs in this document
or new network telemetry.

## Attachment measurements

Downloaded all three attachments directly from the issue comment. The file
names say `.m4a`; inspection confirms AAC audio in M4A containers. No audio was
sent to a transcription service. Measurements below come from local FFmpeg
decoding; identification of the bursts as ringing comes from the reporter.

| Artifact | SHA-256 |
| --- | --- |
| [system-raw.m4a](https://github.com/user-attachments/assets/f22aaeb4-e66a-4278-9e21-c4333d560059) | `89cc6d70b42ea299e20dfbe11ef8fd2cb43fbb71c8fad27dad1804fa174b5cfc` |
| [meeting-playback.m4a](https://github.com/user-attachments/assets/a8139966-22de-4535-ab74-956758fe664f) | `75200e2327c5aca8981548b05b61e824731ad5f147da7488ecb481004cbedc57` |
| [dictation-audio.log](https://github.com/user-attachments/files/32309479/dictation-audio.log) | `d800442f54e899c73f54b986538946fd3f22f6b68928a61a0c3247d4b6bdbc0e` |

| Measurement | System source | Mixed playback |
| --- | ---: | ---: |
| Encoded sample rate | 48,000 Hz | 48,000 Hz |
| Encoded channels | 1 | 2 |
| Container duration | 32.853333 s | 32.800000 s |
| Decoded frames | 1,574,848 | 1,574,912 |
| Overall RMS | -56.570 dBFS | -32.617 dBFS |
| Absolute sample peak | -35.005 dBFS | -2.804 dBFS |

AAC priming/padding and container timelines can make decoded-frame duration
differ from container duration. Do not infer missing
capture from that small discrepancy. Measurements include the decoder's
returned tail; time coordinates are relative to that decoded stream.

The system source has nonzero samples only in the one-second windows 4–7 s and
25–28 s. Every decoded sample in the complete interval **7–25 s is exactly
zero**, not merely below a quiet threshold. The longest exact-zero run spans
18.944 seconds. There is also exact silence before 4 s and from 28 s through
the tail. A lifetime peak obscures these intervals.

The final playback has substantial signal during multiple windows in the
18-second central system gap, consistent with the reporter's working mic.
That observation does not establish what the remote party said or exactly
when the call connected.

## What the diagnostic log establishes

The 57-line attachment covers one capture shortly after app launch:

| Time (UTC) | Observation |
| --- | --- |
| 21:04:16.194 | 0.8.3 process diagnostic session starts |
| 21:04:25.718 | SCK starts and reports its first 48 kHz, 2-channel buffer |
| 21:04:27.019 | Initial Bluetooth microphone attempt times out with zero callbacks |
| 21:04:27.334 | Retry receives a nonzero 24 kHz, mono microphone buffer |
| 21:04:27.338 | Microphone startup succeeds; `vpio=false` |
| 21:04:58.548 | System stream stops normally |
| 21:04:59.389 | Final health summary: 32.8 s system coverage, no capture failure |

Relevant final values are `system_frames=1574400`, `system_coverage=1.000`,
`system_peak_level=0.018`, `system_signal=present`, and
`system_chunks_enqueued=0`. There are no system recovery/stall events in this
attachment. The recovered microphone delivers 179 nonzero buffers and four
silent buffers. The log identifies **Bluetooth input**, not the exact output
device or a Bluetooth output-profile transition.

The microphone startup failure recovered. Whether starting or retrying
Bluetooth input changed the call's audio route remains untested. MacParakeet's
native VPIO was disabled; the log does not identify other apps' audio processing.
Software LocalVQE processed the microphone; it does not erase `system-raw.m4a`.
The offline mic-cleaning pass subsequently skipped for lack of reference energy.

## Code path and eliminated explanations

```text
SCStream audio callback (48 kHz stereo)
  → CMSampleBufferToPCMBuffer (copies PCM)
  → MeetingAudioCaptureService system event
  → MeetingRecordingService
       → MeetingAudioStorageWriter → retained mono system-raw.m4a
       → live chunker/VAD → provisional transcript
  → saved-source final transcription/diarization and playback rendering
```

The relevant capture, converter, and source-writer implementations are unchanged
between the reporter's 0.8.3 commit and the reviewed development revision.

1. **No Phone/FaceTime exclusion in our filter.**
   [SystemAudioStream](https://github.com/moona3k/macparakeet/blob/1340d0b476650ec5dc99c2160ed809ea6f60df45/Sources/MacParakeetCore/Audio/SystemAudioStream.swift#L385-L404)
   captures a display with no excluded windows, enables audio, and excludes only
   MacParakeet's own process. Apple's
   [property documentation](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio)
   describes that self-exclusion. Turning it off is not a justified call fix.
2. **Buffer liveness cannot establish audibility.** The first-buffer and
   heartbeat watchdogs measure callback arrival. Valid zero-valued buffers
   satisfy both. Restart recovery is reached for absent/interrupted delivery,
   not merely quiet content. Changing this to restart every silent stream would
   interrupt valid one-sided recordings and still might not expose call audio.
3. **The source writer runs before live VAD/STT.**
   [MeetingRecordingService](https://github.com/moona3k/macparakeet/blob/67e06d2e366a4af92a39bf7866754169132fb9bc/Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift#L1573-L1603)
   writes the system source before feeding preview samples. Lowering VAD
   thresholds, changing STT models, or changing diarization cannot recover speech
   absent from the saved source.
4. **`system-raw` is not an untouched SCK dump.** It is downmixed and encoded.
   Nevertheless, right-channel-only input and inverse stereo already have
   explicit preservation logic and file-decoding tests in
   [MeetingAudioStorageWriterTests](https://github.com/moona3k/macparakeet/blob/67e06d2e366a4af92a39bf7866754169132fb9bc/Tests/MacParakeetTests/Audio/MeetingAudioStorageWriterTests.swift#L116-L142).
   Arbitrary conversion defects are not disproved without the original stereo
   callbacks, but simple channel-zero selection and equal/opposite cancellation
   are poor explanations for this revision.
5. **Signal presence is not speech completeness.**
   [MeetingSystemAudioSignalVerdict](https://github.com/moona3k/macparakeet/blob/67e06d2e366a4af92a39bf7866754169132fb9bc/Sources/MacParakeetCore/Services/MeetingRecording/MeetingSystemAudioSignalVerdict.swift)
   deliberately answers whether any retained sample was nonzero. The ringtone
   satisfies that predicate. It does not claim that the far side was captured.
   `capture_quality=healthy` separately describes successful source coverage;
   the [artifact contract](../../spec/contracts/meeting-artifacts-v1.md)
   deliberately treats valid silence as healthy capture. Do not redefine that
   field to mean that every expected speaker was heard.

## External evidence and its limits

The developer of Thunder Kitty describes losing the far side of Continuity
calls under SCK, attributes Phone/FaceTime audio to system daemons, and reports
success after using Core Audio taps with the correct audio-capture permission
configuration. This is useful first-hand corroboration, not documentation of
Apple's internal routing or a guarantee across OS/device combinations.
([Implementation account, 2026-05-24](https://www.thunderkitty.app/learn/2000-buffers-of-nothing/))

Meetmouse also records failed FaceTime/Phone capture under SCK. Its subsequent
live test even lost microphone input, unlike Rodentia's attachment. This
difference argues against presenting any one route's behavior as universal.
([Project decision log](https://github.com/noahdevkagan/meetmouse/blob/main/decisions.md#2026-08-09--apple-calls-sck-cannot-hear-call-audio--mic-only))

An OBS report independently describes missing FaceTime far-side audio after an
upgrade and downgrade, while acknowledging inconsistent reproduction across
users. It provides no verified fix.
([OBS #11561](https://github.com/obsproject/obs-studio/issues/11561))

Apple documents Core Audio taps as a supported way to capture process output,
including the required `NSAudioCaptureUsageDescription` and the recording
permission prompt. It does **not** certify that the API fixes this particular
Phone/FaceTime failure.
([Apple sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps))

## Best fix direction

**Qualify an alternative system-audio backend against the actual call before
changing production capture.** If SCK receives zeros while a Core Audio tap
receives the remote voice in the same controlled call, the appropriate capture
repair is a backend implementation behind the existing system-source boundary.
Retain the writer, source alignment, live/final transcription, and artifact
contracts. Do not solve a capture failure in VAD, STT, or the mixer.

The existing `MeetingSystemAudioCapturing` protocol and
`systemAudioCaptureFactory` in `MeetingAudioCaptureService` already provide
that seam. A qualified implementation can use it without adding another
capture coordinator or changing the meeting workflow.

MacParakeet already has a
[Core Audio feasibility probe](issue-924-audio-only-process-tap-probe.md), but
its generated-tone success proves only that narrow no-microphone/no-VPIO
topology. [ADR-014](../../spec/adr/014-meeting-recording.md) adopted SCK after
process taps conflicted with VPIO. The current raw-mic default reduces one
conflict risk; it does not establish coexistence during dictation, microphone
route transitions, or another app's voice-processing session.

The current probe cannot be pointed at a call unchanged: it plays its own tone,
inspects channel zero, and requires that tone for PASS. A call experiment needs
an explicit external-input observation mode with no generated playback and
per-channel measurements over time, reusing its bounded runner and checked
teardown. Nonzero samples alone must never become a “call captured” verdict.

Before selecting Core Audio as a production replacement, verify:

- A consented real Phone/Continuity call and a separate FaceTime call, including
  remote speech after connection. Compare against a same-route ordinary-media
  control. Keep media off during the remote-speech interval.
- Simultaneous SCK/tap observations, followed by each backend separately to
  detect interference introduced by the probe itself. Measure each original
  input channel before mixdown; retained mono is a second boundary.
- Built-in/wired output and the reporter's Bluetooth route, plus microphone
  capture on/off. Record the call application's selected output as well as
  macOS's default output; they need not be the same.
- Permission denial/revocation, late start, stop/cancel, device changes,
  sleep/wake, and coexistence with raw mic, dictation, and explicitly requested
  VPIO. Keep cleanup ownership and bounded start/stop guarantees.
- Signed-app permission behavior. An ad-hoc research probe's consent is not
  permission migration evidence for the distributed app.

If both backends miss the remote voice, investigate the selected route and
platform restrictions. If SCK input contains speech but retained mono does not,
repair the conversion boundary. If a new SCK process works for the same failing
source while the long-lived app does not, isolate process/session ownership
before introducing a new backend. These outcomes lead to different fixes.

A repeated automatic restart on silence is not the preferred fix: silence can
be valid, the Phone report survives a restart already, and restarts create more
capture gaps. Likewise, do not declare FaceTime categorically unsupported from
one report or silently fall back to acoustic speaker pickup.

## Reproduce the file measurements

The companion [local analyzer](../../scripts/dev/analyze_audio_signal.py) uses
installed `ffprobe` and `ffmpeg` executables and Python 3. It opens only a local
file, decodes the first audio stream to Float32 PCM without changing its channel
count or sample rate, and emits scalar JSON. It performs no transcription,
playback, network requests, or writes to the source. Decoder errors fail the
command rather than accepting a partial measurement.

```sh
python3 scripts/dev/analyze_audio_signal.py /absolute/path/system-raw.m4a > /tmp/system-signal.json
python3 scripts/dev/analyze_audio_signal.py /absolute/path/meeting-playback.m4a > /tmp/playback-signal.json
python3 -m unittest discover -s scripts/dev/tests -p test_analyze_audio_signal.py -v
```

`exact_zero_frames` counts a frame only when **all** of its channels are zero.
RMS includes every sample across channels, avoiding cancellation from inverse
stereo. A zero RMS/peak is encoded as JSON `null` dBFS, representing negative
infinity; a very quiet nonzero sample stays nonzero. Windows are one second
except the final partial window. The longest zero run crosses window boundaries.
Time zero is the decoder's first output frame, not wall-clock capture time.

These measurements are post-decode observations, not an original SCK trace,
speech detector, or verdict on capture health. Lossy encoding can add nonzero
tails to a previously silent boundary. A successful measurement means the file
was decoded, not that the expected remote speech exists. AAC decoder versions
may cause small numeric differences; retain the artifact hash when comparing.

## Verification boundary

Completed: live GitHub issue/comment retrieval; attachment hashes, formats,
decoded levels and silent intervals; exact-version and current-source review;
inspection of existing channel-preservation tests; primary-source comparison.
The analyzer's seven behavioral tests pass, including silence, bursts separated
by zeros, quiet nonzero samples, right-only and inverse stereo, source
preservation, and failure without success JSON for corrupt, missing, or
partially decodable truncated input.

Not completed: live Phone/FaceTime reproduction; original stereo callback
inspection; controlled backend comparison; reporter output-route identification;
native GUI verification. Existing tests are evidence of intended coverage, not
a claim that they were executed during this investigation.

Keep #912 open. The evidence supports the capture-path hypothesis for Rodentia
and identifies why a lifetime signal flag cannot expose the missing interval;
it does not prove the native cause of the original long-lived-process report
or establish a shippable replacement backend.
