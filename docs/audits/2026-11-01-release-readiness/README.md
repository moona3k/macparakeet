# Release readiness review — 2026-11-01

## Candidate and scope

- Published app baseline: `v0.8.10`, verified against GitHub releases and the live Sparkle appcast (build `20261014033417`).
- Source baseline: `bb1ebcc37974bfb363f2bec46250bc0532009f17`, current `origin/main` at review start; 56 commits since the release.
- Working branch: `review/release-readiness-2026-11-01`, isolated in `macparakeet-release-review-20261101` to preserve unfinished work in the primary checkout.
- Proposed app candidate: 0.8.11. 0.9.0 remains reserved for qualified public Voice Control. Source CLI is promoted to 5.2.0 because the new activity-reminder trigger is an additive public contract change.
- Scope: review changes since the shipped release, fix confirmed regressions, verify the candidate and prepare release notes. No publication, deployment, production data changes or merge is part of this review.

## Invariants

Keep existing audio/transcripts and unrelated work intact. Preserve opt-in defaults, local processing, experimental release gates, shared capture ownership, cancellation and recovery, CLI schemas and exit codes. Fix concrete defects without expanding feature scope. One owner runs the full Swift suite at most once after fixes; iterations use focused tests.

## Review coverage

Independent review lanes cover capture/finalization/recovery/AEC; keyboard/dictation/sounds/vocabulary/Settings; meeting reminders/browser collection/video/LLM/CLI history. The primary review covers integration, packaging, public metadata, evidence and final verification. Findings and final results will be recorded below.

## Findings and changes

1. **CLI release identity:** source still advertised the already published 5.1.0 despite new behavior under Unreleased. Promoted the changelog and executable version to 5.2.0; published stable/standalone metadata remains 5.1.0.
2. **Meeting retry with unreadable locks:** source-only meetings could not reach the existing recovery lease fallback when their lock was empty or corrupt. Capture reconstruction now uses the same read-only candidate interpretation as lease admission; missing locks and live future-schema owners remain refused. See [capture review](capture-review.md).
3. **Audio after cancelling video:** navigating with Show Video open, then hiding a pending video, could leave the retained audio unloaded. Cancellation restores that audio if no player exists, including legacy conversion. Cancellation is checked again after conversion persistence to prevent an old operation replacing a newer selection. See [services review](services-review.md).
4. **Historical CLI notes:** the 300-second request timeout and segmented long-transcript cleanup were already in both `v0.8.10` and `cli-v5.1.0`, but their notes remained under Unreleased. Moved those entries to 5.1.0 rather than presenting them as new 5.2.0 behavior.
5. **Stale playback duration:** an existing adjacent race could publish a previous player's asynchronously loaded duration after navigation. The metadata commit now checks player identity. A deterministic result-application test covers current, stale, invalid and cleaned-up owners; it does not claim to reproduce AVFoundation timing.

The [interaction review](interaction-review.md) found no further confirmed issue in keyboard handling, dictation controls/sounds, vocabulary and Settings. Sound asset hashes and PCM metadata match the original-asset manifest. [Draft release notes](../../releases/0.8.11/README.md) are prepared locally.

## Acceptance boundaries

Automated proof does not establish the following native/physical/distribution behavior. Keep these as explicit acceptance gates for the exact release artifact:

- Dictation in a real target app: hold-to-talk, hands-free, second shortcut, repeated paste, physical typing interruption and remote desktop; imported cues and device routing.
- Back-to-back meetings: stop one and start another during finalization; microphone/system audio on built-in, Bluetooth and changed routes; verify both retained recordings and retry after restart.
- Meeting reminders: opt-in/off behavior, supported native/browser calls, dismissed prompts and explicit Record action; no unexpected recording.
- Library video: navigation during extraction, Show/Hide while downloading, retained audio, offline behavior and signed yt-dlp/FFmpeg helpers.
- Real model transcription on representative speech and supported hardware, including long recordings and limited-memory machines.
- Exact Developer ID app/DMG, required echo assets, notarization Accepted, Gatekeeper, installation and Sparkle upgrade from 0.8.10; no publication before artifact identity is verified.

## Verification

In progress. Existing baseline CI run `41323390324` succeeded for `bb1ebcc37974bfb363f2bec46250bc0532009f17`; this is not evidence for later changes or physical capture/distribution qualification.

- Original implementations reproduced failed source-only meeting retry and unavailable retained audio after video cancellation (`regression-red.log`). The separate active-lock fixture initially compared a timestamp across JSON serialization; it now checks unchanged on-disk bytes, the actual preservation contract.
- Focused Swift suite: **165 passed**, zero failures, covering capture/locks, queue/coordinator/detail retry, media/video and CLI version (`focused-tests.log`).
- CI helper tests: **46 passed**. Distribution policy fixtures passed for version, privacy, Mach-O minimum OS, echo asset preparation and echo verification.
- Ask helper: **14 passed** using the packaged helper path. An initial harness invocation omitted that path and could not locate its notices; using the CI environment fixed the invocation without source changes.
- CLI persistence smoke passed across independent processes. Subsystem README references passed. All 104 Swift telemetry events are accepted by the sibling website checkout's 110-entry allowlist; this is a source compatibility check, not a live ingestion test.
- Changed-file Swift lint exited zero with existing style warnings; `git diff --check` passed. Local Greptile cannot run because the installed CLI is not signed in. Independent code reviews completed; no further blocking findings in the fixed paths.
- The initial cold build was interrupted by concurrent edits to a compilation input; the subsequent focused test command rebuilt successfully. No full suite has run yet.
- Local health safely reports schema skew for this machine's existing library (`v0.10.1-quick-prompts-pin` is newer than this release branch understands). It was not modified. Persistence and transcription qualification use disposable databases; this personal development-library state must not be mistaken for a failed 0.8.10 upgrade test.

Raw local logs are retained in `evidence/`. Final receipts should identify exact candidate commits and distinguish automated, native, physical and distribution checks.
