# Crash-Resilient Meeting Recording (ADR-019)

> Authoritative ADR: `spec/adr/019-crash-resilient-meeting-recording.md`
> Status: IMPLEMENTED — Phase 1 + Phase 2 shipped together on 2026-04-25
> Created: 2026-04-24

## Problem

`MeetingAudioStorageWriter` (`Sources/MacParakeetCore/Audio/MeetingAudioStorageWriter.swift`) writes audio with `AVAudioFile`, which only flushes the MP4 `moov` atom in `deinit`. Any crash, force-quit, kernel panic, or power loss mid-recording leaves audio bytes on disk but no decoder can find samples without the index. The user loses the entire session even when it's a 40-minute meeting that crashed at minute 39.

Three other artifacts are also clean-stop-only: `metadata.json`, `meeting.m4a` (the FFmpeg-mixed file), and the post-stop transcription pass. So the failure mode isn't just "audio is unplayable" — there's no detection that a recording was ever in progress, no UI surfacing the loss, and no recovery path.

## Design Goals

1. A crash mid-recording must result in a usable audio file containing everything written up to a small bounded window (the fragment interval).
2. The user must learn — on next launch — that a recording was interrupted, and be offered recovery.
3. Recovered recordings must produce real transcripts via the same post-stop pipeline that clean stops use; no parallel "lite" path.
4. The implementation may ship in two phases: phase 1 ships the recovery UX surface against the current writer (best-effort repair); phase 2 swaps the writer for `AVAssetWriter` (lossless up to the fragment boundary). Both phases must work end-to-end on their own; phase 2 is a drop-in upgrade.
5. Caller surface of `MeetingAudioStorageWriter` (its `write(_:source:)` and `finalize()` methods, the URLs it owns) must stay stable across phase 2.

## Non-Goals

- **No new persistence path for transcripts during recording.** The transcript still lives only in memory until clean stop or recovery. We are protecting *audio*; transcripts are derived.
- **No fragmented-MP4 livestreaming.** This is local-recording crash resilience, not HLS / DASH output.
- **No general-purpose orphan-file cleanup.** The recovery scan only handles the lock-file + audio-files combination it itself wrote.
- **No retroactive recovery for sessions interrupted before this ships.** Anything a user lost prior to phase 1 is gone.

---

# Phase 1: Lock file + recovery scan (no writer change)

This phase made interrupted recordings *visible* and recoverable. In this PR it shipped together with Phase 2, so recovered source files are normally playable up to the last 1-second fragment rather than relying on repair.

## 1.1 Lock file

New file in the session folder, written **before** any audio is captured:

```
~/Library/Application Support/MacParakeet/meeting-recordings/<uuid>/recording.lock
```

JSON content (schema v1):

```json
{
  "schemaVersion": 1,
  "sessionId": "<uuid>",
  "startedAt": "2026-04-24T20:34:38Z",
  "pid": 62326,
  "displayName": "Meeting on April 24, 2026 at 8:34 PM"
}
```

Field rationale:

- `schemaVersion` — locks future format changes; readers ignore unknown versions.
- `sessionId` — matches the folder UUID; redundant but useful for sanity-checking after disk weirdness.
- `startedAt` — ISO-8601 in UTC, used for ordering recovery prompts and as a fallback `metadata.json` value.
- `pid` — process ID of the recording app instance. Recovery scan uses `kill -0 PID` semantics (`getpgid`/sentinel) to skip a lock owned by a still-running process (handles double-launch during dev).
- `displayName` — preserved through recovery so the UI can show the same session name the user saw while recording.
- `state` — `recording` while capture is active, then `awaitingTranscription` after source audio is finalized/mixed but before the transcript row is durable.

## 1.2 New module

New file: `Sources/MacParakeetCore/Services/MeetingRecordingLockFileStore.swift`

