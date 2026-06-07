# 08 - Error Handling

> Status: **ACTIVE** - Authoritative, current

## Philosophy

1. **Never lose user data** -- Dictation text, transcription results, and recordings must survive crashes.
2. **Graceful degradation** -- If STT fails, show an actionable error and offer retry. Never silently fail.
3. **User-facing errors must be actionable** -- Every error the user sees must tell them what went wrong and what to do about it.
4. **Crash recovery for meetings** -- During active meeting recording, fragmented source audio plus a session lock file preserve recoverable state after unexpected termination.
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
| Whisper model missing | Whisper selected before its local model is downloaded | Keep Parakeet available; show Whisper download action |
| Engine busy | STT jobs are queued/running or a meeting speech-engine lease is active | Disable engine switch; retry after work finishes |

### Processing Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Pipeline error | Text processing stage failed | Fall back to raw text, log error |

### Dictation Control Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Stop requested before recording active | Stop key pressed while start flow is still in-flight and recorder has not reached `.recording` | Stop request is deferred until recording is active; no user action needed |
| Recording was not active | Stop requested while service is not recording and startup is not in-flight (invalid transition) | Show explicit overlay error and ask user to start dictation again |

### Meeting Recording Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| Screen Recording denied | User denied Screen & System Audio Recording permission | Show error + "Open System Settings" button, block recording |
| System audio capture failed | ScreenCaptureKit stream setup failed or stopped unexpectedly | "System audio capture failed. Try restarting the app." |
| Mic capture failed during meeting | AVAudioEngine failed to start for meeting mic | "Microphone capture failed. Check your microphone connection." |
| Mix failed | FFmpeg failed to mix mic + system M4A files | Log error, attempt transcription of individual streams |
| Chunk transcription backpressure | Live transcription can't keep pace with recording | Silent degradation: final batch transcription still produces full result |
| Meeting hotkey conflict | Meeting hotkey same as dictation hotkey | Block in Settings UI; at runtime, log warning and skip conflicting trigger |

### Export / Storage Errors

| Error | Cause | User Action |
|-------|-------|-------------|
| File permission denied | Read-only directory or sandbox issue | "Choose a different save location" |
| Disk full | No space for database or audio | "Free up disk space (need ~X MB)" |
| Database corruption | Unexpected shutdown during write | Auto-recover from WAL, warn user if data lost |
| Import failed | Unsupported format or corrupt file | "This file format is not supported" |

## Meeting Recording Crash Recovery

During active meeting recording, MacParakeet writes fragmented source audio and a lock file into the meeting session directory:

```
~/Library/Application Support/MacParakeet/meeting-recordings/{uuid}/
  microphone.m4a
  system.m4a
  recording.lock
```

**Recovery flow:**
1. On app launch, scan meeting-recording directories for `recording.lock`.
2. If a lock exists, the previous meeting session was interrupted.
3. Validate surviving source audio and load lock metadata, including title, notes, and captured speech engine/language.
4. Recover the meeting into the transcription library when audio exists; otherwise clean up empty sessions according to the recovery service rules.
5. Final transcription uses the same captured speech engine/language that was active when the meeting started.
6. Remove the lock after successful recovery/finalization.

Dictation does not use this lock-file recovery path. Short dictation audio is written as a temp WAV and rejected before STT if it contains too little audio.

## Error States in UI

### Overlay Error Card

Errors in the dictation overlay use a wider rounded-rectangle card (not the compact pill). See `04-ui-patterns.md` for full visual spec.

- Two-line text: bold title + actionable subtitle (no truncation needed)
- Auto-dismiss after 2-5 seconds depending on error path, with Dismiss affordance where available
- Red icon in tinted circle
- Technical errors mapped to 6 friendly categories with contextual hints
- Speech-engine failures explicitly direct users to onboarding or `Settings > Speech Recognition` repair/download actions

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

Local diagnostics use `os.Logger`. Current subsystems are layered by target:

```swift
Logger(subsystem: "com.macparakeet.app", category: "DictationFlow")
Logger(subsystem: "com.macparakeet.core", category: "TranscriptionService")
Logger(subsystem: "com.macparakeet.viewmodels", category: "SettingsViewModel")
Logger(subsystem: "com.macparakeet", category: "CalendarService") // legacy/simple cases
```

New log lines should use stable event-style messages with `key=value`
dimensions, for example `meeting_recording_started session=<uuid>`, rather than
free-form prose. Local logs are for developer triage and explicit diagnostic
bundles; product-health analytics come from typed telemetry operation events in
`docs/telemetry.md`.

**Log levels:**
- `.debug` -- Verbose diagnostic info, high-volume details, and gated traces
- `.info` / `.notice` -- Normal lifecycle transitions and notable state changes
- `.warning` -- Degraded but recoverable behavior (fallbacks, stalls, retries)
- `.error` -- Failed operations or recoverable errors that require attention
- `.fault` -- Unrecoverable corruption or crash-adjacent failures

**Privacy:** Transcript text, prompts, notes, file names, file paths, URLs,
provider error bodies, microphone names, CoreAudio device IDs, and device UIDs
must be logged as `.private` or omitted. Prefer structured safe dimensions such
as extension, file-size bucket, source, stage, outcome, device presence,
coarse device transport, and classified `error_type`.

Shareable audio diagnostics are stricter than local `os.Logger` entries. Raw
`localizedDescription` values may be kept in private OSLog fields for local
debugging, but `~/Library/Logs/MacParakeet/dictation-audio.log` and any future
diagnostic bundle must use classified `error_type` plus sanitized, single-line
`error_detail` values. Device identity in these shareable logs is limited to
`present`/`none` and coarse transport labels such as `built-in`, `usb`,
`bluetooth`, `aggregate-*`, `virtual`, or `unknown`.

## Retry Strategy

| Operation | Max Retries | Backoff | Fallback |
|-----------|------------|---------|----------|
| STT model load | 3 | 1s, 2s, 4s | Show error, offer manual restart |
| Transcription | 2 | Immediate | Show error with raw audio preserved |
| LLM inference | 1 | Immediate | Skip AI features, show raw content |
| Database write | 3 | 100ms, 200ms, 400ms | Queue for retry on next launch |
| Network (model download) | 5 | Exponential (1s base) | Resume from last byte |

## Error Reporting

Errors are always logged locally. If telemetry is enabled, non-identifying
operation failures and crash reports may also be sent to MacParakeet's
self-hosted telemetry pipeline.

The in-app feedback flow has an explicit opt-in control for attaching
`~/Library/Logs/MacParakeet/dictation-audio.log` when users report dictation or
meeting recording problems. The attachment is scoped to a recent window by
default (`DiagnosticLogScope.recent`: the last 7 days, with 2 MB / 20k-line
safety ceilings, falling back to the last few hundred lines when nothing is
that recent) so a public issue carries the window around the bug rather than the
full multi-week on-disk history. An advanced "Include full history" toggle lifts
the time window to the entire on-disk log for intermittent issues. Scoping
selects *whole lines by recency*; it never edits line contents, which are
already privacy-scrubbed at write time.
A broader diagnostic bundle is still a follow-up:
it should contain recent MacParakeet `os.Logger` entries, the audio diagnostics
log, app version/build info, and redacted runtime metadata. It must not include
audio, transcripts, notes, prompts, file names, file paths, URLs, API keys, or
microphone identity (names, CoreAudio device IDs, device UIDs), and it must not
upload automatically.
