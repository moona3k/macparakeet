# 05 - Audio Pipeline

> Status: **ACTIVE** - Authoritative, current

The audio pipeline handles all audio input for MacParakeet: microphone recording for dictation and file input for transcription.

---

## Microphone Recording (Dictation)

### Capture Chain

```
Mic Input → AVAudioEngine tap → Sample Rate Conversion → Ring Buffer → WAV (temp) → M4A (final)
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
    → Send WAV to STT daemon
    → Move WAV to dictations/ for storage (if enabled)
    → Clean up temp WAV (if storage disabled)
```

---

## File Input (Transcription)

### Conversion Pipeline

```
Input File → FFmpeg → 16kHz mono WAV → STT Daemon → Transcript
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
- FFmpeg runs as a subprocess; progress is reported back to the UI

### Conversion Flow

```
User selects file
    → Validate format (check extension + probe with FFmpeg)
    → Validate duration <= max (4 hours default)
    → Convert to 16kHz mono WAV via FFmpeg
    → Send WAV to STT daemon
    → Return transcript
    → Clean up temp WAV
```

---

## Permissions

| Permission | Why | When Requested | Fallback |
|------------|-----|----------------|----------|
| Microphone | Dictation recording | First dictation attempt | Show permission dialog with instructions |
| Accessibility | Global hotkey detection + text insertion | First dictation attempt | Show System Settings deep link |

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
| Mic capture | Platform native | Varies | Mono | Float32 |
| After conversion | WAV | 16kHz | Mono | Float32 |
| STT input | WAV | 16kHz | Mono | Float32 |
| Long-term storage | WAV | 16kHz | Mono | Float32 |
| File import (temp) | WAV | 16kHz | Mono | Float32 |
