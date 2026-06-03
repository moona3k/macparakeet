# 05 - Audio Pipeline

> Status: **ACTIVE** - Authoritative, current

The audio pipeline handles all audio input for MacParakeet: microphone recording for dictation, file input for transcription, and dual-stream capture (system audio + mic) for meeting recording.

---

## Microphone Recording (Dictation)

### Capture Chain

```
Mic Input → SharedMicrophoneStream tap → temp WAV → selected local STT engine
```

- **Shared mic engine**: `AudioRecorder` subscribes to the process-wide `SharedMicrophoneStream` with `wantsVPIO: false`
- The stream owns the underlying `AVAudioEngine` input-node tap and handles device fallback centrally
- **Output format**: temporary WAV, 16kHz mono Float32
- **Minimum sample threshold**: 4,800 samples (0.3 seconds at 16kHz) required before sending to STT, mirroring FluidAudio's ASR guard. Header-only and near-empty recordings are rejected before they reach the speech engine.
- Dictation always extracts channel 0 before conversion so VPIO duplex layouts produce the post-AEC mono stream instead of channel-mixed reference audio.
- **Instant Dictation**: default-off setting that keeps a passive shared-stream subscriber attached while idle, stores a bounded 1-second RAM-only ring at 16kHz mono, and prepends up to 0.45 seconds to the next dictation WAV. macOS shows the microphone indicator while this is enabled. No STT or transcript processing runs while idle.
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

### Supported Formats

| Category | Formats |
|----------|---------|
| Audio | MP3, WAV, M4A, FLAC, OGG, OPUS |
| Video | MP4, MOV, MKV, WebM, AVI |

### Constraints

- **Max file size**: 4 hours of audio (configurable)
- **Temp file management**: intermediate WAV files are automatically cleaned up after transcription completes (success or failure)
- FFmpeg runs as a subprocess; phase updates are reported to the UI (download/transcribe progress where available)
- The selected speech engine is Parakeet by default. Within Parakeet, v3 is the multilingual default and v2 is an English-only opt-in; WhisperKit can be selected globally in Settings or per CLI invocation for broader language coverage.

### Conversion Flow

```
User selects file
    → Extract embedded media metadata (title, author, artwork, duration) when present
    → Validate format (check extension + probe with FFmpeg)
    → Validate duration <= max (4 hours default)
    → Convert to 16kHz mono WAV via FFmpeg
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
                                                          │
                                                          ▼
                                              LiveChunkTranscriber
                                              (queueing, ordering, cancellation, STT)
                                                          │
                                                          ▼ (on stop)
                                              AudioFileConverter (FFmpeg mix)
                                              → meeting.m4a (stereo dual-source when both tracks exist)
                                              → separate source-file STT + aligned merge
```

- **System audio** is captured via ScreenCaptureKit `SCStream` audio (`SCStreamConfiguration.capturesAudio = true`), which avoids owning or clocking a HAL aggregate output device.
- **Mic audio** is captured by subscribing to `SharedMicrophoneStream` with a typed policy (`MeetingMicProcessingMode`): `raw` (default), `vpioPreferred`, or `vpioRequired`.
- MacParakeet ships meeting capture with raw mic capture and ScreenCaptureKit for system audio. VPIO remains available for explicit experiments, but it is not the shipped default because live-call testing showed that engaging it can muffle the user's outgoing mic in Zoom/Meet. The older Core Audio process-tap path also remains out of production because it does not reliably coexist with VPIO in-process. See `docs/research/vpio-process-tap-conflict.md`.
- Both streams are captured within the same meeting session and aligned by host time. `CaptureOrchestrator` owns join + offset + live-preview chunk boundaries via `MeetingAudioPairJoiner` plus per-source `MeetingLiveAudioChunking` strategies.
- Mic conditioning is pass-through. Raw capture applies no capture-time AEC/noise suppression/AGC; transcript-layer system-dominance suppression remains the default guard against obvious speaker bleed. When VPIO is explicitly requested and engages, macOS applies AEC/noise suppression/AGC before buffers reach `MeetingRecordingService`.
- Audio is stored as separate M4A files (AAC 64kbps, 48kHz mono) per source
- Source audio is written as fragmented M4A with 1-second movie fragments so kill-9 recovery can keep playable audio through the last committed fragment.
- After recording stops, microphone + system M4As are merged into `meeting.m4a`. Dual-input sessions preserve source separation as stereo (`L=mic`, `R=system`), while single-input sessions remain mono.
- Final meeting STT does **not** transcribe `meeting.m4a`. It transcribes `microphone.m4a` and `system.m4a` separately with the engine captured at recording start, then merges those fresh results by persisted `MeetingSourceAlignment`. `meeting.m4a` is kept as the playback/export artifact. See `docs/research/meeting-dual-stream-transcription-pipeline.md` for the full pipeline and tradeoffs.
- Live chunk enqueue keeps a conservative guard: when recent system energy strongly dominates processed mic energy for a short freshness window, mic chunks are skipped for live transcription only. Mic audio is still written to disk and included in final mix/output.
- Joiner queue overflow, long-session sync lag, and runtime capture failures are emitted as diagnostics for observability (`MeetingAudioCaptureEvent.error` where available).