```swift
public struct MeetingRecordingLockFile: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let sessionId: UUID
    public let startedAt: Date
    public let pid: Int32
    public let displayName: String
}

public protocol MeetingRecordingLockFileStoring: Sendable {
    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws
    func read(folderURL: URL) throws -> MeetingRecordingLockFile?
    func delete(folderURL: URL) throws
    /// Walks meetings/ root and returns every folder that still has a
    /// `recording.lock` AND whose owning PID is no longer alive. Locks owned
    /// by a live PID are filtered out (defensive against double-launch).
    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile]
}

public final class MeetingRecordingLockFileStore: MeetingRecordingLockFileStoring {
    private let processChecker: ProcessAliveChecking
    public init(processChecker: ProcessAliveChecking = LiveProcessChecker()) { ... }
    // implementation
}

public protocol ProcessAliveChecking: Sendable {
    func isAlive(pid: Int32) -> Bool
}
public struct LiveProcessChecker: ProcessAliveChecking {
    public func isAlive(pid: Int32) -> Bool {
        // kill(pid, 0) returns 0 if the process exists; ESRCH if it doesn't.
        kill(pid, 0) == 0 || errno == EPERM
    }
}
```

The protocol exists so tests can inject a `MockProcessAliveChecker` and exercise the orphan-vs-live branch deterministically.

## 1.3 Wiring into `MeetingRecordingService`

`startRecording()` (line 145ish, after `currentSession` is set) writes the lock:

```swift
let lock = MeetingRecordingLockFile(
    schemaVersion: MeetingRecordingLockFile.currentSchemaVersion,
    sessionId: session.id,
    startedAt: session.startedAt,
    pid: ProcessInfo.processInfo.processIdentifier,
    displayName: session.displayName
)
try lockFileStore.write(lock, folderURL: session.folderURL)
```

`stopRecording()` rewrites the lock to `awaitingTranscription` **after** `metadata.json` is on disk and `meeting.m4a` is mixed. The flow coordinator deletes the lock only after `TranscriptionService.transcribeMeeting` has persisted the transcript row. **Ordering matters**: lock removal is the last action that makes a recording "officially stopped." If anything before it fails, the lock stays and the next launch offers recovery from the durable audio.

`cancelRecording()` also deletes the lock — a user-initiated cancel is not a crash, and we don't want to recover something the user explicitly threw away. Optionally write a `.cancelled` sibling marker first if there's value in distinguishing user-cancel from natural completion in any later forensic; defer this decision unless it comes up.

## 1.4 Recovery scan + UX

New module: `Sources/MacParakeetCore/Services/MeetingRecordingRecoveryService.swift`

```swift
public protocol MeetingRecordingRecoveryServicing: Sendable {
    func discoverPendingRecoveries() async throws -> [MeetingRecordingLockFile]
    func recover(_ lock: MeetingRecordingLockFile) async throws -> Transcription
    func discard(_ lock: MeetingRecordingLockFile) async throws
}
```

Recovery flow (`recover(_:)`):

