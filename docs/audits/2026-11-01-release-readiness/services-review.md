# Services release review

Reviewed `v0.8.10..bb1ebcc37974bfb363f2bec46250bc0532009f17` in the release-review worktree. Deep review: over 1,300 changed production lines in the assigned services, including subprocesses, persistence projections, and capture-start integration.

## Confirmed finding and fix

**P2: Hide Video strands retained audio after navigating with the video panel open.**

1. Show Video is open for transcript A.
2. Navigating to YouTube transcript B invokes `cleanup()` then `load(for:)` directly, bypassing `prepare(for:)`; B has retained audio but no audio player yet.
3. Hide Video cancels B's pending extraction/download.
4. Previously `cancelVideoPreparation()` set `.idle` when `player == nil`, leaving B's retained audio unloaded and the scrubber unusable until the transcript was reopened.

`MediaPlayerViewModel` now retains the pending video's transcription and reuses its existing retained-audio preparation path only when cancellation has no player to preserve. This includes legacy WebM conversion and leaves an already prepared audio/video player intact. Cleanup and a new preparation invalidate the pending fallback. The playback contract documents this behavior.

A related existing async boundary needed protection: cancellation while the conversion's persistence callback is suspended could previously let the old conversion replace a newly selected transcript's player. A cancellation check now follows that callback. The production callback is currently synchronous on MainActor, but the public callback supports suspension; the restored conversion path preserves that boundary.

The same stranded state was reachable when the direct load failed instead of being cancelled: the player stayed empty in `.error`, so Hide Video did nothing. `cancelVideoPreparation()` now also restores retained audio from the failed state, keeps an existing audio player instead of rebuilding it, and returns it to `.ready`. Retry from the error panel is unchanged.

Behavioral regressions were added before/alongside the fix:

- `testHidingDirectVideoLoadRestoresRetainedAudio`: direct video load, cancellation, retained `.m4a` player restoration, and late video result disposal.
- `testHidingDirectVideoLoadPreparesLegacyRetainedAudio`: direct video load cancellation starts the existing WebM conversion/persistence flow and installs its playable output without deleting source data itself.
- `testHidingFailedDirectVideoLoadRestoresRetainedAudio`, `testHidingFailedDirectVideoLoadPreparesLegacyRetainedAudio` and `testHidingFailedVideoLoadKeepsExistingAudioPlayerUsable`: the failed-load counterparts, including legacy conversion and an already-installed audio player.
- `testRestoredLegacyAudioCannotReplaceNewTranscriptAfterPersistenceWait`: navigation during suspended conversion persistence cannot install the old audio afterward.

The pre-fix direct-load test would observe a nil player and `.idle`; its legacy-audio counterpart would time out waiting for persistence. The suspended-persistence test isolates the missing post-persistence cancellation check. Parent owns compilation and focused/full test execution; no build or test pass is claimed by this reviewer. `git diff --check` passed after these edits.

## Reviewed without another confirmed actionable defect

- Meeting reminder coordinator: opt-in startup/shutdown, async snapshot generations, busy dictation/recorder gating, accepted-click revalidation, capture-success attribution, native process replacement, stale prompt tokens, and deferred starts.
- Browser collector and candidate/prompt policy: metadata-only AX traversal, per-process work budgets, strict provider room validation, prejoin veto, muted Meet corroboration, dismissal continuity, and absence/session handling. Fixture-limited language support and conservative same-room suppression are documented limitations, not newly introduced release blockers.
- Video service: combined URL cache, split stream selection, per-track bounds, unique temporary ownership, cancellation/error cleanup, subprocess output limits, and FFmpeg stream-copy arguments. No retained media is deleted by video resource cleanup.
- LLM knowledge-card recovery: bounded retry count, transient configuration-lock retry, provider-specific allowances, response schema validation, cumulative/unknown usage accounting, cancellation and telemetry outcomes, and persistence-side provenance checks.
- CLI history JSON projection: effective correction/speaker projection for list/search/favorites, original database row preservation, and shared schema.

## Verification limits

No live provider requests, actual browser/meeting trial, native UI run, YouTube network extraction, model download, or full build/test run was performed by this reviewer. Real provider availability, browser AX shape, native audio attribution, signed-helper operation, and playback remain separate qualification work. This review used code reasoning; no Jev classification step was used.
