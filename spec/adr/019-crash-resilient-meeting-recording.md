# ADR-019: Crash-resilient meeting recording via fragmented MP4 + session lock files

> Status: IMPLEMENTED
> Date: 2026-04-24
> Related: ADR-014 (meeting recording via ScreenCaptureKit system audio), ADR-016 (centralized STT runtime + scheduler)

## Context

Meeting recordings can run 40+ minutes — far longer than dictation or
file transcription. Long sessions are also exactly when laptops sleep
on low battery, the OS nags for a restart, or the app hits an
edge-case crash. The current `MeetingAudioStorageWriter`
(`Sources/MacParakeetCore/Audio/MeetingAudioStorageWriter.swift`)
uses `AVAudioFile`, which writes audio bytes incrementally but only
flushes the MP4 container's `moov` atom in `deinit` (when the
writer is set to nil during `finalize()`). Without the `moov` atom,
the resulting `microphone.m4a` and `system.m4a` are typically
unplayable — every byte of audio is on disk, but no decoder can
locate samples without the index.

Compounding the problem, three other artifacts only land on a clean
stop: `meeting-recording-metadata.json` (source-alignment offsets and captured
speech engine), `meeting.m4a` (the
mixed file FFmpeg produces from the two source files), and the full
post-stop transcription pass. So a crash mid-recording silently
loses the entire session — audio, alignment, and transcript — even
though most of the audio bytes are already on disk.

There is no crashed-session detection on next launch, no heartbeat,
no recovery flow. Users would lose everything from a 40-minute
meeting if the app force-quits at minute 39.

For long-running real-time media capture on Apple platforms, the
industry pattern is fragmented MP4 (`fmp4`): the writer flushes a
self-contained fragment every N seconds, each fragment is
independently parseable, and a partially-written file is playable up
to the last full fragment with no repair tools. This is the same
pattern used by QuickTime Player, iOS Voice Memos, iPhone screen
recording, Zoom, Loom, and OBS. Apple exposes the mechanism on
`AVAssetWriter` via the `movieFragmentInterval` property.

Quoting Apple's documentation
([`AVAssetWriter.movieFragmentInterval`](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval),
available since macOS 10.7):

> Some container formats, such as QuickTime movies, support writing
> movies in fragments. Using this feature enables you to open and
> play a partially written movie in the event that an unexpected
> error or interruption occurs.
>
> An asset writer disables this feature by default and sets this
> value to invalid. To enable fragment writing, set a valid CMTime
> value. For best performance when writing to external storage
> devices, set the movie fragment interval to 10 seconds or greater.
>
> You can't set this value after writing starts.

`AVAudioFile` has no equivalent flush hook — its API was designed
for short, atomic writes (think: dictation snippets), not long
real-time captures. Picking it for the meeting writer was likely an
early-stage choice when 30-second clips were the model.

## Decision

### 1. Replace `AVAudioFile` with `AVAssetWriter` configured for fragmented MP4

`MeetingAudioStorageWriter` will use one `AVAssetWriter` per selected source
(microphone and/or system), each configured with:

```swift
writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)          // 1 s steady-state
writer.initialMovieFragmentInterval = CMTime(value: 1, timescale: 1)   // 1 s initial — macOS 14.0+
writer.shouldOptimizeForNetworkUse = false  // not streaming, just resilient
```

Audio inputs use the existing AAC settings (`kAudioFormatMPEG4AAC`,
`AVSampleRateKey`, `AVNumberOfChannelsKey`, `AVEncoderBitRateKey`)
via `AVAssetWriterInput.init(mediaType: .audio, outputSettings:)`.
The container is `AVFileType.m4a`. `AVAudioPCMBuffer` instances are
converted to `CMSampleBuffer` before `appendSampleBuffer(_:)` —
standard pattern using `CMAudioFormatDescriptionCreate` +
`CMSampleBufferCreate`.

**Fragment interval rationale.** Apple's documentation directly
addresses the trade-off and recommends a short initial fragment when
early crash recovery matters.
Quoting
[`AVAssetWriter.initialMovieFragmentInterval`](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval)
(available since macOS 14.0; we require 14.2+):

> When using fragment writing, you can set this property value to
> indicate the interval at which to write the initial fragment.
> The default value is invalid, which indicates to use the interval
> set in the `movieFragmentInterval` property. The
> `movieFragmentInterval` property is typically set to 10 seconds,
> so if an error occurs before writing the first fragment, the
> movie file won't be playable. To avoid this case, your app may
> want to set a shorter interval, such as 1 second, to write the
> initial fragment, and then use a 10 second interval for
> subsequent fragments.

