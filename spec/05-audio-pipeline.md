# 05 - Audio Pipeline

> Status: **ACTIVE** - Authoritative, current

The audio pipeline handles all audio input for MacParakeet: microphone recording for dictation, file input for transcription, and meeting recording with microphone + system audio by default plus microphone-only or system-audio-only source modes.

---

## Microphone Recording (Dictation)

### Capture Chain

```
Mic Input → SharedMicrophoneStream tap → temp WAV → selected local STT engine
```

- **Shared mic engine**: `AudioRecorder` subscribes to the process-wide `SharedMicrophoneStream` with `wantsVPIO: false`
- The stream owns the underlying `AVAudioEngine` input-node tap and handles device fallback centrally
- The platform accepts an input route only after its tap produces a usable buffer; a one-second no-buffer start is torn down and advances through the existing selected → System Default → built-in fallback chain. System Default generation is captured before route resolution and engine-configuration observation begins before `start()`, so a relevant change before readiness invalidates the stale attempt without penalizing an explicitly pinned named input for unrelated default-device churn. Once capture is active, a five-second callback gap runs the same bounded fresh-engine recovery used for a stopped configuration-change graph. A Bluetooth or unresolved route also recovers after two seconds of continuous exact-zero PCM (issue #541). This is not voice-activity detection: any non-zero microphone sample is valid, and digital silence remains valid on positively identified non-Bluetooth inputs. VPIO checks microphone channel 0 only so render/reference audio cannot mask a dead mic; raw multichannel input checks every channel.
- **Output format**: temporary WAV, 16kHz mono Float32
- **Minimum sample threshold**: 4,800 samples (0.3 seconds at 16kHz) required before sending to STT, mirroring FluidAudio's ASR guard. Header-only and near-empty recordings are rejected before they reach the speech engine.
- Dictation always extracts channel 0 before conversion so VPIO duplex layouts produce the post-AEC mono stream instead of channel-mixed reference audio.
- **Idle engine prepare (cold-start latency)**: independent of Instant Dictation, the shared stream re-*prepares* the raw dictation engine whenever it goes idle (`SharedMicrophoneStream(autoPrewarmWhenIdle:)`, plus a one-shot `prewarmDictation()` at launch). Prepare pays the expensive cold-path work up front — applying an explicit named-device selection when requested, negotiating the output format, installing the tap, and calling `AVAudioEngine.prepare()` — but leaves the engine **stopped**, so there is no capture and **no microphone indicator** while idle. System Default remains implicit during preparation; it is never rewritten into a `CurrentDevice` pin. The next dictation press matches the prepared engine (`AVAudioEngineMicrophonePlatform.prepare`/`goPreparedLocked`) and pays only `audioEngine.start()` (tens of ms) instead of the full device-acquisition + format negotiation (which previously ran *after* key-down and clipped the opening words). Raw meetings use the same non-VPIO stream configuration and can consume the prepared engine too; explicit VPIO or a different buffer size causes a full configure. Idle microphone-route changes trailing-debounce a fresh preparation before the next capture. Prepare is **suppressed on Bluetooth or unresolved inputs** (pre-acquiring even a stopped BT mic pins HFP/SCO). This is the no-open-mic path to instant first words; it complements Instant Dictation rather than replacing it (when the warm lease already holds the engine, the stream is not idle and prepare no-ops). See `Audio/README.md` for the prepare/go split.
- **Instant Dictation**: default-off setting that keeps a passive shared-stream subscriber attached while idle, stores a bounded 1-second RAM-only ring at 16kHz mono, and prepends up to 0.45 seconds to the next dictation WAV. Unlike idle prepare above, this keeps the mic actively **capturing**, so macOS shows the microphone indicator while it is enabled — its purpose is the pre-press pre-roll, not just a fast start. No STT or transcript processing runs while idle. The warm hold is suppressed unless the resolved input is positively known to be non-Bluetooth (an idle open Bluetooth mic pins the headset in HFP/SCO and degrades playback — issue #481); dictation then cold-starts with no pre-roll. Warm-capture refreshes triggered by microphone-selection, default-input, and live engine-configuration changes are debounced (0.5 s trailing) so notification bursts collapse into one engine restart, including profile/topology changes that retain the same device ID.
- **Pre-roll discard on confirmed media pause (issue #474)**: when the Pause Media round-trip confirms system media was playing at press time, `stop()` trims the prepended pre-roll from the WAV before transcription — it is pre-press audio that no pause can silence, so on speakers it would put the media's speech at the head of the transcript. The minimum-sample threshold then applies to the post-trim count, so an effectively media-only capture dismisses silently. Best-effort: a pause confirmation that settles after capture stops keeps the pre-roll.
- Dictation does not use the meeting crash-recovery lock-file pipeline. The current implementation writes a temp WAV and either moves it into retained storage or deletes it after processing.

### Storage

```
~/Library/Application Support/MacParakeet/dictations/{uuid}.wav
```

- Each dictation gets a UUID-named WAV file
- Storage preferences (keep audio, auto-delete after N days) are user-configurable

### Recording Lifecycle

```
User triggers dictation
    → Check microphone permission
    → If Instant Dictation is enabled, stop accepting idle pre-roll
      and prepend the most recent in-memory samples to the temp WAV
    → Subscribe to SharedMicrophoneStream
    → Shared stream starts the mic engine if needed
    → Convert samples to 16kHz mono Float32
    → Write to temp WAV
    → User stops dictation (or release-to-stop)
    → Validate sample count >= 4,800
    → Send to selected local STT engine through STTScheduler
    → Move WAV to dictations/ for storage (if enabled)
    → Clean up temp WAV (if storage disabled)
```

---

## File Input (Transcription)

### Conversion Pipeline

```
Input File → FFmpeg → 16kHz mono WAV → selected local STT engine → Transcript
```

- **FFmpeg** (bundled with the app) handles format conversion to 16kHz mono WAV
- The STT engine requires 16kHz mono Float32 input; FFmpeg normalizes all formats to this
- FFmpeg input-summary probing enumerates local-file audio streams before STT.
  One stream preserves automatic selection; two or more require an explicit
  zero-based audio-stream ordinal and conversion adds `-map 0:a:N`. Stream
  indices shown by the container are informational and are not substituted for
  the audio-only ordinal.

### Supported Formats

| Category | Formats |
|----------|---------|
| Audio | MP3, WAV, M4A, FLAC, OGG, OPUS |
| Video | MP4, MOV, MKV, WebM, AVI |

### Constraints

- **Max file size**: 4 hours of audio (configurable)
- **Temp file management**: intermediate WAV files are automatically cleaned up after transcription completes (success or failure)
- FFmpeg runs as a subprocess; phase updates are reported to the UI (download/transcribe progress where available)
- Live Speech is the persisted low-latency route for dictation and eligible meeting preview. Final Transcription is an optional persisted override for authoritative post-meeting and file/media work; when its key is absent it follows Live Speech. File, media, and URL jobs snapshot the resolved final route when they start. Within Parakeet, v3 is the multilingual default, v2 is an English-only TDT opt-in, and Unified is an English-only punctuation/capitalization opt-in with native live preview and token-derived word timestamps; Nemotron Beta, WhisperKit, and Cohere Transcribe can be selected in Settings or per CLI invocation where their engine constraints fit. Cohere is batch-only and produces plain text without word timestamps or live preview.

### Conversion Flow

```
User selects file
    → Preserve the original filename and extract embedded author, description, artwork, and duration when present
    → Validate format (check extension + probe with FFmpeg)
    → Continue immediately for one audio stream, or collect a choice for two or more
    → Validate duration <= max (4 hours default)
    → Convert the selected audio stream to 16kHz mono WAV via FFmpeg
    → Send to selected local STT engine through STTScheduler
    → Return transcript
    → Clean up temp WAV
```

---

## YouTube URL Input (Transcription)

### Download + Conversion Pipeline

```
YouTube URL → yt-dlp (audio only) → downloaded audio file → FFmpeg → 16kHz mono WAV → selected local STT engine → Transcript
```

- `yt-dlp` is used with `--no-playlist` for single-video processing
- YouTube audio quality is configurable:
  - **M4A** (default): `bestaudio[ext=m4a]/bestaudio/best`, preferring Apple-friendly saved audio files while falling back when m4a is unavailable
  - **Best available**: `bestaudio/best`, allowing higher-quality source streams such as Opus/WebM when YouTube offers them. Issue #237 measured ~10% lower Parakeet WER on Opus vs m4a for a Stanford speech. After STT completes, retained WebM/WebA/Opus/Ogg/MKV downloads are transcoded to `.m4a` (AAC 192k, faststart) in the background via bundled `ffmpeg` so AVPlayer can decode them for the in-app audio scrubber; conversion failures are non-fatal and the Show Video stream fallback remains available. Skipped entirely when retention is disabled.
- Download progress is parsed from yt-dlp output and surfaced as percent updates
- Downloaded files are written to:

```
~/Library/Application Support/MacParakeet/youtube-downloads/
```

### Retention Policy

- **Default:** keep downloaded YouTube audio (`saveTranscriptionAudio = true`)
- If disabled in Settings, downloaded YouTube audio is deleted after transcription
- Users can manually clear retained YouTube downloads from Settings > Storage

### URL Transcription Flow

```
User pastes YouTube URL
    → Validate URL format (single video)
    → Download audio via yt-dlp (emit "Downloading audio... X%")
    → Merge yt-dlp metadata with embedded audio metadata when needed
    → Convert to 16kHz mono WAV via FFmpeg
    → Send to selected local STT engine (emit "Transcribing... X%")
    → Save transcription (sourceURL set, filePath set only if retention enabled)
    → Clean up temp WAV (always)
    → If retention enabled AND saved file is WebM/WebA/Opus/Ogg/MKV,
        schedule a detached `ffmpeg` transcode to `.m4a` so the in-app
        audio scrubber can decode it. Update the row's `filePath` and
        delete the source on success. Non-fatal on failure.
```

---

## Meeting Recording (v0.6)

### Dual-Stream Capture

```
System Audio → ScreenCaptureKit SCStream audio → PCM adapter ─────────────┐
                                                                          ├→ MeetingAudioCaptureService
Mic Input    → SharedMicrophoneStream (+ Voice Processing I/O when active)┘   (AsyncStream<MeetingAudioCaptureEvent>)
                                                          │
                                                          ▼
                                              MeetingAudioStorageWriter
                                              (separate M4A per source)
                                                          │
                                                          ▼
                                              CaptureOrchestrator
                                              (ingest/join/offset/chunk flow)
                                                          │
                                                          ▼
                                  MicConditioner:
                                  - PassthroughMicConditioner
                                    (raw default; no capture-time AEC)
                                  - StreamingMeetingEchoSuppressor
                                    (optional LocalVQE-compatible runtime/model)
                                                          │
                                                          ▼
                                              LiveChunkTranscriber
                                              (queueing, ordering, cancellation, STT)
                                                          │
                                                          ▼ (on stop)
                                              AudioFileConverter (FFmpeg mix)
                                              → meeting-playback.m4a (stereo dual-source when both tracks exist)
                                              → awaiting-transcription lock + Library stub
                                              → background source-file STT + aligned merge
```

- **Source mode** is user-configurable per recording start: microphone +
  system audio (default), microphone only, or system audio only. The selected
  mode controls both permission prompts and which capture streams are started.
- **System audio** is captured via ScreenCaptureKit `SCStream` audio
  (`SCStreamConfiguration.capturesAudio = true`) only when the source mode
  includes system audio, which avoids owning or clocking a HAL aggregate output
  device.
- **Mic audio** is captured by subscribing to `SharedMicrophoneStream` only
  when the source mode includes microphone audio, with a typed policy
  (`MeetingMicProcessingMode`): `raw` (default), `vpioPreferred`, or
  `vpioRequired`.
- MacParakeet ships meeting capture with raw mic capture and ScreenCaptureKit
  for system audio when both sources are selected. VPIO remains available for
  explicit experiments, but it is not the shipped default because live-call
  testing showed that engaging it can muffle the user's outgoing mic in
  Zoom/Meet. The older Core Audio process-tap path also remains out of
  production because it does not reliably coexist with VPIO in-process. See
  `docs/research/vpio-process-tap-conflict.md`.
- When both streams are selected, they are captured within the same meeting
  session and aligned by host time. `CaptureOrchestrator` owns join + offset +
  live-preview chunk boundaries via `MeetingAudioPairJoiner` plus per-source
  `MeetingLiveAudioChunking` strategies. Single-source sessions skip the
  unselected stream and produce a mono `meeting-playback.m4a`.
- Raw capture applies no platform AEC/noise suppression/AGC. Meeting mic
  conditioning is preview-only: release bundles with LocalVQE assets may run
  `StreamingMeetingEchoSuppressor` over paired mic/system samples, while
  local/dev bundles without those assets fall back to raw preview samples with
  diagnostics. Transcript-layer system-dominance suppression and
  `MeetingTranscriptSourceReconciler` remain safety nets against obvious
  speaker bleed, not a complete AEC substitute. When VPIO is explicitly
  requested and engages, macOS applies AEC/noise suppression/AGC before buffers
  reach `MeetingRecordingService`.
- Audio is stored as separate M4A files (AAC 64kbps, 48kHz mono) per source
- Source audio is written as fragmented M4A with 1-second movie fragments so kill-9 recovery can keep playable audio through the last committed fragment.
- After recording stops, the captured source M4As are finalized and merged into
  `meeting-playback.m4a`. Dual-input sessions preserve source separation as stereo
  (`L=mic`, `R=system`), while single-input sessions remain mono. The recovery
  lock is then rewritten to `awaitingTranscription`, and a processing Library
  row is saved before the recorder returns to idle.
- Final meeting STT does **not** transcribe `meeting-playback.m4a`. A background queue
  transcribes the captured source files separately with the engine captured at
  recording start, then merges those fresh results by persisted
  `MeetingSourceAlignment`. For the local (`Me`) microphone track, source
  selection follows the echo-cancellation readiness gate below. The system track
  is unchanged. `MeetingRecordingOutput.microphoneTranscriptionURL` remains a
  cheap UI/list helper, not the final-STT gate. `meeting-playback.m4a` is kept as the
  playback/export artifact. See
  `docs/research/meeting-dual-stream-transcription-pipeline.md` for the full
  pipeline and tradeoffs.
- Recovery locks and retention safety are a tested boundary contract. See [`spec/contracts/meeting-recovery-retention.md`](contracts/meeting-recovery-retention.md) before changing lock-file predicates or automatic meeting-audio deletion.
- Live chunk enqueue keeps a conservative guard: when recent system energy strongly dominates processed mic energy for a short freshness window, mic chunks are skipped for live transcription only. Mic audio is still written to disk and included in final mix/output.
- Joiner queue overflow, long-session sync lag, and runtime capture failures are emitted as diagnostics for observability (`MeetingAudioCaptureEvent.error` where available).

### Meeting Echo Cancellation (AEC)

Dual-source meeting capture preserves raw source artifacts:
`microphone-raw.m4a` and `system-raw.m4a`, plus mixed `meeting-playback.m4a` for playback and
export. After stop, `MeetingCleanedMicRenderer` can derive
`microphone-cleaned.m4a` offline from the raw mic and system reference using
the LocalVQE echo-only v1.4 path with `MeetingEchoDelayEstimator` delay
estimation. Before running the model, the echo probe can skip no-echo meetings
(headphones or inaudible remote audio) and choose raw without manufacturing a
cleaned file. For very long meetings, the duration guard skips upfront when the
render is predicted to exceed the bounded final-STT deadline.

Final STT waits on `MeetingCleanedMicrophoneReadiness` with a bounded,
duration-scaled deadline before choosing the microphone source. It uses cleaned
audio only when the render finishes and the artifact is non-empty and decodable;
otherwise it falls back to raw mic. The source decision records a structured
routing reason (`cleanedUsed`, `rawTimeout`, `rawInvalidArtifact`,
`rawRenderFailed`, `rawMissingSystemReference`, `rawNoAECAssets`,
`skippedNoEchoPath`, or `predictedRenderTimeout`). The render/skip summary is
persisted to
`meeting-recording-metadata.json` as optional `echoSuppression` provenance so
shared artifact folders explain cleaned-vs-raw routing without app logs.

[ADR-028](adr/028-meeting-echo-cancellation.md) is the architectural record.
[`spec/contracts/meeting-artifacts-v1.md`](contracts/meeting-artifacts-v1.md)
is the artifact and sidecar contract.

### Key Components

| Component | Purpose |
|-----------|---------|
| `SystemAudioStream` | ScreenCaptureKit system-audio wrapper - creates an audio-only `SCStream`, adapts `CMSampleBuffer` to `AVAudioPCMBuffer`, and maps first-buffer, heartbeat, and unexpected delegate stops into typed lifecycle failures |
| `SharedMicrophoneStream` | Process-wide microphone engine owner, VPIO arbiter, synchronous buffer fan-out, source-owned startup readiness/device fallback, and terminal engine-death propagation after bounded configuration-change, callback-stall, or Bluetooth zero-filled recovery is exhausted |
| `MicrophoneCapture` | Meeting mic subscriber with explicit mic-processing policy, effective-mode reporting, awaited teardown, and typed stall propagation |
| `MeetingAudioCaptureService` | Actor combining the selected source stream(s) into `AsyncStream<MeetingAudioCaptureEvent>`; owns bounded fresh-instance system recovery, coalesces duplicate failures, and lets Stop invalidate every retry generation |
| `CaptureOrchestrator` | Owns ingest/join/offset/chunk flow for live preview |
| `MicConditioner` | Meeting-side seam for mic samples; passthrough is the default, and an optional `StreamingMeetingEchoSuppressor` can use paired system reference samples when the runtime/model are available |
| `MeetingCleanedMicRenderer` | Post-stop offline derivation of `microphone-cleaned.m4a` from the raw mic + system sources through a freshly built suppressor; skips when no echo path/single-source and never throws into finalize |
| `LiveChunkTranscriber` | Owns live chunk queueing, cancellation, ordering, STT invocation |
| `MeetingAudioStorageWriter` | Writes separate fragmented M4A files per source, preserves genuine recovery gaps as silence, distinguishes real captured frames from padded timeline frames, and reports per-source finalization failure |
| `MeetingPlaybackArtifactBuilder` | Probes finalized sources, installs validated mixed playback atomically, or uses the longest aligned source as an explicit partial-playback fallback |
| `MeetingCaptureReport` | Pure finalized truth for elapsed time, captured/timeline duration, per-source coverage/interruption, runtime failure, and canonical-playback fallback |
| `MeetingRecordingMetadataStore` | Persists source alignment, capture report, and speech/AEC provenance atomically for normal and crash-recovery paths |
| `MeetingRecordingLockFileStore` | Persists in-progress session state, notes, and captured final speech engine for crash recovery |
| `MeetingRecordingSettlement` | Sole completion-path owner of `recording.lock` deletion; re-fetches the saved row and deletes the lock only after verifying a completed meeting Transcription for that artifact folder (see [meeting-recovery-retention contract](contracts/meeting-recovery-retention.md#lock-deletion-authority)) |
| `MeetingTranscriptionQueue` | Owns FIFO background finalization for stopped meetings after audio + lock + Library stub are durable |
| `MeetingTranscriptFinalizer` | Merges fresh per-source STT results into the final meeting transcript |

### Meeting Recording Flow

```text
User clicks "Start Meeting Recording"
    → Resolve source mode
    → Check microphone permission only when the mode includes mic audio
    → Check Screen & System Audio Recording permission only when the mode includes system audio
    → If a required permission is denied: show error + "Open System Settings" button, block recording
    → Acquire the Live Speech lease from STTScheduler unconditionally
    → Capture an immutable preview/final plan; preview is live when supported,
      final is the resolved Final Transcription route
    → Start MeetingAudioCaptureService with the selected source mode
    → Show recording pill (red dot + elapsed timer + stop button)
    → Consume AsyncStream<MeetingAudioCaptureEvent>, write buffers to M4A files
      and keep `recording.lock` current with session state/notes/final speech engine
    → User clicks Stop
    → Stop capture and finalize the captured source file(s); if a written source
      cannot finalize, preserve the lock/source artifacts and abort settlement
    → Persist `meeting-recording-metadata.json` with source alignment,
      frame-derived capture report, final speech engine, and optional provenance
    → Build and probe `meeting-playback.m4a` (stereo for dual input; mono for
      single input); a failed dual mix installs the longest aligned source and
      durably marks playback partial
    → Atomically rewrite `recording.lock` to `awaitingTranscription`
    → Save a processing Transcription row with sourceType = .meeting and filePath = `meeting-playback.m4a`
    → Enqueue background finalization and return recorder to idle
    → User may immediately start the next meeting recording
    → Background queue converts each captured source M4A → 16kHz mono WAV via FFmpeg
    → Send each source WAV to the captured local STT engine
    → Merge fresh per-source STT using persisted source offsets
    → Optionally refine the isolated system side with diarization
    → Update the existing Transcription row, then settle: MeetingRecordingSettlement
      verifies the completed row and deletes `recording.lock` (on failure the
      lock stays for recovery to re-settle; the queue still reports success)
    → Navigate to transcription detail view only if no newer meeting recording is active
```

The foreground stop path is intentionally sequential, not concurrent: Meeting
B can start only after Meeting A's source audio, mixed playback artifact,
`awaitingTranscription` lock, and processing Library row are durable. Meeting
A's final STT then continues in the queue-owned background path.

This is a recorder-availability guarantee, not an instant-transcript guarantee.
Queued meeting finalization still uses the shared `STTScheduler` background
slot. If file, folder, YouTube, podcast, or media URL STT is already running,
the stopped meeting waits for that job to finish; once the slot is free,
`meetingFinalize` outranks later queued `fileTranscription` work.

### Storage

```text
~/Library/Application Support/MacParakeet/meeting-recordings/{uuid}/
    ├── microphone-raw.m4a    # Raw mic audio when captured (AAC, 48kHz mono) — source of truth
    ├── system-raw.m4a        # System audio when captured (AAC, 48kHz mono)
    ├── microphone-cleaned.m4a  # Optional derived echo-cancelled mic (16kHz mono); STT input for the "Me" track only after readiness/decodability gates pass
    ├── meeting-playback.m4a       # Playback/export artifact (stereo dual-source when both tracks exist)
    ├── meeting-recording-metadata.json  # Source timing/alignment + capture report + final engine + optional preview engine / echoSuppression provenance
    ├── recording.lock     # Recovery state, notes, and captured final engine (schema v2 unchanged)
    └── chunks/            # Live-preview scratch chunks
```

Audio files are kept forever by default. Settings > Storage exposes a meeting
audio retention policy: keep forever, auto-delete after a configurable number of
days (1–365, default 30), or delete immediately after transcription. Switching
to an auto-deleting mode is gated behind a one-time confirmation; the legacy
`saveMeetingAudio` preference migrates to keep-forever (on) or delete-immediately
(off). Users can also reveal, save a copy, or delete
managed meeting audio from the meeting detail view, Library/Meetings row menus,
Settings > Storage, and CLI support commands. Audio deletion clears the
transcript's stored `filePath` and removes top-level app-managed audio files
from the session folder, including `meeting-playback.m4a`, selected-source
`microphone-raw.m4a` / `system-raw.m4a`, and other managed audio extensions. It keeps
the transcript row, `meetingArtifactFolderPath`, and non-audio artifacts such
as `manifest.json`, `transcript.json`, `notes.md`, and prompt-result files.
Full meeting deletion is the path that removes the session folder.

Scheduled retention only detaches audio for completed meeting rows with stored
audio paths. It skips any session folder that still has `recording.lock`, live
or dead PID, because those files are active or recoverable recording input.
Crash-recovered meetings are protected while recovery runs; once the lock is
removed and the recovered row is completed, normal retention applies. The same
lock guard protects manual cleanup: both `TranscriptionAssetCleanup` and the
`clear-meeting-audio` CLI refuse to remove a session folder while a
`recording.lock` is present, including dead-owner `awaitingTranscription` locks
whose audio is still queued for background transcription (back-to-back meeting
recording).

### Concurrent Operation with Dictation (ADR-015)

Meeting recording and dictation share one process-wide microphone engine. Both flows subscribe to the same `SharedMicrophoneStream`, and the stream fans every captured buffer out to all subscribers:

| Flow | Shared mic role | Notes |
|------|--------|-------|
| Dictation | `AudioRecorder` subscribes with `wantsVPIO: false` | Copies tap buffers for async conversion/writes and extracts ch[0] if a VPIO duplex layout is already active |
| Instant Dictation warm lease | `AudioRecorder` subscribes with `wantsVPIO: false, blocksVPIOPromotion: false` while the setting is enabled, dictation is idle, and the resolved input is positively known to be non-Bluetooth | Keeps the mic engine warm and maintains only a bounded in-memory pre-roll; because it is passive, explicit VPIO subscribers can still promote the engine immediately when no active raw capture is in flight. Suppressed (dropped, not deferred) on Bluetooth or unresolved inputs so the idle hold never pins a headset in HFP/SCO (issue #481) |
| Meeting mic | `MicrophoneCapture` subscribes with `wantsVPIO` derived from `MeetingMicProcessingMode` | Raw capture by default; VPIO can still be explicitly requested, and meeting mic extracts ch[0] when VPIO is engaged |

`SharedMicrophoneStream` owns the single `AVAudioEngine`, fans buffers out synchronously, and keeps VPIO sticky once engaged. Engagement is deferred while an active non-VPIO capture subscriber is already in flight, so dictation or raw meeting capture does not get a mid-session format flip. Passive warm subscribers do not count as blockers. If deferred VPIO promotion fails, the engine is marked dead, remaining subscriptions are invalidated after their `onEngineDeath` callbacks are captured, and later subscribers start a fresh engine. The shared-engine architecture is required (not a convenience) because VPIO is process-scoped — see ADR-015 §1 for the full rationale.

All STT work routes through a process-wide scheduler and shared runtime owner (ADR-016, ADR-021). Parakeet is the default engine family (`v3` multilingual default, `v2` English-only TDT opt-in, `unified` English opt-in); Nemotron Beta, WhisperKit, and Cohere Transcribe can be selected explicitly. That keeps:

- dictation on its own reserved interactive slot
- meeting live preview best-effort under backlog, with immediate post-stop finalization prioritized on the shared background slot
- file / YouTube transcription, plus legacy saved-meeting fallbacks without archived metadata, queued behind meeting work on that same background slot
- saved meetings with archived source metadata reuse the same `meetingFinalize` path as immediate post-stop finalization
- active meetings hold the Live Speech lease and capture one immutable preview/final plan; recovery uses a captured schema-v2 final engine/language when present, otherwise the current resolved Final Transcription route

The primary concurrency use case remains meeting recording + dictation. File transcription may coexist architecturally, but it should never degrade dictation responsiveness.

### Dictation Live Preview

Dictation can show a display-only live transcript preview above the dictation
pill while you speak (`AppFeatures.liveDictationStreamingEnabled`, #517). It is
decoupled from the paste: the final inserted text always comes from the
stop-time transcription path, so a jumpy or approximate preview can never
corrupt the result. Per engine: Parakeet runs a single-flight tail-window batch
preview (~1s cadence over the last ~15s of mic samples through its existing
`[Float]` batch path); both Nemotron builds reuse their native live-partial
path; Whisper stays default-off pending a per-pass latency probe, and Cohere
stays off because it is record-then-transcribe only. Users toggle
it — and pick a preview text size — in Settings → Capture → Dictation
(`showLiveDictationPreview`, default on); the toggle gates only the preview
sink.

Before display the raw preview stream passes through a `LiveTranscriptStabilizer`
(owned by `DictationService`, reset per session): it aligns each update against
the committed tail and only ever appends — committing the stable body and holding
the last few words as a volatile hypothesis — so already-shown words don't jump,
re-spell, or disappear as the window slides or partials are revised. The overlay
renders this as a bottom-anchored rolling readout: the newest line is pinned to
the bottom and older lines rise and fade out at the top edge via a gradient mask,
with no mid-word head truncation. Stabilization is display-only and can never
alter the pasted text. See `docs/research/live-dictation-streaming.md`.

### Meeting Live Preview

`CaptureOrchestrator` buffers audio into live-preview chunks and sends them through the scheduler using the meeting plan's preview route. The preview route is the captured Live Speech selection only when its capabilities provide the word timings required by the renderer; otherwise no live chunks are created and there is no fallback engine. The fixed cadence keeps the original 5s / 1s-overlap `AudioChunker`. When `AppFeatures.meetingVadLiveChunkingEnabled` is true, launch-time prep tries to cache the Silero VAD model; if it is cached and preview uses Parakeet, the live path cuts chunks at speech boundaries per source. Nemotron and Whisper preview use the fixed cadence. Cohere cannot preview. VAD unavailable/error cases fall back to fixed chunking, while the authoritative post-stop pass independently uses the plan's captured final route and durable audio. This provides:
- Live transcript preview in the recording pill
- Source-aware labels: mic chunks → "Me", system chunks → "Them"
- Raw mic capture plus a residual safeguard that suppresses clearly system-dominant mic chunks in live preview windows
- Immediate transcript availability when recording stops

---

## Permissions

| Permission | Why | When Requested | Fallback |
|------------|-----|----------------|----------|
| Microphone | Dictation recording and meeting modes that include mic audio | Onboarding, first dictation attempt, or first mic-capturing meeting attempt | Show permission dialog with instructions |
| Accessibility | Global shortcut detection + text insertion | Onboarding or first dictation attempt | Show System Settings deep link |
| Screen & System Audio Recording | Meeting modes that include system audio capture via ScreenCaptureKit | First system-audio meeting attempt | Show error + "Open System Settings" button, block recording |

### Permission Flow

1. Check permission status before starting the relevant feature
2. If not granted, show an in-app dialog explaining why the permission is needed
3. Provide a button to open System Settings to the correct pane
4. Poll for permission grant (Accessibility) or use callback (Microphone)
5. Never block the entire app — only the feature that requires the permission

---

## Audio Format Reference

| Stage | Format | Sample Rate | Channels | Bit Depth |
|-------|--------|-------------|----------|-----------|
| Mic capture (dictation) | Platform native | Varies | Mono | Float32 |
| After conversion | WAV | 16kHz | Mono | Float32 |
| STT input | WAV | 16kHz | Mono | Float32 |
| Long-term storage (dictation) | WAV | 16kHz | Mono | Float32 |
| File import (temp) | WAV | 16kHz | Mono | Float32 |
| Meeting mic storage | M4A (AAC) | 48kHz | Mono | 64kbps |
| Meeting system audio storage | M4A (AAC) | 48kHz | Mono | 64kbps |
| Meeting STT input (temp) | WAV | 16kHz | Mono | Float32 |
