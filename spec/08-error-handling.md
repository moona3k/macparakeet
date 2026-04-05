# 08 - Error Handling

> Status: **ACTIVE** - Authoritative, current

## Philosophy

1. **Never lose user data** -- Dictation text, transcription results, and recordings must survive crashes.
2. **Graceful degradation** -- If STT fails, show an actionable error and offer retry. Never silently fail.
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
| CoreML failure | FluidAudio transcription error | Log error, offer retry |
| Transcription timeout | Transcription took > 60s | "Transcription timed out. Try a shorter recording." |
| Out of memory | Model too large for available RAM | "Close other apps to free memory" |
| Model not found | First run, model not downloaded | Show download progress |
| Model download failed | Network error during CoreML model download | "Check internet connection and retry" |

### Processing Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Pipeline error | Text processing stage failed | Fall back to raw text, log error |

### Dictation Control Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Stop requested before recording active | Stop key pressed while start flow is still in-flight and recorder has not reached `.recording` | Stop request is deferred until recording is active; no user action needed |
| Recording was not active | Stop requested while service is not recording and startup is not in-flight (invalid transition) | Show explicit overlay error and ask user to start dictation again |

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
- Auto-dismiss after 2-5 seconds depending on error path, with Dismiss affordance where available
- Red icon in tinted circle
- Technical errors mapped to 6 friendly categories with contextual hints
- Speech-engine failures explicitly direct users to onboarding or `Settings > Local Models > Repair`

### Dictation Stop/Start Race Handling

- Stop decisions are explicit and deterministic: `proceed`, `defer-until-recording`, or `reject-not-recording`.
- Deferred stop is applied immediately once `startRecording()` completes and the service reaches recording.
- Duplicate stop taps during in-flight stop/cancel/undo actions are ignored (idempotent stop).
- If startup never reaches recording, users get an explicit error card instead of silent teardown.

### Onboarding Model Failure

When first-run local model setup fails:
- Show the raw error detail (selectable text) plus user-friendly recovery tips.
- Provide direct CTAs: `Retry` and `Open Settings` (opens `Settings > Local Models`).
- Keep onboarding blocked until model setup succeeds (or user explicitly dismisses onboarding).

### Error Display Hierarchy

1. **Overlay error card** -- Dictation/recording errors with actionable text (2-5s auto-dismiss depending on error path)
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
- `.error` -- Recoverable errors (STT failure, fallback to raw text)
- `.fault` -- Unrecoverable errors (database corruption, crash)

**Privacy:** Audio content and transcription text are logged as `.private` to prevent leaking user data into system logs.

## Retry Strategy

| Operation | Max Retries | Backoff | Fallback |
|-----------|------------|---------|----------|
| STT model load | 3 | 1s, 2s, 4s | Show error, offer manual restart |
| Transcription | 2 | Immediate | Show error with raw audio preserved |
| LLM inference | 1 | Immediate | Skip AI features, show raw content |
| Database write | 3 | 100ms, 200ms, 400ms | Queue for retry on next launch |
| Network (model download) | 5 | Exponential (1s base) | Resume from last byte |

## Error Reporting

Errors are always logged locally. If telemetry is enabled, anonymized error events and crash reports may also be sent to MacParakeet's self-hosted telemetry pipeline. Users can export logs manually via:

```
Menu Bar > Help > Export Diagnostic Logs
```

This creates a zip of recent `os.Logger` entries with `.private` fields redacted.
