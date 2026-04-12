# 05 - Audio Pipeline

> Status: **ACTIVE** - Authoritative, current

The audio pipeline handles all audio input for MacParakeet: microphone recording for dictation, file input for transcription, and dual-stream capture (system audio + mic) for meeting recording.

---

## Microphone Recording (Dictation)

### Capture Chain

```
Mic Input → AVAudioEngine tap → Sample Rate Conversion → Ring Buffer → WAV
```

- **AVAudioEngine** with tap on input node
- **Sample rate conversion**: arbitrary input sample rate → 16kHz mono Float32 (required by Parakeet)
- **Ring buffer** for crash recovery — if the app crashes mid-recording, the ring buffer preserves audio data that can be recovered on next launch
- **Output format**: saved as WAV (16kHz mono, same format Parakeet expects)
- **Minimum sample threshold**: 81 samples required before sending to STT. Parakeet's Metal allocator crashes on header-only WAVs (files with valid headers but near-zero audio data). This guard prevents that failure mode.

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
    → Start AVAudioEngine
    → Install tap on input node
    → Convert samples to 16kHz mono Float32
    → Write to ring buffer
    → User stops dictation (or release-to-stop)
    → Flush ring buffer to temp WAV
    → Validate sample count >= 81
    → Send to FluidAudio STT (CoreML/ANE)
    → Move WAV to dictations/ for storage (if enabled)
    → Clean up temp WAV (if storage disabled)
```

---

## File Input (Transcription)

### Conversion Pipeline

```
Input File → FFmpeg → 16kHz mono WAV → FluidAudio STT (CoreML/ANE) → Transcript
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

### Conversion Flow

```
User selects file
    → Validate format (check extension + probe with FFmpeg)
    → Validate duration <= max (4 hours default)
    → Convert to 16kHz mono WAV via FFmpeg
    → Send to FluidAudio STT (CoreML/ANE)
    → Return transcript
    → Clean up temp WAV
```

---

## YouTube URL Input (Transcription)

### Download + Conversion Pipeline

```
YouTube URL → yt-dlp (audio only) → downloaded audio file → FFmpeg → 16kHz mono WAV → FluidAudio STT (CoreML/ANE) → Transcript
```

- `yt-dlp` is used with `--no-playlist` for single-video processing
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
    → Convert to 16kHz mono WAV via FFmpeg
    → Send to FluidAudio STT (CoreML/ANE) (emit "Transcribing... X%")
    → Save transcription (sourceURL set, filePath set only if retention enabled)
    → Clean up temp WAV (always)
```

---

## Meeting Recording (v0.6)

### Dual-Stream Capture

```
System Audio → Core Audio Taps → Aggregate Device → Buffer Callback ─┐
                                                                      ├→ MeetingAudioCaptureService
Mic Input    → AVAudioEngine (raw tap) → Input Node Tap ─────────────┘   (AsyncStream<MeetingAudioCaptureEvent>)
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
                                   - SoftwareAECConditioner (default)
                                   - VPIOConditioner (explicit opt-in only)
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

- **System audio** is captured via Core Audio Taps (`CATapDescription` + `AudioHardwareCreateProcessTap`), available on macOS 14.2+
- **Mic audio** is captured via `AVAudioEngine` input node tap with a typed policy (`MeetingMicProcessingMode`): `raw` (default), `vpioPreferred`, or `vpioRequired`.
- MacParakeet ships meeting capture in `raw` mode by default. VPIO remains available only as explicit opt-in plumbing; it is not used in production because the app's Core Audio process tap and VPIO do not coexist reliably in the same process. See `docs/research/vpio-process-tap-conflict.md`.
- Both streams are captured within the same meeting session and aligned by host time. `CaptureOrchestrator` owns join + offset + chunk boundaries via `MeetingAudioPairJoiner` + `AudioChunker`.
- Mic conditioning is policy-driven: `SoftwareAECConditioner` (NLMS) is the shipped default for meeting capture, while `VPIOConditioner` remains as an explicit opt-in pass-through for the dormant VPIO path.
- Audio is stored as separate M4A files (AAC 64kbps, 48kHz mono) per source
- After recording stops, microphone + system M4As are merged into `meeting.m4a`. Dual-input sessions preserve source separation as stereo (`L=mic`, `R=system`), while single-input sessions remain mono.
- Final meeting STT does **not** transcribe `meeting.m4a`. It transcribes `microphone.m4a` and `system.m4a` separately, then merges those fresh results by persisted `MeetingSourceAlignment`. `meeting.m4a` is kept as the playback/export artifact. See `docs/research/meeting-dual-stream-transcription-pipeline.md` for the full pipeline and tradeoffs.
- Live chunk enqueue keeps a conservative guard: when recent system energy strongly dominates processed mic energy for a short freshness window, mic chunks are skipped for live transcription only. Mic audio is still written to disk and included in final mix/output.
- Joiner queue overflow, long-session sync lag, and runtime capture failures are emitted as diagnostics for observability (`MeetingAudioCaptureEvent.error` where available).

### Key Components (ported from Oatmeal)