### Key Components

| Component | Purpose |
|-----------|---------|
| `SystemAudioStream` | ScreenCaptureKit system-audio wrapper - creates an audio-only `SCStream`, adapts `CMSampleBuffer` to `AVAudioPCMBuffer`, and emits stall diagnostics |
| `SharedMicrophoneStream` | Process-wide microphone engine owner, VPIO arbiter, and synchronous buffer fan-out |
| `MicrophoneCapture` | Meeting mic subscriber with explicit mic-processing policy, effective-mode reporting, and stall diagnostics |
| `MeetingAudioCaptureService` | Actor combining both streams into `AsyncStream<MeetingAudioCaptureEvent>` with `.bufferingNewest(2048)` and runtime error emission where available |
| `CaptureOrchestrator` | Owns ingest/join/offset/chunk flow for live preview |
| `MicConditioner` | Pass-through seam for mic samples; raw capture is the default, with VPIO only when explicitly requested |
| `LiveChunkTranscriber` | Owns live chunk queueing, cancellation, ordering, STT invocation |
| `MeetingAudioStorageWriter` | Writes separate M4A files per source (mic + system) |
| `MeetingRecordingMetadataStore` | Persists `MeetingSourceAlignment` for post-stop merge correctness |
| `MeetingRecordingLockFileStore` | Persists in-progress session state, notes, and captured speech engine for crash recovery |
| `MeetingTranscriptFinalizer` | Merges fresh per-source STT results into the final meeting transcript |

### Meeting Recording Flow

```text
User clicks "Start Meeting Recording"
    → Check Screen Recording permission (CGPreflightScreenCaptureAccess)
    → If denied: show error + "Open System Settings" button, block recording
    → Acquire speech-engine lease from STTScheduler and capture current engine/language
    → Start MeetingAudioCaptureService (both streams)
    → Show recording pill (red dot + elapsed timer + stop button)
    → Consume AsyncStream<MeetingAudioCaptureEvent>, write buffers to M4A files
      and keep `recording.lock` current with session state/notes/speech engine
    → User clicks Stop
    → Stop capture, finalize `microphone.m4a` + `system.m4a`
    → Persist `meeting-recording-metadata.json` with source alignment and speech engine
    → Merge streams into `meeting.m4a` (stereo for dual input; mono for single input)
    → Convert `microphone.m4a` → 16kHz mono WAV via FFmpeg
    → Send mic WAV to captured local STT engine
    → Convert `system.m4a` → 16kHz mono WAV via FFmpeg
    → Send system WAV to captured local STT engine
    → Merge fresh per-source STT using persisted source offsets
    → Optionally refine the isolated system side with diarization
    → Save as Transcription with sourceType = .meeting
    → Navigate to transcription detail view
```

### Storage

```text
~/Library/Application Support/MacParakeet/meeting-recordings/{uuid}/
    ├── microphone.m4a    # Mic audio (AAC, 48kHz mono)
    ├── system.m4a        # System audio (AAC, 48kHz mono)
    ├── meeting.m4a       # Final playback/export artifact (stereo dual-source when both tracks exist; legacy fallback for downstream tools)
    ├── meeting-recording-metadata.json  # Persisted source timing/alignment + speech engine for post-stop merge
    ├── recording.lock     # In-progress recovery state, including notes and speech engine
    └── chunks/            # Live-preview scratch chunks
```

