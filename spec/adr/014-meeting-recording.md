# ADR-014: Meeting Recording via ScreenCaptureKit System Audio

> Status: IMPLEMENTED
> Date: 2026-04-05
> Related: ADR-001 (Parakeet STT), ADR-007 (FluidAudio CoreML), ADR-010 (speaker diarization), ADR-021 (WhisperKit optional STT), [GitHub #57](https://github.com/moona3k/macparakeet/issues/57)
> Amended: 2026-04-10 (historical: meeting mic echo mitigation via joined software AEC + observability hardening)
> Amended: 2026-04-29 (replace Core Audio process taps with ScreenCaptureKit audio so VPIO can remain enabled on the meeting mic path)
> Amended: 2026-05-09 (pause/resume for active recordings — [issue #235](https://github.com/moona3k/macparakeet/issues/235))

## Context

MacParakeet has three co-equal modes: system-wide dictation, file transcription, and meeting recording (added by this ADR). Parakeet STT via FluidAudio CoreML is the default on-device transcription path; ADR-021 adds optional WhisperKit for broader local language coverage. Users have requested the ability to record live meetings and calls — capturing both system audio (the other participants) and mic audio (the user) simultaneously, then transcribing the result.

This came from exploring [GitHub #52](https://github.com/moona3k/macparakeet/issues/52) (hotkey profiles). The core ask was different workflows for different use cases. Meeting recording is the direct answer — a third mode that extends MacParakeet's voice-to-text capability without changing the product's simplicity.

The initial audio capture layer was ported from [Oatmeal](https://github.com/moona3k/oatmeal) and used Core Audio process taps for system audio plus AVAudioEngine for mic capture. Follow-up VPIO testing showed that Core Audio process taps and VPIO do not reliably coexist in MacParakeet's single-process meeting/dictation architecture, so system audio capture moved to ScreenCaptureKit while the mic path keeps AVAudioEngine.

## Decision

### 1. Add meeting recording as a third mode

MacParakeet becomes three co-equal modes:

| Mode | Audio Source | Duration | Output |
|------|-------------|----------|--------|
| Dictation | Mic | Seconds | Paste into active app |
| File transcription | Imported file | Any | Display + export |
| **Meeting recording** | **Mic + system audio** | **Minutes–hours** | **Display + export** |

### 2. ScreenCaptureKit for system audio (macOS 14.2+)

System audio is captured via ScreenCaptureKit `SCStream` audio (`SCStreamConfiguration.capturesAudio = true`, `SCStreamOutputType.audio`). This captures system audio without creating a HAL aggregate output device, which avoids the VPIO/process-tap conflict documented in `docs/research/vpio-process-tap-conflict.md`. It uses the same Screen & System Audio Recording permission already required by the meeting feature.

Key components:
- `SystemAudioStream` - ScreenCaptureKit audio wrapper, converts `CMSampleBuffer` to `AVAudioPCMBuffer`, and emits first-buffer/stall diagnostics
- `MicrophoneCapture` - AVAudioEngine input node tap with VPIO preferred (separate from existing `AudioRecorder`)
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
- `MicrophoneCapture` prefers macOS Voice Processing I/O so AEC/noise suppression/AGC happen before mic buffers enter the meeting pipeline.
- A short-window dominant-system guard remains in place for live mic chunk enqueue when recent system energy strongly dominates processed mic energy.
- The guard affects live mic chunk transcription only; mic audio is still stored and included in the finalized meeting artifact.
- Joiner queue overflow and sync-lag telemetry are logged for long-session observability.
- Dictation capture remains raw and unchanged (ADR-015 isolation still applies).

## Rationale

### Why not keep meeting recording in Oatmeal only?

Oatmeal adds intelligence on top of recording: AI meeting notes, entity extraction, calendar integration, cross-meeting RAG. MacParakeet's meeting recording is the simple, free version — just record and transcribe. This creates a natural funnel: MacParakeet (free) → Oatmeal (paid) for users who want the intelligence layer.

### Why reuse Transcription (not a new MeetingRecording model)?

A separate model would require duplicating the entire library infrastructure: repository, library view, export, summaries, chat, favorites, search. The `Transcription` model already has all the fields a meeting recording needs (timestamps, speakers, diarization segments, summaries, chat). Adding `sourceType` is a one-line migration.

### Why ScreenCaptureKit (not Core Audio process taps)?

Core Audio process taps were the original choice because they provide audio-only capture and worked for raw mic capture. They are no longer the correct first-principles solution once meeting mic AEC is a requirement: VPIO is a duplex I/O unit that introduces aggregate-device state, and MacParakeet's process tap also depends on aggregate-device output clocking. ScreenCaptureKit moves system audio capture to the WindowServer/replayd capture path and avoids claiming the HAL output device, so the mic can use VPIO without starving system-audio buffers.

### Why a separate coordinator (not extending DictationFlowCoordinator)?

Dictation has complex paste/cancel/undo behavior that meeting recording doesn't need. Meeting recording has permission checks and long-form timer states that dictation doesn't have. Sharing a coordinator would mean each mode carries the other's complexity. Two simple coordinators are better than one complex one.

### 11. Pause / resume for active recordings (2026-05-09 amendment)

[Issue #235](https://github.com/moona3k/macparakeet/issues/235) requested a pause button on meeting recording so users can stop and resume capture without splitting the session into multiple files. The shipped behavior:

- **Buffer-discard, not capture-teardown.** Pause sets an actor-isolated flag on `MeetingRecordingService`; incoming `microphoneBuffer` / `systemBuffer` events are dropped at the top of `handleCaptureEvent`. The OS-level mic + ScreenCaptureKit streams stay subscribed, so resume is instant and there is no mic/system desync from asymmetric teardown latency.
- **Audio file is gap-free.** `MeetingAudioStorageWriter`'s monotonic PTS counter is preserved across the pause window — no zero-fill, no pause marker. The final `.m4a` plays back as continuous audio (the user's stated downstream is re-transcribing the file with another model). Pauses are invisible in playback.
- **Elapsed timer is pause-aware.** `MeetingRecordingService` tracks `accumulatedPausedDuration` + an in-flight `pausedAt`; both `elapsedSeconds` (live) and `MeetingRecordingOutput.durationSeconds` (persisted) subtract paused time. Stopping while paused settles the in-flight pause into the total before computing the duration.
- **Capture-orchestrator reset on pause.** `CaptureOrchestrator.reset()` is called on pause so any pre-pause partial samples sitting in the pair joiner / chunker queues don't bridge into post-resume samples. The audio file is unaffected (the storage writer is independent of the chunker); only the live transcript loses any in-flight unfinalized chunk.
- **Pause is a sub-state of recording, not a flow state.** `MeetingRecordingFlowStateMachine` is unchanged. `CaptureMode` gains a `.paused` value; `MeetingRecordingPillViewModel.PillState` gains `.paused`. The flow coordinator's polling task reconciles the pill VM state from the service. The existing `captureMode == .stopped` failure path is widened to fire when `pillViewModel.state` is `.recording` *or* `.paused` so a USB mic unplug during pause still surfaces.
- **UI surfaces.** Pause/resume is reachable from three places: the floating pill's right-click menu, a button in the Meeting Panel header alongside Stop, and a button in the Transcribe-tab Meeting Recording tile. The pill rosette dims and shows pause bars while paused; the panel header swaps the live "Recording" label for "Paused" and hides the dual-audio orb (zeroed levels would render as a flat dot pretending to listen).
- **No telemetry, no hotkey, no lock-file changes in v1.** Telemetry needs the website allowlist updated in lockstep; punted to a follow-up PR. The lock file's `state` enum is not extended (`.paused` would only matter if recovery wanted to resume; today recovery always finalizes whatever is on disk, which is correct because the audio file already reflects everything captured before pause).

## Consequences

### Positive

- MacParakeet becomes a complete voice-to-text tool (dictation + files + meetings)
- Meeting recordings get prompt library, multi-summary, chat, and export for free
- System audio capture no longer depends on HAL aggregate-device clocking
- Clean architecture: parallel services, no coupling to existing dictation flow
- Phase 2 free diarization provides speaker attribution without ML overhead
- Speaker attribution quality improves on speakerphone calls by reducing echo-driven phantom "Me" chunks
- Meeting dual-source final artifacts preserve source separation (`L=mic`, `R=system`) when both tracks are present

### Negative

- **New permission:** Screen Recording permission is a significant UX cost. Users may be reluctant to grant it.
- **Larger audio files:** Meeting recordings generate much larger files than dictations (50–100 MB for 60 minutes). Audio is kept by default.
- **Product scope expansion:** MacParakeet goes from "two things well" to "three things well." Must resist further scope creep.
- **Code ported from Oatmeal:** ~1,200 lines of audio capture code to adapt. Divergence over time will need to be managed.
- **ScreenCaptureKit dependency:** system audio capture now depends on `SCStream` lifecycle and `CMSampleBuffer` adaptation rather than Core Audio process-tap IO procs.
- **Residual suppression tradeoff:** dominant-system live gating may still drop very quiet mic utterances during loud remote speech windows.

## Phased Rollout

1. **Phase 1 (MVP):** Start/stop recording, batch transcription, results in library. Sidebar + menu bar entry points. **Implemented.**
2. **Phase 2 (Enhancement):** Real-time transcription via AudioChunker, source-aware live preview, dual audio level meters in pill, live transcript preview. **Implemented.**
3. **Phase 3 (Polish):** Dedicated meeting hotkey, auto-save wiring, meeting title prefix + rename flow, hotkey conflict prevention, settings section. **Implemented.**
4. **Phase 4 (Concurrency):** Concurrent dictation during meeting recording (ADR-015). Menu bar icon priority aggregator. **Implemented.** STT runtime ownership and scheduling policy are defined separately in ADR-016.
