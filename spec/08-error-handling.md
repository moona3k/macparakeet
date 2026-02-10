# 08 - Error Handling

> Status: **ACTIVE** - Authoritative, current

## Philosophy

1. **Never lose user data** -- Dictation text, transcription results, and recordings must survive crashes.
2. **Graceful degradation** -- If the STT daemon crashes, show an actionable error and offer retry. Never silently fail.
3. **User-facing errors must be actionable** -- Every error the user sees must tell them what went wrong and what to do about it.
4. **Crash recovery via ring buffer** -- During active recording, audio is written to a ring buffer on disk so data survives unexpected termination.
5. **Structured logging** -- All internal errors logged via `os.Logger` with appropriate levels. User-facing errors are a separate concern.

## Error Categories

### Audio Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Mic access denied | System Preferences > Privacy | Show "Open Settings" button |
| No audio input | No mic connected / device offline | "Check your microphone connection" |
| Audio session interrupted | Another app claimed exclusive access | Auto-retry when session resumes |

### STT Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Daemon crash | Python process exited unexpectedly | Auto-restart daemon, retry transcription |
| Daemon timeout | Transcription took > 60s | "Transcription timed out. Try a shorter recording." |
| Out of memory | Model too large for available RAM | "Close other apps to free memory" |
| Model not found | First run, model not downloaded | Show download progress |
| Python env failed | uv bootstrap failed | "Check internet connection and retry" |

### Processing Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Pipeline error | Text processing stage failed | Fall back to raw text, log error |
| LLM inference failed | MLX model error or OOM | Skip AI features, show raw transcript |

### Export / Storage Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| File permission denied | Read-only directory or sandbox issue | "Choose a different save location" |
| Disk full | No space for database or audio | "Free up disk space (need ~X MB)" |
| Database corruption | Unexpected shutdown during write | Auto-recover from WAL, warn user if data lost |
| Import failed | Unsupported format or corrupt file | "This file format is not supported" |

## Ring Buffer Crash Recovery

During active recording, audio is continuously written to a temporary ring buffer file:

```
~/Library/Application Support/MacParakeet/recovery/
  recording-buffer.raw      # Current recording ring buffer
  recording-meta.json       # Timestamps, sample rate, channel config
```

**Recovery flow:**
1. On app launch, check for `recording-meta.json`
2. If found, a previous recording was interrupted
3. Prompt user: "A recording was interrupted. Recover audio?"
4. If yes, import the buffer as a new dictation
5. Clean up recovery files after user decision

**Buffer parameters:**
- Format: Raw PCM (same as capture pipeline)
- Max size: 500 MB (~4 hours at 16-bit 16kHz mono)
- Flush interval: Every 5 seconds

## Error States in UI

### Overlay Error Card

Errors in the dictation overlay use a wider rounded-rectangle card (not the compact pill). See `04-ui-patterns.md` for full visual spec.

- Two-line text: bold title + actionable subtitle (no truncation needed)
- Auto-dismiss after 5 seconds, Dismiss button for immediate close
- Red icon in tinted circle
- Technical errors mapped to 6 friendly categories with contextual hints

### Error Display Hierarchy

1. **Overlay toast** -- Transient errors during recording/dictation (3s auto-dismiss)
2. **Inline alert** -- Errors within a specific view (e.g., import failed)
3. **Modal alert** -- Blocking errors that need user decision (e.g., crash recovery)
4. **Status bar icon change** -- Persistent issues (e.g., mic disconnected)

## Structured Logging

All logging uses `os.Logger` with subsystem `com.macparakeet.app`:

```swift
// Categories
static let audio = Logger(subsystem: "com.macparakeet.app", category: "audio")
static let stt = Logger(subsystem: "com.macparakeet.app", category: "stt")
static let llm = Logger(subsystem: "com.macparakeet.app", category: "llm")
static let database = Logger(subsystem: "com.macparakeet.app", category: "database")
static let pipeline = Logger(subsystem: "com.macparakeet.app", category: "pipeline")
```

**Log levels:**
- `.debug` -- Verbose diagnostic info (timestamps, buffer sizes)
- `.info` -- Normal operations (recording started, transcription complete)
- `.error` -- Recoverable errors (daemon restart, fallback to raw text)
- `.fault` -- Unrecoverable errors (database corruption, crash)

**Privacy:** Audio content and transcription text are logged as `.private` to prevent leaking user data into system logs.

## Retry Strategy

| Operation | Max Retries | Backoff | Fallback |
|-----------|------------|---------|----------|
| STT daemon start | 3 | 1s, 2s, 4s | Show error, offer manual restart |
| Transcription | 2 | Immediate | Show error with raw audio preserved |
| LLM inference | 1 | Immediate | Skip AI features, show raw content |
| Database write | 3 | 100ms, 200ms, 400ms | Queue for retry on next launch |
| Network (model download) | 5 | Exponential (1s base) | Resume from last byte |

## Error Reporting

For v0.1, errors are logged locally only. No telemetry or crash reporting is sent anywhere -- consistent with the local-first philosophy. Users can export logs manually via:

```
Menu Bar > Help > Export Diagnostic Logs
```

This creates a zip of recent `os.Logger` entries with `.private` fields redacted.