The original ADR draft adopted Apple's example pair:
**1 s initial** + **10 s steady-state**. The kill-9 verifier for this
work showed that pair only recovers the first ~1 second when the
process dies around the 5-second mark. That is technically consistent
with a 10-second steady-state interval, but it misses the product
intent: protect the recording itself. The implementation therefore
uses **1 s initial** + **1 s steady-state**.

- **Worst-case loss:** ≤ 1 s after the first fragment lands.
- **Disk overhead:** negligible. AAC at 64 kbps = 8 KB/s. A 1-hour
  recording at 1 s intervals = 3,600 fragments × ~16 bytes of `moof`
  header = ~58 KB per source, which is still imperceptible next to
  the audio payload.

### 2. Session lock file + recovery scan on launch

`MeetingRecordingService.startRecording` writes a JSON marker to
the session folder before any audio is captured:

```
~/Library/Application Support/MacParakeet/meeting-recordings/<uuid>/recording.lock
{
  "sessionId": "<uuid>",
  "startedAt": "<ISO8601>",
  "schemaVersion": 1,
  "pid": 62326,
  "displayName": "Meeting Apr 24, 2026 at 8:34 PM",
  "state": "recording"
}
```

On `stopRecording()` (success path), the marker is rewritten to
`state: "awaitingTranscription"` after the writers have been
finalized, `meeting-recording-metadata.json` is on disk, and `meeting.m4a` has been
mixed. The marker is **atomically deleted** only after the post-stop
`Transcription` row has been completed. The stopped-session path first saves a
processing Library row, then queues final transcription; the lock stays in
place while that row is awaiting transcription. This keeps the audio
recoverable if the app crashes in the clean-stop window between mixing and
transcription completion. On capture or mix failure, the marker stays in place
and the session is treated as recoverable.
`cancelRecording()` deletes the marker and the session folder because
user-initiated cancel is not a crash.

On `AppDelegate.applicationDidFinishLaunching`, a recovery scanner
walks `meeting-recordings/` looking for any folder that contains
`recording.lock`. For each, it offers the user a **single**
"recover partial recording" prompt at most (multiple recoverable
sessions are presented as a list). Accepting runs the standard
post-stop pipeline:

1. Truncate-repair the fragmented selected-source audio files
   (`microphone.m4a`, `system.m4a`, or both depending on source mode; no-op
   for fragmented MP4 — they're already valid up to the last fragment; just
   verify with `AVAsset.tracks` loadability).
2. Synthesize `meeting-recording-metadata.json` from the audio file durations
   (`startOffsetMs = 0` for both since we don't have the original
   alignment; acceptable degradation — user knows recording was recovered).
   Use the speech engine captured in `recording.lock`, defaulting to Parakeet
   for legacy lock files that predate ADR-021.
