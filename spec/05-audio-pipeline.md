# 05 - Audio Pipeline

> Status: **ACTIVE** - Authoritative, current

The audio pipeline handles all audio input for MacParakeet: microphone recording for dictation and file input for transcription.

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
System Audio → Core Audio Taps → Aggregate Device → Buffer Callback → M4A
Mic Input    → AVAudioEngine   → Input Node Tap   → Buffer Callback → M4A
                                                          │
                                                          ▼
                                              MeetingAudioCaptureService
                                              (AsyncStream<CaptureEvent>)
                                                          │
                                                          ▼
                                              MeetingAudioStorageWriter
                                              (separate M4A per source)
                                                          │
                                                          ▼ (on stop)
                                              AudioFileConverter (FFmpeg)
                                              → 16kHz mono WAV → Parakeet STT
```

- **System audio** is captured via Core Audio Taps (`CATapDescription` + `AudioHardwareCreateProcessTap`), available on macOS 14.2+
- **Mic audio** is captured via `AVAudioEngine` input node tap (separate from the existing `AudioRecorder` used by dictation — `MicrophoneCapture` provides raw buffer callbacks, not WAV file output)
- Both streams are independent — no synchronization between them. Timing comes from `AVAudioTime` host time on each buffer
- Audio is stored as separate M4A files (AAC 64kbps, 16kHz mono) per source
- After recording stops, system audio M4A is converted to 16kHz mono WAV via FFmpeg and transcribed with Parakeet

### Key Components (ported from Oatmeal)

| Component | Purpose |
|-----------|---------|
| `SystemAudioTap` | Core Audio Taps wrapper — creates aggregate device, provides buffer callback |
| `MicrophoneCapture` | AVAudioEngine mic wrapper — raw buffer callback (not file output) |
| `MeetingAudioCaptureService` | Actor combining both streams into `AsyncStream<CaptureEvent>` with `.bufferingNewest(32)` |
| `MeetingAudioStorageWriter` | Writes separate M4A files per source (mic + system) |

### Meeting Recording Flow

```
User clicks "Start Meeting Recording"
    → Check Screen Recording permission (CGPreflightScreenCaptureAccess)
    → If denied: show error + "Open System Settings" button, block recording
    → Start MeetingAudioCaptureService (both streams)
    → Show recording pill (red dot + elapsed timer + stop button)
    → Consume AsyncStream<CaptureEvent>, write buffers to M4A files
    → User clicks Stop
    → Stop capture, finalize M4A files
    → Convert system audio M4A → 16kHz mono WAV via FFmpeg
    → Send to FluidAudio STT (CoreML/ANE) for batch transcription
    → Save as Transcription with sourceType = .meeting
    → Navigate to transcription detail view
```

### Storage

```
~/Library/Application Support/MacParakeet/meeting-recordings/{uuid}/
    ├── microphone.m4a    # Mic audio (AAC, 16kHz mono)
    └── system.m4a        # System audio (AAC, 16kHz mono)
```

Audio files are kept by default. Users can delete manually from the transcription detail view.

### Phase 2: Real-time Transcription

In Phase 2, an `AudioChunker` (ported from Oatmeal) buffers audio into 5-second chunks with 1-second overlap and sends them to Parakeet during recording. This provides:
- Live transcript preview in the recording pill
- Free speaker diarization: mic chunks → "Me", system chunks → "Them"
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
| Meeting mic storage | M4A (AAC) | 16kHz | Mono | 64kbps |
| Meeting system audio storage | M4A (AAC) | 16kHz | Mono | 64kbps |
| Meeting STT input (temp) | WAV | 16kHz | Mono | Float32 |
