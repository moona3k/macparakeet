---
title: Meeting Recording Dual-Stream Transcription Pipeline
status: ACTIVE
date: 2026-04-12
authors: Codex/GPT, Daniel Moon
---

# Meeting Recording Dual-Stream Transcription Pipeline

> Status: **ACTIVE** - current implementation and design notes
> Related spec: `spec/05-audio-pipeline.md`, `spec/06-stt-engine.md`
> Related ADRs: `spec/adr/014-meeting-recording.md`, `spec/adr/015-concurrent-dictation-meeting.md`, `spec/adr/016-centralized-stt-runtime-scheduler.md`

## TL;DR

MacParakeet meeting recording is a **dual-stream capture pipeline**:

- **microphone** audio is captured separately
- **system** audio is captured separately
- both streams feed the **live transcript UI** during recording
- both streams are written to disk as separate files
- after stop, the two source files are mixed into `meeting.m4a` for playback/export
- final post-stop STT does **not** transcribe `meeting.m4a`
- instead, it runs fresh batch STT separately on:
  - `microphone.m4a`
  - `system.m4a`
- those fresh results are merged by persisted source-alignment metadata

The important constraints:

- `meeting.m4a` is usually **stereo** (`L=mic`, `R=system`)
- Parakeet / FluidAudio are still **mono** in this app pipeline
- the live transcript is now **live/UI-only**
- `preparedTranscript` is no longer part of the final correctness path

## Why this doc exists

There are several similar-but-not-identical concepts in the meeting pipeline:

- raw capture streams
- live chunk transcription
- persisted source files
- mixed playback artifact
- final post-stop transcription
- source-alignment metadata
- optional diarization

These are easy to collapse mentally into "the app records one file and transcribes it," which is not what the current implementation does.

This note documents the current architecture after:

- the VPIO rollback work
- the Parakeet / FluidAudio mono-input investigation
- the meeting-finalization redesign that removed `preparedTranscript`

## End-to-end flow

```text
Meeting starts
    │
    ├── MicrophoneCapture
    │     └── raw mic buffers
    │
    ├── SystemAudioTap
    │     └── system audio buffers
    │
    └── MeetingAudioCaptureService
          └── AsyncStream<MeetingAudioCaptureEvent>
                    │
                    ▼
             MeetingRecordingService
                    │
                    ├── write source files
                    │     ├── microphone.m4a
                    │     └── system.m4a
                    │
                    ├── persist source timing/alignment metadata
                    │     └── meeting-recording-metadata.json
                    │
                    ├── resample + join + chunk
                    │     └── CaptureOrchestrator
                    │
                    ├── mic cleanup
                    │     ├── SoftwareAECConditioner (default)
                    │     └── live mic suppression when system dominates
                    │
                    └── LiveChunkTranscriber
                          └── MeetingTranscriptAssembler
                                └── live transcript UI only

Meeting stops
    │
    ├── finalize source files
    ├── mix microphone.m4a + system.m4a -> meeting.m4a
    └── TranscriptionService.transcribeMeeting(recording:)
          ├── convert microphone.m4a -> 16 kHz mono WAV
          ├── batch STT on mic WAV
          ├── convert system.m4a -> 16 kHz mono WAV
          ├── batch STT on system WAV
          ├── align words using persisted source offsets
          ├── merge source-aware words into final transcript
          └── optionally diarize the isolated system track additively
```

## Capture model

Meeting recording captures **two logical sources**:

1. `AudioSource.microphone`
2. `AudioSource.system`

Relevant code:

- `MeetingAudioCaptureService`
- `MicrophoneCapture`
- `SystemAudioTap`
- `MeetingRecordingService.handleCaptureEvent(...)`

The streams are not merged at capture time. They stay distinct long enough to support:

- separate recording artifacts
- source-aware live transcription
- microphone conditioning against the system reference
- persisted source timing/alignment for post-stop merge

## Stored artifacts

Each meeting session produces a folder containing:

```text
meeting-recordings/<uuid>/
├── microphone.m4a
├── system.m4a
├── meeting.m4a
└── meeting-recording-metadata.json
```

Semantics:

