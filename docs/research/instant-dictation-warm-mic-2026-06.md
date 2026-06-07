# Instant Dictation Warm Mic Research

> Checked on 2026-06-02 while triaging [issue #414](https://github.com/moona3k/macparakeet/issues/414).

## Finding

The useful competitive pattern is not "warm the speech model." The user-facing
gap is pre-start microphone capture: keep the microphone stream running, hold a
tiny rolling buffer in memory, and prepend the newest samples when recording
starts. That captures speech that begins at the hotkey press.

MacParakeet should copy that behavior, but not the exact topology. ADR-015
requires one process-wide `SharedMicrophoneStream` because VPIO is
process-scoped on macOS. A second always-on dictation engine would recreate the
class of bugs ADR-015 fixed. The warm lease therefore belongs inside
`SharedMicrophoneStream` as a passive subscriber that does not block VPIO
promotion.

## Issue #450 Evidence

Checked again on 2026-06-07 while triaging
[issue #450](https://github.com/moona3k/macparakeet/issues/450).

The report is a controlled timing test: speaking immediately at button press
often loses the first one to three spoken numbers, while waiting until the
dictation pill reaches about one second captures all eight numbers. The 2x2
matrix across Auto Pause on/off and Clean/Raw vocabulary mode shows the same
shape, which rules out pause detection and text cleanup as primary causes.

The attached `dictation-audio.log` confirms healthy audio after a late first
buffer rather than an STT or silent-stream failure. In the repro window
(`2026-06-07T17:55Z` through `17:59Z`), all captures use the USB default input
and the timing is tightly clustered:

| Phase | Median |
|-------|--------|
| `dictation_capture_start` -> `shared_mic_engine_input_device_started` | 563 ms |
| `dictation_capture_start` -> `dictation_capture_engine_started` | 568 ms |
| `dictation_capture_start` -> `dictation_capture_first_buffer` | 662 ms |
| `dictation_capture_engine_started` -> first buffer | 95 ms |

The variable cost is therefore before live buffers reach `AudioRecorder`: input
device / Core Audio / `AVAudioEngine` startup. The final buffer period is the
expected tap cadence. Once buffers arrive, the log shows non-silent input and
normal Parakeet v2 transcription completion.

Across the full uploaded log, press-to-first-buffer latency is bimodal and
device-sensitive rather than a clean app-version regression:

- Built-in input sessions generally sit around 240-270 ms.
- USB input sessions in this log generally sit around 650-700 ms.
- The same v0.6.21 process starts built-in at 251-274 ms around `06:17Z`, then
  after the default input moves to USB it stays around 654-710 ms through the
  #450 reproduction.

This makes #450 the deterministic user-facing form of the same startup window
that originally motivated Instant Dictation. It is adjacent to #421/#432, but
not identical: #450 has valid, non-silent capture after a late first buffer;
#432 describes intermittent silent/no-input capture and still needs the
separate capture-health handling in PR #441.

## References

| Project | Checked ref | Relevant behavior |
|---------|-------------|-------------------|
| [Hex](https://github.com/kitlangton/Hex) | `f988cb78c57f206abd6935ff93042242fc7669ad` | `Hex/Clients/SuperFastCaptureController.swift` keeps a 16 kHz capture engine warm in "super-fast" mode, maintains a 1-second `Float` ring, and prepends 0.45 seconds on begin-recording. The pre-roll is written before live recording is marked active, and the ring only appends while idle, which avoids double-writing live samples. This is the closest Swift/macOS reference. |
| [local-whisper](https://github.com/gabrimatic/local-whisper) | `c932a64757359b9ca3462825836b1ca080b8464b` | `src/whisper_voice/audio.py` uses a configurable pre-buffer monitor stream. `pre_buffer` defaults to `0.0`; enabling it keeps the mic active between recordings. On recording start it stops monitoring, reassembles the ring, and prepends it to the live chunks. It also restarts monitoring after stop/error paths. |
| [Muesli](https://github.com/Muesli-HQ/muesli) | `3af79eb00dce44cd83d9e23466328ff46d91cbc1` | `MicrophoneRecorder` warms an `AVAudioRecorder` with `prepareToRecord()` / activation, and Muesli has streaming/model warmup paths, but it does not maintain a pre-start rolling buffer. Useful as a contrast: prepare/model warmup reduces setup cost but does not recover first syllables. |
| [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) | `f5b55f9083a66f93911c6ddf49539c7b1e5094a5` | `AudioRecordingService` starts capture on demand and has stop-side grace for short speech, but no idle rolling pre-buffer. |
| [OpenWhisper app](https://github.com/Rajvardhman05/openwhisper-app) | `b13d1421e6653cde9f68f43e37330a0733fa6acc` | `OpenWhisper/Core/AudioEngine.swift` starts a fresh `AVAudioEngine` on each recording, appends samples only after `startRecording`, then stops and resets the engine on `stopRecording`. No warm stream or pre-start rolling buffer. |
| [OpenWhisper](https://github.com/Knuckles92/OpenWhisper) | `119ad1ec9b91dfa4a329f805170dacfdf54ecd11` | `services/recorder.py` starts a `sounddevice.InputStream` on recording start and includes stop-side post-roll, but no idle monitor/pre-roll. Useful contrast: post-roll captures trailing audio, not first syllables at hotkey press. |
| [OpenWhispr](https://github.com/OpenWhispr/openwhispr) | `38e832d23dbd1da472a331a9262106a8e9ba9b01` | `src/helpers/audioManager.js` preloads its AudioWorklet/provider state and briefly acquires/releases the mic to warm the OS audio driver, but it does not keep an idle stream or rolling pre-roll. Useful contrast: driver warmup improves later `getUserMedia` latency, but cannot prepend speech that began before recording. |

## MacParakeet Shape

- Default off, exposed as a user setting with explicit mic-indicator copy.
- Dictation only. Meeting recording behavior stays unchanged.
- Use one warm `AudioRecorder` subscriber on `SharedMicrophoneStream`; do not create another engine.
- Subscriber uses `wantsVPIO: false, blocksVPIOPromotion: false`, so explicit meeting VPIO experiments can still promote when no active raw capture is in flight.
- Keep only bounded RAM audio while idle: 1 second capacity, prepend at most 0.45 seconds.
- Do not run STT/model inference while idle.
- Clear the ring on dictation start/stop, disable, refresh, and engine death.
