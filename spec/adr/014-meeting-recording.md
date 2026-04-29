# ADR-014: Meeting Recording via Core Audio Taps

> Status: IMPLEMENTED
> Date: 2026-04-05
> Related: ADR-001 (Parakeet STT), ADR-007 (FluidAudio CoreML), ADR-010 (speaker diarization), ADR-021 (WhisperKit optional STT), [GitHub #57](https://github.com/moona3k/macparakeet/issues/57)
> Amended: 2026-04-10 (meeting mic echo mitigation via joined software AEC + observability hardening)

## Context

MacParakeet has three co-equal modes: system-wide dictation, file transcription, and meeting recording (added by this ADR). Parakeet STT via FluidAudio CoreML is the default on-device transcription path; ADR-021 adds optional WhisperKit for broader local language coverage. Users have requested the ability to record live meetings and calls — capturing both system audio (the other participants) and mic audio (the user) simultaneously, then transcribing the result.

This came from exploring [GitHub #52](https://github.com/moona3k/macparakeet/issues/52) (hotkey profiles). The core ask was different workflows for different use cases. Meeting recording is the direct answer — a third mode that extends MacParakeet's voice-to-text capability without changing the product's simplicity.

The audio capture layer already exists in [Oatmeal](https://github.com/moona3k/oatmeal) (a separate meeting notes app under development, same owner). Oatmeal uses Core Audio Taps for system audio capture and AVAudioEngine for mic capture. This code can be ported directly.

## Decision

### 1. Add meeting recording as a third mode

MacParakeet becomes three co-equal modes:

| Mode | Audio Source | Duration | Output |
|------|-------------|----------|--------|
| Dictation | Mic | Seconds | Paste into active app |
| File transcription | Imported file | Any | Display + export |
| **Meeting recording** | **Mic + system audio** | **Minutes–hours** | **Display + export** |

### 2. Core Audio Taps for system audio (macOS 14.2+)

System audio is captured via Core Audio Taps (`CATapDescription` + `AudioHardwareCreateProcessTap`), which captures all system audio output without requiring screen recording in the traditional sense. This triggers the "Screen & System Audio Recording" permission prompt on macOS 14.2+.

Implementation is ported from Oatmeal's `SystemAudioTap.swift` (same owner, GPL-3.0). Key components:
- `SystemAudioTap` — Core Audio Taps wrapper, creates aggregate device with tap
- `MicrophoneCapture` — AVAudioEngine input node tap (separate from existing `AudioRecorder`)
- `MeetingAudioCaptureService` — Actor combining both streams into an `AsyncStream<MeetingAudioCaptureEvent>`
- `MeetingAudioStorageWriter` — Writes separate M4A files per source (mic + system)

### 3. Reuse Transcription model with sourceType column

Meeting recordings are stored as `Transcription` records with a new `sourceType` column:

```swift
public enum SourceType: String, Codable, Sendable {
    case file      // drag-drop audio/video
    case youtube   // YouTube URL
    case meeting   // meeting recording
}
```

This gives meeting recordings the full library infrastructure for free: export (TXT/MD/SRT/VTT/DOCX/PDF/JSON), prompt library, multi-summary tabs, chat, favorites, search, thumbnail grid.

No new table is needed. The migration adds a column and backfills existing records.

### 4. Separate state machine and coordinator

Meeting recording has a fundamentally different lifecycle from dictation:

| Aspect | Dictation | Meeting Recording |
|--------|-----------|-------------------|
| Duration | Seconds | Minutes–hours |
| Output | Paste into app | Save to library |
| Cancel | 5-second undo window | Immediate |
| Post-processing | Text refinement + paste | Batch transcription |
| Permissions | Mic + Accessibility | Mic + Screen Recording |

A shared state machine would make both harder to understand. `MeetingRecordingFlowStateMachine` + `MeetingRecordingFlowCoordinator` run parallel to dictation's and can operate concurrently (see ADR-015), with states:

```
idle → checkingPermissions → starting → recording(elapsedSeconds)
  → stopping → transcribing → completed(transcriptionID) | error
```

### 5. New MeetingAudioCaptureService, not an extension of AudioProcessor

The existing `AudioProcessor` is a single-stream actor wrapping `AudioRecorder` (mic → WAV) and `AudioFileConverter` (FFmpeg). Meeting recording requires dual concurrent streams with buffer-level callbacks. Extending `AudioProcessor` would break its single-responsibility or create a confusing API surface.

`MeetingAudioCaptureService` is a parallel service at the same level, behind its own protocol.

### 6. Screen Recording permission required, no fallback

If the user denies Screen Recording permission, meeting recording is blocked entirely. No mic-only fallback. This keeps the UX simple — the feature either works fully or doesn't. The permission is requested on first meeting recording attempt, not during onboarding.

### 7. Batch transcription first; live preview implemented later

Parakeet at 155x realtime transcribes 60 minutes of audio in ~23 seconds. Batch transcription (transcribe after recording stops) was the MVP. Real-time chunked transcription (5-second chunks during recording) shipped in Phase 2 and is best-effort; final post-stop transcription remains authoritative.

### 8. Source-aware meeting finalization

Keeping mic and system audio as separate streams enables source-aware attribution: mic audio = "Me", system audio = remote speakers. Final meeting STT transcribes the per-source files separately and merges fresh results using persisted source-alignment metadata; `meeting.m4a` is the playback/export artifact, not the authoritative STT input.

### 9. Speech engine captured at recording start

The meeting service captures the active `SpeechEngineSelection` at start and persists it in the session metadata/lock file. Live preview, final transcription, retranscription of archived source files, and crash recovery use that captured selection. Settings cannot switch engines while the meeting's speech-engine lease is active.

### 9. Meeting mic echo mitigation (v0.6 hardening)

To reduce phantom "Me" fragments when users are on speakers:

- Meeting mic/system buffers are paired in `MeetingAudioPairJoiner` with bounded lag handling and silence-fill fallback.
- `MeetingRecordingService` runs `MeetingSoftwareAEC` (NLMS adaptive cancellation) on joined frames, using system audio as the far-end reference.
- A short-window dominant-system guard remains in place for live mic chunk enqueue when recent system energy strongly dominates processed mic energy.
- The guard affects live mic chunk transcription only; mic audio is still stored and included in the finalized meeting artifact.
- Joiner queue overflow and sync-lag telemetry are logged for long-session observability.
- Dictation capture remains raw and unchanged (ADR-015 isolation still applies).

## Rationale

### Why not keep meeting recording in Oatmeal only?

Oatmeal adds intelligence on top of recording: AI meeting notes, entity extraction, calendar integration, cross-meeting RAG. MacParakeet's meeting recording is the simple, free version — just record and transcribe. This creates a natural funnel: MacParakeet (free) → Oatmeal (paid) for users who want the intelligence layer.

### Why reuse Transcription (not a new MeetingRecording model)?

A separate model would require duplicating the entire library infrastructure: repository, library view, export, summaries, chat, favorites, search. The `Transcription` model already has all the fields a meeting recording needs (timestamps, speakers, diarization segments, summaries, chat). Adding `sourceType` is a one-line migration.

### Why Core Audio Taps (not ScreenCaptureKit)?

Core Audio Taps (macOS 14.2+) provide audio-only capture without screen recording overhead. They create an aggregate device with a tap that intercepts system audio output. This is the same approach Oatmeal uses, and it works within MacParakeet's existing macOS 14.2+ minimum version requirement.

### Why a separate coordinator (not extending DictationFlowCoordinator)?

Dictation has complex paste/cancel/undo behavior that meeting recording doesn't need. Meeting recording has permission checks and long-form timer states that dictation doesn't have. Sharing a coordinator would mean each mode carries the other's complexity. Two simple coordinators are better than one complex one.

## Consequences

### Positive

- MacParakeet becomes a complete voice-to-text tool (dictation + files + meetings)
- Meeting recordings get prompt library, multi-summary, chat, and export for free
- Audio capture code is proven (already running in Oatmeal)
- Clean architecture: parallel services, no coupling to existing dictation flow
- Phase 2 free diarization provides speaker attribution without ML overhead
- Speaker attribution quality improves on speakerphone calls by reducing echo-driven phantom "Me" chunks
- Meeting dual-source final artifacts preserve source separation (`L=mic`, `R=system`) when both tracks are present

### Negative

- **New permission:** Screen Recording permission is a significant UX cost. Users may be reluctant to grant it.
- **Larger audio files:** Meeting recordings generate much larger files than dictations (50–100 MB for 60 minutes). Audio is kept by default.
- **Product scope expansion:** MacParakeet goes from "two things well" to "three things well." Must resist further scope creep.
- **Code ported from Oatmeal:** ~1,200 lines of audio capture code to adapt. Divergence over time will need to be managed.
- **Adaptive-filter tuning tradeoff:** software AEC adds additional tuning/maintenance surface (filter length, adaptation rate, double-talk behavior).
- **Residual suppression tradeoff:** dominant-system live gating may still drop very quiet mic utterances during loud remote speech windows.

## Phased Rollout

1. **Phase 1 (MVP):** Start/stop recording, batch transcription, results in library. Sidebar + menu bar entry points. **Implemented.**
2. **Phase 2 (Enhancement):** Real-time transcription via AudioChunker, source-aware live preview, dual audio level meters in pill, live transcript preview. **Implemented.**
3. **Phase 3 (Polish):** Dedicated meeting hotkey, auto-save wiring, meeting title prefix + rename flow, hotkey conflict prevention, settings section. **Implemented.**
4. **Phase 4 (Concurrency):** Concurrent dictation during meeting recording (ADR-015). Menu bar icon priority aggregator. **Implemented.** STT runtime ownership and scheduling policy are defined separately in ADR-016.