- `microphone.m4a`: mic-only source recording
- `system.m4a`: system-only source recording
- `meeting.m4a`: final mixed playback/export artifact
- `meeting-recording-metadata.json`: persisted source alignment metadata for post-stop merge

`MeetingRecordingOutput` carries:

- all three audio URLs
- meeting duration
- `MeetingSourceAlignment`

Relevant code:

- `Sources/MacParakeetCore/Services/MeetingRecordingOutput.swift`
- `Sources/MacParakeetCore/Services/MeetingRecordingMetadata.swift`
- `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`

## What `meeting.m4a` actually is

For the normal two-source meeting case, `meeting.m4a` is **stereo**:

- left channel = microphone
- right channel = system audio

Relevant code:

- `AudioFileConverter.mixToM4A(...)`
- `AudioFileConverter.ffmpegMixArguments(...)`

The FFmpeg graph explicitly pans mic to the left channel and system to the right channel before mixing them into a 2-channel AAC output.

For single-input fallback sessions, the output remains mono.

Important: `meeting.m4a` is a **playback/export artifact**, not the authoritative STT input.

## Live transcription path

During recording, both streams feed the live transcript pipeline.

### Source handling

`MeetingRecordingService.handleCaptureEvent(...)`:

- writes the raw buffer to the per-source file
- records first/last host-time observations per source
- extracts / resamples samples for orchestration
- routes mic and system to `CaptureOrchestrator`

`CaptureOrchestrator`:

- joins mic/system samples by host time
- applies the mic conditioner using system audio as reference
- chunks mic and system independently for live STT

Relevant code:

- `Sources/MacParakeetCore/Services/CaptureOrchestrator.swift`
- `Sources/MacParakeetCore/Services/MeetingAudioPairJoiner.swift`

### Microphone cleanup in the live path

The shipped default is:

- `SoftwareAECConditioner` for mic cleanup
- plus transcript-layer suppression when system audio strongly dominates recent processed mic energy

Relevant code:

- `MeetingRecordingService.configureMicConditioner(...)`
- `MeetingRecordingService.shouldSuppressMicrophoneChunkTranscription()`

Important nuance:

- suppressed mic chunks are skipped for **live transcription**
- the mic audio is still recorded to disk
- the mic audio is still included in the final mixed artifact

So this suppression is a transcript-quality safeguard, not destructive audio editing.

### Transcript assembly

`MeetingTranscriptAssembler` builds a source-aware live transcript:

- each live word gets `speakerId = source.rawValue`
- active speakers become `Me` / `Others`
- diarization-style segments are built from the ordered words

`MeetingRealtimeTranscript` still exists as the live transcript model, but it is now **UI-only**.
It no longer feeds final meeting transcription.

Relevant code:

- `Sources/MacParakeetCore/Services/MeetingTranscriptAssembler.swift`

## Source alignment metadata

Post-stop dual-source merge is only correct if the app persists a shared time origin for the recorded source files.

MacParakeet now persists `MeetingSourceAlignment`, which records per source:

- first observed host time
- last observed host time
- source start offset in milliseconds relative to a shared meeting origin
- written frame count
- recorded sample rate

This metadata is:

- returned in `MeetingRecordingOutput`
- written to `meeting-recording-metadata.json`

Why it exists:

- `microphone.m4a` and `system.m4a` are written as independent continuous files
- each post-stop STT pass returns timestamps relative to its own file origin
- the offsets are needed to align the two fresh transcripts onto a single meeting timeline

Without this metadata, "transcribe both files and sort by timestamps" would be guesswork.

## Archived meeting retranscription path

Saved meeting retranscription from the library now reuses the same dual-source finalization flow when the archived meeting folder still contains:

- `meeting.m4a`
- `microphone.m4a`
- `system.m4a`
- `meeting-recording-metadata.json`

`TranscriptionViewModel` reconstructs a `MeetingRecordingOutput` from the archived folder and calls `TranscriptionService.transcribeMeeting(recording:)` again instead of routing the meeting through generic mixed-file transcription.

Important nuance:

- this keeps later retranscribes aligned with the immediate post-stop correctness path
- legacy meeting rows that only have `meeting.m4a` still fall back to mixed-file transcription so old data keeps working

## Post-stop final transcription path