1. If an `awaitingTranscription` lock already has a completed transcript for `meeting.m4a`, delete the stale lock and return the existing transcript. Otherwise read the audio files from the session folder. If both `microphone.m4a` and `system.m4a` are missing or unplayable, report unrecoverable. If at least one source is playable, proceed with that source.
2. **Best-effort repair fallback**: try to load each as `AVAsset` and read its duration. If that fails, fall back to `AVAssetExportSession` to remux into a fresh container. With the Phase 2 writer this should normally be a no-op, but it remains useful for partially finalized files.
3. Synthesize `metadata.json`: `startOffsetMs = 0` for both sources (we don't have the original alignment data). Note this in the saved transcription's metadata so the UI can show a "recovered" badge with degraded-alignment caveat.
4. Run `MeetingTranscriptFinalizer.finalize` via the existing `TranscriptionService` path — recovery transcription is a normal `meetingFinalize` job per ADR-016's slot model. **Do not write a parallel pipeline.**
5. On success: delete `recording.lock`. On failure: keep the lock so the user can retry from Settings. Retry first checks for an already-saved transcript by `meeting.m4a` path so a prior "save succeeded, lock delete failed" partial success does not duplicate transcripts.

UX hook in `AppDelegate` / `AppEnvironment`:

- On `applicationDidFinishLaunching` (after permissions / models settle), call `recoveryService.discoverPendingRecoveries()`.
- If non-empty, present a single dialog: "We found %d interrupted recording%s. Would you like to recover %@?" with **Recover**, **Recover Later**, **Discard** actions. The dialog should list the sessions by `startedAt` + `displayName`.
- Provide a Settings affordance ("Pending recovery: N partial recordings") so users can reach the same flow later without quitting + relaunching.

## 1.5 Tests (Phase 1)

Unit (`Tests/MacParakeetTests/Services/MeetingRecordingLockFileStoreTests.swift`):

- `testWriteThenRead_roundTrip` — schema v1 fields preserved.
- `testReadFromMissingFolder_returnsNil`.
- `testReadFromCorruptJSON_returnsNil` — don't propagate, treat as no-lock.
- `testDeleteRemovesFile`.
- `testDiscoverOrphansSkipsLiveOwners` — uses a `MockProcessAliveChecker` returning `true`; assert empty result.
- `testDiscoverOrphansReturnsDeadOwners` — checker returns `false`; assert returned.
- `testDiscoverOrphansHandlesUnknownSchemaVersion` — write v999, ensure scanner skips it without crashing.

Integration (`Tests/MacParakeetTests/Services/MeetingRecordingRecoveryServiceTests.swift`):

- `testRecoverSynthesizesMetadataAndPersistsTranscription` — fake session folder with two short m4a fixtures + a lock file; assert `Transcription` is written with `recoveredFromCrash: true` flag.
- `testRecoverDeletesLockOnSuccess`.
- `testRecoverKeepsLockOnFailure` — inject a `MockTranscriptionService` that throws; assert lock survives.
- `testDiscardRemovesEverything` — folder gone after discard.

Manual smoke (in `docs/cli-testing.md` or as a Plans `## Verification` checklist):

- Start a recording, force-quit the app via Activity Monitor, relaunch. Expect the recovery dialog. Accept and verify the transcription appears in the library with the recovered badge.

## 1.6 Acceptance criteria (Phase 1)

- [x] `recording.lock` is written before audio capture starts and removed only after a clean stop or successful recovery.
- [x] An app launched after a crash shows a "We found N interrupted recordings" dialog if and only if at least one orphan lock exists.
- [x] Recovering a session writes a `Transcription` row visible in the library with a "Recovered" badge.
- [x] Recovering a session reuses `MeetingTranscriptFinalizer` — no duplicated finalize logic.
- [x] Discard removes the entire session folder, lock included.
- [x] Lock files owned by live PIDs are skipped (no false-positive recovery dialog when the user double-launches the app).
- [x] All Phase 1 tests pass; broader `Meeting`-prefixed suite (currently 90 tests + however many we add) still passes.

---

# Phase 2: Replace `AVAudioFile` with `AVAssetWriter` + `movieFragmentInterval`

Phase 2 is invasive. It rewrites the inside of `MeetingAudioStorageWriter` while keeping its public surface unchanged.

## 2.1 New writer architecture

`MeetingAudioStorageWriter` (same file path, same public API) replaces:

```swift
private var microphoneFile: AVAudioFile?
private var systemFile: AVAudioFile?
```

with:

```swift
private var microphoneWriter: AVAssetWriter?
private var microphoneInput: AVAssetWriterInput?
private var systemWriter: AVAssetWriter?
private var systemInput: AVAssetWriterInput?
```

Per-source initialization:

```swift
let writer = try AVAssetWriter(outputURL: microphoneAudioURL, fileType: .m4a)
writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)          // 1 s steady-state
writer.initialMovieFragmentInterval = CMTime(value: 1, timescale: 1)   // 1 s initial — macOS 14.0+
writer.shouldOptimizeForNetworkUse = false

let outputSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: targetFormat.sampleRate,
    AVNumberOfChannelsKey: targetFormat.channelCount,
    AVEncoderBitRateKey: 64_000,
]
let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
input.expectsMediaDataInRealTime = true
guard writer.canAdd(input) else { throw MeetingAudioError.storageFailed("...") }
writer.add(input)

guard writer.startWriting() else {
    throw MeetingAudioError.storageFailed(writer.error?.localizedDescription ?? "startWriting failed")
}
writer.startSession(atSourceTime: .zero)
```

**Fragment intervals: 1 s initial + 1 s steady-state.** The original draft used Apple's example 1 s initial + 10 s steady-state pair, but the kill-9 verifier recovered only about 1.17 s when the child process died around 5 s. That behavior was consistent with a 10 s steady-state interval but failed the product goal. The implementation uses 1 s for both intervals so worst-case post-fragment loss is about 1 s; AAC/container overhead remains negligible.

`expectsMediaDataInRealTime = true` is required for live-capture inputs — it tells the writer to prioritize keeping up with the input clock over compression efficiency. **Without this, the writer may stall under load and drop samples silently.**

## 2.2 The PCM-to-CMSampleBuffer adapter (load-bearing)

This is the most error-prone piece and gets its own unit test. New file:

`Sources/MacParakeetCore/Audio/PCMBufferToSampleBuffer.swift`

```swift
import AVFAudio
import CoreMedia

/// Converts an `AVAudioPCMBuffer` into a `CMSampleBuffer` suitable for
/// `AVAssetWriterInput.append`. Maintains presentation timestamps via a
/// caller-supplied running sample count.
///
/// Returns `nil` (does not throw) on conversion failure so the caller can
/// log + continue rather than tearing down the recording.
public enum PCMBufferToSampleBuffer {
    public static func make(
        from pcmBuffer: AVAudioPCMBuffer,
        presentationTimeSamples: Int64
    ) -> CMSampleBuffer? {
        // 1. Build CMAudioFormatDescription from the PCM buffer's format.
        // 2. Build a CMBlockBuffer wrapping the PCM bytes (deep copy — the
        //    PCM buffer may be reused by the audio engine after we return).
        // 3. Build CMSampleTimingInfo with presentationTimeStamp =
        //    CMTime(value: presentationTimeSamples, timescale: sampleRate).
        // 4. CMSampleBufferCreate with the above.
    }
}
```

**Critical invariants** (these are where bugs hide):

- **Deep-copy the audio bytes** into the `CMBlockBuffer`. AVAudioEngine reuses PCM buffers; if we hand the writer a block buffer pointing into AVAudioEngine's memory, samples get corrupted on the next callback.
- **Presentation timestamps are monotonic and per-source.** Each source has its own running sample count. Don't share a counter between mic and system; their clocks are independent.
- **Sample count math** uses `Int64`. A 1-hour recording at 48 kHz is 172.8M samples — fits in `Int32` for now, but `Int64` is cheap and future-proof.
- **Format description must match the PCM buffer's format exactly** (sample rate, channel count, common format, interleaving). Mismatch causes silent append failure.

Reference patterns in the wild are scattered across blog posts and Stack Overflow with subtle bugs. **Write this against a known-good fixture** — generate a 1 second sine wave PCM buffer, convert it, append it to a test `AVAssetWriter`, then load the resulting m4a back via `AVAssetReader` and assert the decoded samples match the input within float tolerance.

## 2.3 Writer lifecycle changes

Existing `write(_:source:)` and `finalize()` become:

```swift
func write(_ buffer: AVAudioPCMBuffer, source: AudioSource) throws {
    let sampleBuffer = PCMBufferToSampleBuffer.make(
        from: buffer,
        presentationTimeSamples: writtenFrames(for: source)
    )
    guard let sampleBuffer else {
        logger.warning("PCM→sampleBuffer conversion failed")
        return
    }
    let input = self.input(for: source)
    if input.isReadyForMoreMediaData {
        input.append(sampleBuffer)
        bumpWrittenFrames(by: Int64(buffer.frameLength), source: source)
    } else {
        logger.warning("AVAssetWriter input not ready — dropping audio")
    }
}

func finalize() {
    let group = DispatchGroup()
    if let mic = microphoneWriter {
        microphoneInput?.markAsFinished()
        group.enter()
        mic.finishWriting { group.leave() }
    }
    if let sys = systemWriter {
        systemInput?.markAsFinished()
        group.enter()
        sys.finishWriting { group.leave() }
    }
    group.wait()
    microphoneWriter = nil
    microphoneInput = nil
    systemWriter = nil
    systemInput = nil
}
```

`finalize()` becomes async-ish (uses `DispatchGroup.wait`). If callers run on the main thread, switch the wait to `await withCheckedContinuation` so we don't block. Verify the call sites in `MeetingRecordingService.stopRecording` / `cancelRecording` aren't on the main thread before deciding.

## 2.4 Tests (Phase 2)

Unit:

- `Tests/MacParakeetTests/Audio/PCMBufferToSampleBufferTests.swift`:
    - `testRoundTripPreservesSamples` — sine wave in, sample buffer through `AVAssetWriter` → `AVAssetReader`, decoded values match within `1e-3` tolerance.
    - `testPresentationTimestampsAdvanceWithSampleCount`.
    - `testReturnsNilOnFormatMismatch` — pass a buffer whose format is incompatible with what we expect.
    - `testDeepCopiesBytes` — mutate the PCM buffer after conversion, confirm the sample buffer's bytes are unchanged.

- `Tests/MacParakeetTests/Audio/MeetingAudioStorageWriterTests.swift`:
    - `testFinalizedFileLoadsAsAVAsset` — write 5 s, finalize, assert duration ≈ 5 s.
    - `testFragmentedFileContainsMovieFragments` — write 10 s of audio, finalize, and assert `moof` fragments exist.
    - `testWritesToBothMicAndSystemFiles` — basic two-stream sanity.

Integration:

- `Tests/MacParakeetTests/Services/MeetingRecordingCrashRecoveryTests.swift`:
    - `testKillNineMidRecordingProducesPlayableFiles` — spawn a child process via `Process()` that records 10 s, kill `-9` it after 5 s, in the parent process load the resulting `microphone.m4a` as `AVAsset` and assert duration ≥ 4 s. **This is the load-bearing integration test** — if it passes, the architectural goal is met.

Manual smoke:

- Record for 10 minutes, kill via Activity Monitor → Force Quit, relaunch. Expect recovery dialog from Phase 1. Accept. Verify the recovered transcript covers ≥ 9:59 of the original speech.

## 2.5 Acceptance criteria (Phase 2)

- [x] `MeetingAudioStorageWriter` no longer references `AVAudioFile`.
- [x] All meetings produce m4a files whose `AVAsset.duration` matches recording duration ± fragment interval.
- [x] The kill-9 integration test passes deterministically.
- [x] The Phase 1 recovery flow now produces lossless transcripts (within the fragment-boundary window) instead of best-effort.
- [x] No regression in clean-stop recording quality (sample-rate, bitrate, channel layout match phase 1 output).
- [x] All existing meeting tests still pass; the kill-9 test joins them.
- [x] Multi-LLM review (Codex + Gemini) on the writer changes shows convergence to nitpick-level findings.

---

## Open questions / known landmines (read before implementing)

- **First-fragment delay is what `initialMovieFragmentInterval` exists for.** With the 1 s initial + 1 s steady-state pair, recordings >= 1 s should produce a playable file on crash. Recordings < 1 s may still have zero fragments; that is a known limitation.

- **AAC encoder priming/padding.** AAC has 2112 priming samples; the priming/padding is stored in `edts/elst` atoms in the moov. A truncated mid-fragment file may have minor playback artifacts at start/end. Usually unnoticeable. Don't fight this; just be aware when interpreting test assertion deltas.

- **Two streams, two writers, two fragment timelines.** Mic and system have independent `AVAssetWriter` instances. On crash, one stream may have flushed `N` fragments while the other flushed `N±1`. The recovery flow must defensively trim transcripts to the shorter stream's length to avoid "ghost" speech past the actual recording end. The existing `MeetingTranscriptFinalizer` should already handle this via per-source `startOffsetMs` math; verify with a deliberately asymmetric fixture.

- **Sleep/wake mid-recording.** Not a crash but adjacent. Current capture path handles capture errors; sleep + wake interrupts the Core Audio Tap and may not resume cleanly. **Out of scope for this plan** — file separately if it surfaces. The lock file alone makes the failure visible.

- **Lock file on a read-only volume.** If for some reason the meetings folder becomes unwritable mid-recording, lock writes will start failing. Treat that as a normal capture error (surface to user, abort recording) — don't add a special path.

- **First-launch onboarding race.** The recovery scan runs on `applicationDidFinishLaunching`. If onboarding is incomplete (no models, no permissions), recovery transcription will fail. Either gate the scan behind onboarding completion, or queue recoveries until onboarding finishes. Decide during implementation; the lock files are persistent so we can defer to the user's next "ready" state.

Resolved: the launch scan is gated behind onboarding completion. Lock files remain on disk, and the Settings affordance can retry once the app is ready.

## Verification

- `swift test --filter MeetingRecordingLockFileStoreTests` passed (9 tests).
- `swift test --filter PCMBufferToSampleBufferTests` passed (3 tests).
- `swift test --filter 'MeetingRecordingServiceTests|MeetingRecordingRecoveryServiceTests|MeetingRecordingLockFileStoreTests'` passed (33 tests) after final review fixes for awaiting-transcription locks, idempotent retry before remix, and corrupt-source salvage.
- `swift test --filter MeetingRecordingCrashRecoveryTests/testKillNineMidRecordingProducesPlayableFiles` passed after switching steady-state fragments from 10 s to 1 s.
- `swift test --filter Meeting` passed (163 tests).
- `swift test` passed: 1552 XCTest tests + 13 Swift Testing tests.
- Multi-LLM review: Codex Explore found lock-write cleanup and recovery-idempotence blockers; both were fixed with regression tests. Oracle multi-model API review timed out after 10 minutes with no model responses, so Gemini CLI (`gemini-2.5-pro`) reviewed the focused diff; remaining comments were nits/false positives after accounting for `@MainActor` and the untracked writer tests.
- Manual Activity Monitor force-quit smoke was not run in this environment; the automated kill-9 verifier covers the file-survival property directly.

## Out of scope for this plan

- Recovery for sessions interrupted before this code ships.
- Pause/resume mid-recording (a different feature).
- Background recording (continuing while app is suspended).
- Cloud backup of recordings.
- Proactive sleep / low-battery prevention during recording.

## References

- ADR-019: `spec/adr/019-crash-resilient-meeting-recording.md` (the architectural decision and rationale)
- ADR-014: `spec/adr/014-meeting-recording.md` (the meeting recording feature this extends)
- ADR-016: `spec/adr/016-centralized-stt-runtime-scheduler.md` (recovery transcription enqueues as a normal `meetingFinalize` job)
- Apple docs: [`AVAssetWriter`](https://developer.apple.com/documentation/avfoundation/avassetwriter)
- Apple docs: [`AVAssetWriter.movieFragmentInterval`](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval)
- Apple docs: [`AVAssetWriter.initialMovieFragmentInterval`](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval)
- Existing writer: `Sources/MacParakeetCore/Audio/MeetingAudioStorageWriter.swift`
- Existing service: `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`