Audio files are kept by default. Users can delete manually from the transcription detail view.

### Concurrent Operation with Dictation (ADR-015)

Meeting recording and dictation share one process-wide microphone engine. Both flows subscribe to the same `SharedMicrophoneStream`, and the stream fans every captured buffer out to all subscribers:

| Flow | Shared mic role | Notes |
|------|--------|-------|
| Dictation | `AudioRecorder` subscribes with `wantsVPIO: false` | Copies tap buffers for async conversion/writes and extracts ch[0] if a VPIO duplex layout is already active |
| Instant Dictation warm lease | `AudioRecorder` subscribes with `wantsVPIO: false, blocksVPIOPromotion: false` while the setting is enabled and dictation is idle | Keeps the mic engine warm and maintains only a bounded in-memory pre-roll; because it is passive, explicit VPIO subscribers can still promote the engine immediately when no active raw capture is in flight |
| Meeting mic | `MicrophoneCapture` subscribes with `wantsVPIO` derived from `MeetingMicProcessingMode` | Raw capture by default; VPIO can still be explicitly requested, and meeting mic extracts ch[0] when VPIO is engaged |

`SharedMicrophoneStream` owns the single `AVAudioEngine`, fans buffers out synchronously, and keeps VPIO sticky once engaged. Engagement is deferred while an active non-VPIO capture subscriber is already in flight, so dictation or raw meeting capture does not get a mid-session format flip. Passive warm subscribers do not count as blockers. If deferred VPIO promotion fails, the engine is marked dead, remaining subscriptions are invalidated after their `onEngineDeath` callbacks are captured, and later subscribers start a fresh engine. The shared-engine architecture is required (not a convenience) because VPIO is process-scoped — see ADR-015 §1 for the full rationale.

All STT work routes through a process-wide scheduler and shared runtime owner (ADR-016, ADR-021). Parakeet is the default engine family (`v3` multilingual default, `v2` English-only opt-in); WhisperKit can be selected explicitly. That keeps:

- dictation on its own reserved interactive slot
- meeting live preview best-effort under backlog, with immediate post-stop finalization prioritized on the shared background slot
- file / YouTube transcription, plus legacy saved-meeting fallbacks without archived metadata, queued behind meeting work on that same background slot
- saved meetings with archived source metadata reuse the same `meetingFinalize` path as immediate post-stop finalization
- active meeting recordings pinned to one speech engine/language for live preview, finalization, and crash recovery

The primary concurrency use case remains meeting recording + dictation. File transcription may coexist architecturally, but it should never degrade dictation responsiveness.

### Live Preview

`CaptureOrchestrator` buffers audio into live-preview chunks and sends them through the scheduler using the meeting's captured speech engine during recording. The fixed fallback keeps the original 5s / 1s-overlap `AudioChunker` cadence. When `AppFeatures.meetingVadLiveChunkingEnabled` is true, launch-time prep tries to cache the Silero VAD model; if it is cached and the meeting uses Parakeet, the live path cuts chunks at speech boundaries per source. VAD unavailable/error cases fall back to the fixed cadence, and the final post-stop transcript is unchanged. This provides:
- Live transcript preview in the recording pill
- Source-aware labels: mic chunks → "Me", system chunks → "Them"
- Raw mic capture plus a residual safeguard that suppresses clearly system-dominant mic chunks in live preview windows
- Immediate transcript availability when recording stops

---

## Permissions

| Permission | Why | When Requested | Fallback |
|------------|-----|----------------|----------|
| Microphone | Dictation recording | Onboarding or first dictation attempt | Show permission dialog with instructions |
| Accessibility | Global shortcut detection + text insertion | Onboarding or first dictation attempt | Show System Settings deep link |
| Screen & System Audio Recording | Meeting recording (system audio capture via ScreenCaptureKit) | Optional onboarding step or first meeting recording attempt | Show error + "Open System Settings" button, block recording |

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