After stop, `TranscriptionService.transcribeMeeting(recording:)` performs a **fresh batch STT pass per source file**:

1. convert `microphone.m4a` to mono WAV and transcribe it
2. convert `system.m4a` to mono WAV and transcribe it
3. shift each result by its persisted source start offset
4. merge the shifted words into one source-aware transcript

This pass is the authoritative source for the final raw text.

Relevant code:

- `Sources/MacParakeetCore/Services/TranscriptionService.swift`
- `Sources/MacParakeetCore/Services/MeetingTranscriptFinalizer.swift`

### Base finalization contract

Baseline meeting finalization is source-aware, not diarization-first:

- mic words keep `speakerId = "microphone"`
- system words keep `speakerId = "system"`
- merged diarization-style segments are built from those source-aware words

This is the default final result even when diarization is disabled.

### Optional diarization is additive

If speaker diarization is enabled and available, it is applied **only to the isolated system track**.

That means:

- mic attribution stays `microphone`
- system words may be refined from `system` to namespaced IDs like `system:S1`, `system:S2`
- source identity is still preserved because the IDs remain system-prefixed

This is intentionally additive:

- diarization does not create the primary source structure
- diarization refines only the remote/system side when available

## The most important constraint: Parakeet / FluidAudio are mono here

Current MacParakeet final STT does **not** preserve stereo into Parakeet.

### App-level conversion

Before STT, MacParakeet converts each source file to:

- WAV
- `16 kHz`
- `mono`
- Float32 PCM

Relevant code:

- `AudioFileConverter.convert(fileURL:)`
- `AudioProcessor.convert(fileURL:)`

### FluidAudio behavior

FluidAudio's `AudioConverter` normalizes input to `16 kHz mono Float32`.

In the pinned dependency and upstream docs:

- stereo input is mixed down to mono
- `>2` channels are averaged to mono before resampling
- file, buffer, and streaming paths all become mono before ASR

### Parakeet model expectation

NVIDIA's Parakeet TDT 0.6B-v3 model card describes the model as:

- `16 kHz`
- `1D (audio signal)`
- `Monochannel audio`

So the practical constraint is:

- MacParakeet can store stereo meeting artifacts
- but Parakeet / FluidAudio do not consume those artifacts as stereo in this app pipeline

This is exactly why the current finalization design transcribes the separate source files independently instead of trying to feed stereo `meeting.m4a` into Parakeet.

## Why the current design is clean

This architecture keeps the right responsibilities separated:

- **capture** preserves the strongest source artifacts (`microphone.m4a`, `system.m4a`, stereo `meeting.m4a`)
- **live transcript** serves responsiveness and the meeting panel UI
- **final transcript** is built from fresh post-stop source-file STT, not from live metadata
- **diarization** is optional refinement, not the primary structure source

That gives MacParakeet:

- a stable dual-stream meeting architecture
- no reliance on stale live transcript metadata for final correctness
- no false hope that Parakeet is secretly channel-aware here
- a strong foundation for future channel-aware or source-aware improvements

## Known constraints / future options

The current implementation is a good foundation, but there are still real limits:

1. **Parakeet remains mono in this app path**
   - true multichannel-aware ASR would require a different backend or a different app-level strategy

2. **Source alignment is currently offset-based**
   - persisted start offsets are sufficient for the current design
   - if long-session drift ever appears materially, the stored first/last host times and frame counts provide the diagnostic basis for correction

3. **Optional diarization only refines the system side today**
   - that is intentional
   - it prevents diarization from replacing the primary mic/system structure

4. **`meeting.m4a` remains valuable even though it is not the authoritative STT input**
   - playback/export artifact
   - stereo archival asset
   - future post-processing input if a better multichannel-aware backend is adopted

## Summary

Current MacParakeet meeting recording works like this:

- capture mic + system separately
- transcribe them live for UI only
- save separate source files plus a stereo mixed artifact
- persist source-alignment metadata
- after stop, transcribe the two source files separately
- merge those fresh results by shared time origin
- optionally refine the system side with diarization

The important mental model is:

- **live transcript** is not the final truth
- **`meeting.m4a`** is not the final STT input
- **the separate source files plus source alignment metadata** are the finalization source of truth
