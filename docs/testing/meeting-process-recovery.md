# Meeting recovery across processes

`MeetingRecordingCrashRecoveryTests.testKilledRecordingRecoversInFreshProcessAndRemainsIdempotent`
exercises the local writer-to-recovery boundary without speech models or capture devices.
It is opt-in because it launches XCTest subprocesses, runs AVFoundation codecs, and
intentionally kills its own active writer.

Run from the worktree that owns the code, on an Apple Silicon Mac with Xcode selected:

```sh
MACPARAKEET_CRASH_RECOVERY_TESTS=1 swift test --jobs 4 \
  --filter MeetingRecordingCrashRecoveryTests/testKilledRecordingRecoversInFreshProcessAndRemainsIdempotent
```

After that build, repeat the same journey without recompiling:

```sh
MACPARAKEET_CRASH_RECOVERY_TESTS=1 swift test --skip-build \
  --filter MeetingRecordingCrashRecoveryTests/testKilledRecordingRecoversInFreshProcessAndRemainsIdempotent
```

The writer child runs the production `MeetingRecordingService` with synthetic
microphone events. That service creates the session folder, actual fragmented AAC
source, PID-owned `recording.lock`, captured engine route, and saved notes. Live
transcription is disabled. The parent first checks that live-owner discovery does
not offer the session, then sends SIGKILL after six seconds of generated audio.
There is no clean Stop or writer finalization before the kill.

A fresh child opens the disposable database through production GRDB migrations
and runs `MeetingRecordingRecoveryService`, real audio conversion/playback building,
`TranscriptionService`, repository writes, artifact materialization, and lock
settlement. Only capture input and speech recognition are deterministic substitutes;
the STT substitute verifies it receives a real readable audio file. Recovery
synthesizes alignment metadata from retained media, as expected after a mid-recording
crash before Stop first saves metadata. No row is fabricated by the fixture.

The parent reopens the database and verifies one completed recovered row, retained
notes and transcript, durable folder/playback paths, manifest identity, recovered-state parity, and file
paths, actual Markdown/notes content, decodable playback, and deletion of the
recording lock. A third process checks discovery is empty and explicitly retries
the original lock descriptor: ownership must reject it with `missingLock`, preserving
the same row with zero new STT calls.
The parent verifies the artifacts and row again.

`MeetingRecordingRecoveryServiceTests.testArtifactRefreshFailureRetainsLockAndRetryPreservesPromptResultsWithoutSTT`
obstructs the manifest output path to force real file I/O failure. It verifies the
completed row and recovery lock survive, then removes the obstruction and retries.
The retry must retain saved prompt results, refresh recovered-state metadata, and
settle the lock without another mix or STT call.

Every child receives an explicit temporary state root and telemetry-off environment;
the recovery child also configures no-op telemetry. Preference changes, model
loading, diarization, AI titles, automation hooks, microphone access, and system
audio capture are absent. Logs use files rather than pipes. Writer startup has a
30-second deadline and recovery children have 60-second deadlines. Cleanup kills
and reaps remaining owned children before removing their disposable root.

This covers orderly process death after SIGKILL on the running host. It does not
qualify power loss, disk-full/I/O failure, real speech accuracy, Bluetooth/TCC,
dual-source alignment/AEC, or the native recovery UI. The earlier
`testKillNineMidRecordingProducesPlayableFiles` remains as the lower-level raw
writer check; deterministic recovery service tests still own fault permutations.

## Local verification

On the development Apple Silicon Mac running macOS 26.6.2, three post-fix
process journeys passed in 7.174, 7.077, and 7.578 seconds (excluding build time).
The focused artifact/recovery group passed 67 tests; the additional canonical-notes
precedence test was run separately. These are local results, not hosted CI or
physical capture qualification. Before the fix, the new journey observed
`manifest.meeting.recoveredFromCrash == false` while the database row was `true`;
the parity assertion failed. Recovery now refreshes after saving that metadata.