| Component | Purpose |
|-----------|---------|
| `SystemAudioTap` | Core Audio Taps wrapper — creates aggregate device, provides buffer callback |
| `MicrophoneCapture` | AVAudioEngine mic wrapper with explicit mic-processing policy + effective-mode reporting |
| `MeetingAudioCaptureService` | Actor combining both streams into `AsyncStream<MeetingAudioCaptureEvent>` with `.bufferingNewest(2048)` and runtime error emission where available |
| `CaptureOrchestrator` | Owns ingest/join/offset/chunk flow for live preview |
| `MicConditioner` | Mic cleanup abstraction (`SoftwareAECConditioner` default, `VPIOConditioner` opt-in pass-through) |
| `LiveChunkTranscriber` | Owns live chunk queueing, cancellation, ordering, STT invocation |
| `MeetingAudioStorageWriter` | Writes separate M4A files per source (mic + system) |
| `MeetingRecordingMetadataStore` | Persists `MeetingSourceAlignment` for post-stop merge correctness |
| `MeetingTranscriptFinalizer` | Merges fresh per-source STT results into the final meeting transcript |

### Meeting Recording Flow

```
User clicks "Start Meeting Recording"
    → Check Screen Recording permission (CGPreflightScreenCaptureAccess)
    → If denied: show error + "Open System Settings" button, block recording
    → Start MeetingAudioCaptureService (both streams)
    → Show recording pill (red dot + elapsed timer + stop button)
    → Consume AsyncStream<MeetingAudioCaptureEvent>, write buffers to M4A files
    → User clicks Stop
    → Stop capture, finalize `microphone.m4a` + `system.m4a`
    → Persist `meeting-recording-metadata.json` with per-source alignment
    → Merge streams into `meeting.m4a` (stereo for dual input; mono for single input)
    → Convert `microphone.m4a` → 16kHz mono WAV via FFmpeg
    → Send mic WAV to FluidAudio STT (CoreML/ANE)
    → Convert `system.m4a` → 16kHz mono WAV via FFmpeg
    → Send system WAV to FluidAudio STT (CoreML/ANE)
    → Merge fresh per-source STT using persisted source offsets
    → Optionally refine the isolated system side with diarization
    → Save as Transcription with sourceType = .meeting
    → Navigate to transcription detail view
```

### Storage

```
~/Library/Application Support/MacParakeet/meeting-recordings/{uuid}/
    ├── microphone.m4a    # Mic audio (AAC, 48kHz mono)
    ├── system.m4a        # System audio (AAC, 48kHz mono)
    ├── meeting.m4a       # Final playback/export artifact (stereo dual-source when both tracks exist; legacy fallback for downstream tools)
    └── meeting-recording-metadata.json  # Persisted source timing/alignment for post-stop merge
```

Audio files are kept by default. Users can delete manually from the transcription detail view.

### Concurrent Operation with Dictation (ADR-015)

Meeting recording and dictation run concurrently as fully independent pipelines. Each owns its own `AVAudioEngine` instance:

| Flow | Engine | Notes |
|------|--------|-------|
| Dictation | `AudioRecorder.audioEngine` | Created/destroyed per dictation session |
| Meeting mic | `MicrophoneCapture.audioEngine` | Long-lived, runs for entire meeting; raw mic capture feeds `CaptureOrchestrator` while software AEC + transcript-layer suppression handle speaker bleed |

macOS Core Audio's HAL natively multiplexes microphone access — multiple engines tapping the same physical mic is a supported pattern. There is no shared audio engine or audio broker.

All STT work routes through a process-wide scheduler and a single shared Parakeet runtime owner (ADR-016). That keeps:

- dictation on its own reserved interactive slot
- meeting live preview best-effort under backlog, with immediate post-stop finalization prioritized on the shared background slot
- file / YouTube transcription, plus legacy saved-meeting fallbacks without archived metadata, queued behind meeting work on that same background slot
- saved meetings with archived source metadata reuse the same `meetingFinalize` path as immediate post-stop finalization

The primary concurrency use case remains meeting recording + dictation. File transcription may coexist architecturally, but it should never degrade dictation responsiveness.

### Phase 2: Real-time Transcription

In Phase 2, an `AudioChunker` (ported from Oatmeal) buffers audio into 5-second chunks with 1-second overlap and sends them to Parakeet during recording. This provides:
- Live transcript preview in the recording pill
- Free speaker diarization: mic chunks → "Me", system chunks → "Them"
- Software AEC conditioning plus a residual safeguard that suppresses clearly system-dominant mic chunks in live preview windows
- Immediate transcript availability when recording stops

---

## Permissions

| Permission | Why | When Requested | Fallback |
|------------|-----|----------------|----------|
| Microphone | Dictation recording | First dictation attempt | Show permission dialog with instructions |
| Accessibility | Global hotkey detection + text insertion | First dictation attempt | Show System Settings deep link |
| Screen & System Audio Recording | Meeting recording (system audio capture via Core Audio Taps) | First meeting recording attempt | Show error + "Open System Settings" button, block recording |

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