3. Run `MeetingTranscriptFinalizer.finalize` via `STTScheduler` as a
   normal background job (recovery transcription is just another
   meeting-finalize task per ADR-016's slot model), updating an existing
   incomplete Library row for the mixed audio when one already exists.
4. Persist/update the `Transcription` record with a `recoveredFromCrash:
   true` flag (new column or boolean in metadata).
5. Delete `recording.lock` after successful save.

The marker deletion step is owned by `MeetingRecordingSettlement`, which
re-fetches the saved row and removes the lock only after verifying a completed
meeting `Transcription` for that artifact folder. See the lock deletion
authority rule in
[`spec/contracts/meeting-recovery-retention.md`](../contracts/meeting-recovery-retention.md#lock-deletion-authority).

Declining the prompt **keeps** the lock file and audio — the user
can retry recovery later from a Settings affordance ("Pending
recovery: 1 partial recording").

### 3. Schema version on the lock file

The lock file embeds `schemaVersion: 1` and a small state enum
(`recording` or `awaitingTranscription`) so future format changes
(new fields, different paths) can be migrated without breaking
existing in-flight recordings on a user's machine across an app
update.

The current lock-file, recovery-discovery, active-session refusal, and
retention-sweep safety contract is maintained in
[`spec/contracts/meeting-recovery-retention.md`](../contracts/meeting-recovery-retention.md).
In particular, automatic destructive sweeps treat any file named
`recording.lock` as protective, even when the file is corrupt, zero-byte, or a
future schema.

### 4. Phased rollout

**Phase 1 (smaller, ships first):** Lock file + recovery flow only,
keeping the current `AVAudioFile` writer. The recovery scan finds
crashed sessions; the audio files may not be playable as-is, but
the *UX surface* is in place. Phase 1 attempts repair via
`AVAssetExportSession` first; if that fails, it surfaces a "partial
recording detected, audio not recoverable" notice with the option
to delete or keep the folder for later manual recovery.

**Phase 2 (larger, ships second):** Replace `AVAudioFile` with
`AVAssetWriter` + `movieFragmentInterval` / `initialMovieFragmentInterval`.
Phase 1's recovery flow becomes lossless up to the relevant
1-second fragment boundary without further UX changes. The migration is contained to
`MeetingAudioStorageWriter` — its public surface (the
`write(_:source:)` and `finalize()` methods) is preserved so
callers don't change.

Both phases are part of this ADR. The split is purely about
implementation order, not architectural intent.

## Alternatives considered

**WAV / CAF with header pre-allocation.** Would survive crashes
because PCM containers can be repaired by inspecting file length.
Rejected: a 1-hour mono float32 PCM stream at 48 kHz is ~691 MB per
source = ~1.4 GB per meeting. Too much disk for a free local app
where users may record many meetings.

**Periodic finalize-and-rotate (chunked AVAudioFile).** Every N
minutes, finalize the current `microphone.m4a` and start a new one
(`microphone-002.m4a`, etc.). Rejected: many small files per
session, complex re-merge logic on stop, race conditions on the
rotation boundary, and `AVAudioFile.deinit` is the only flush
mechanism — rotation is itself a synchronization headache.

**Status quo + external repair tools (`untrunc`, `ffmpeg`-based
recovery).** Rejected: external dependency, not always recoverable,
bad UX (user has to run a CLI tool on their crashed file).

**Save uncompressed PCM intermediate, encode to AAC on stop.** Same
disk-usage problem as the WAV alternative, plus added stop-time
latency for the encode pass (potentially minutes for a long meeting).

## Consequences

### Worst-case data loss

≤ 1 s after the first fragment lands. Hard crash, kernel panic, and
power loss all leave a playable file with everything up to the last
fragment boundary the OS flushed.

### Disk overhead

Negligible. AAC at 64 kbps = 8 KB per second. Fragmented MP4 adds
~16 bytes of `moof` header per fragment. A 1-hour meeting at 1 s
intervals = 3,600 fragments × ~16 bytes ≈ 58 KB per source, ~116 KB
total. Imperceptible.

### CPU overhead

`AVAssetWriter` is the framework Apple uses for QuickTime Player,
ScreenCaptureKit recording, and `AVCaptureMovieFileOutput`. Its
encode path is at least as efficient as `AVAudioFile`'s, and the
fragment-flush cost (header write + fsync hint) is well within the
audio-buffer arrival cadence (every ~10 ms).

### UX surface

A new "Recover partial recording?" prompt on launch when crashed
sessions exist. Wording should make clear the recording was
interrupted and the recovery is best-effort — set expectations
correctly. Recovered transcripts are flagged in the library so the
user can tell the difference at a glance.

### Test surface

- Unit: `MeetingRecordingLockFileStore` — write, read, delete,
  schema-version handling.
- Integration: kill -9 mid-recording test (run a recording in a
  child process, kill it after 5 s, assert the resulting
  `microphone.m4a` is loadable as `AVAsset` and contains at least
  4 s of audio).
- Integration: launch-time recovery scan finds N crashed sessions,
  recovers them via the standard pipeline, deletes lock files.

### Migration

In-flight recordings during a Phase 1 → Phase 2 update are not a
concern — the user must stop a recording before quitting the app
to apply an update, and Sparkle's auto-update doesn't kill running
recordings. The lock-file format (schema v1) is forward-compatible
with both phases.

### Privacy

Lock files contain only session UUID, start time, process ID, and
display name — no audio, no transcript, no user-identifying content.
They're stored in the same
`~/Library/Application Support/MacParakeet/meeting-recordings/` tree
as the audio they pertain to.

## References

- [AVAssetWriter — Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter)
- [AVAssetWriter.movieFragmentInterval — Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval)
- [AVAssetWriter.initialMovieFragmentInterval — Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval)
- ADR-014 (meeting recording via ScreenCaptureKit system audio) — defines the audio capture stack this ADR extends
- ADR-016 (centralized STT runtime + scheduler) — recovery transcription enqueues as a normal `meetingFinalize` job
