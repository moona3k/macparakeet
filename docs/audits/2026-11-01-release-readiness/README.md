# Release readiness review — 2026-11-01

## Verdict

The reviewed source is ready for final candidate acceptance testing. Confirmed findings are fixed, regression verification is green, and the Release app is built and Developer ID signed locally. **Publication remains on hold pending native/physical acceptance and installation/Sparkle upgrade checks for the final artifact.** The telemetry companion is now deployed; artifact execution updates are recorded in the [current candidate receipt](https://github.com/moona3k/macparakeet-website/blob/3111c3804aebffd1e6177fbcd9d2fae0ad98c8e2/docs/release-0811-candidate.md). This review does not claim zero regressions or resolve every existing issue.

The candidate before the PR feedback follow-up was app **0.8.11**, build **20261101201053**, CLI **5.2.0**, built from `0146098b013e` after the fresh-review fixes. The [updated signed-candidate receipt](evidence/signed-candidate-final.md) identifies its exact bytes and qualification. The initial build `20261101185026` is preserved under `dist/initial-20261101185026/` with [its historical receipt](evidence/signed-candidate.md); it is superseded. The primary checkout and personal library were preserved.

## Candidate and scope

- Published app baseline: `v0.8.10`, verified against GitHub releases and the live Sparkle appcast (build `20261014033417`).
- Source baseline: `bb1ebcc37974bfb363f2bec46250bc0532009f17`, current `origin/main` at review start; 56 commits since the release.
- Working branch: `review/release-readiness-2026-11-01`, isolated in `macparakeet-release-review-20261101` to preserve unfinished work in the primary checkout.
- Proposed app candidate: 0.8.11. 0.9.0 remains reserved for qualified public Voice Control. Source CLI is promoted to 5.2.0 because the new activity-reminder trigger is an additive public contract change.
- Scope: review changes since the shipped release, fix confirmed regressions, verify the candidate and prepare release notes. No publication, deployment, production data changes or merge into remote main is part of this review.

## Invariants

Keep existing audio/transcripts and unrelated work intact. Preserve opt-in defaults, local processing, experimental release gates, shared capture ownership, cancellation and recovery, CLI schemas and exit codes. Fix concrete defects without expanding feature scope. One owner runs the full Swift suite at most once after fixes; iterations use focused tests.

## Review coverage

Independent review lanes cover capture/finalization/recovery/AEC; keyboard/dictation/sounds/vocabulary/Settings; meeting reminders/browser collection/video/LLM/CLI history. The primary review covers integration, packaging, public metadata, evidence and final verification. Findings and final results will be recorded below.

## Findings and changes

1. **CLI release identity:** source still advertised the already published 5.1.0 despite new behavior under Unreleased. Promoted the changelog and executable version to 5.2.0; published stable/standalone metadata remains 5.1.0.
2. **Meeting retry with unreadable locks:** source-only meetings could not reach the existing recovery lease fallback when their lock was empty or corrupt. Capture reconstruction now uses the same read-only candidate interpretation as lease admission; missing locks and live future-schema owners remain refused. See [capture review](capture-review.md).
3. **Audio after cancelling video:** navigating with Show Video open, then hiding a pending video, could leave the retained audio unloaded. Cancelling a pending video, or hiding it after a failed direct load, restores that audio if no player exists, including legacy conversion. Cancellation is checked again after conversion persistence to prevent an old operation replacing a newer selection. See [services review](services-review.md).
4. **Historical CLI notes:** the 300-second request timeout and segmented long-transcript cleanup were already in both `v0.8.10` and `cli-v5.1.0`, but their notes remained under Unreleased. Moved those entries to 5.1.0 rather than presenting them as new 5.2.0 behavior.
5. **Stale playback duration:** an existing adjacent race could publish a previous player's asynchronously loaded duration after navigation. The metadata commit now checks player identity. A deterministic result-application test covers current, stale, invalid and cleaned-up owners; it does not claim to reproduce AVFoundation timing.
6. **Audio-track discovery scratch output (#1292):** the probe ignored a failed scratch-log creation and turned an unreadable log into an empty successful track list. It now creates its temporary folder on demand and throws creation and read errors, with the log removed on launch failure, read failure and cancellation. Subprocess tests cover those boundaries. The reporter's exact filesystem cause is unknown, so this is not claimed as a fix for that machine.

The [interaction review](interaction-review.md) found no further confirmed issue in keyboard handling, dictation controls/sounds, vocabulary and Settings. Sound asset hashes and PCM metadata match the original-asset manifest. [Draft release notes](../../releases/0.8.11/README.md) are prepared locally.

## Acceptance boundaries

Automated proof does not establish the following native/physical/distribution behavior. Keep these as explicit acceptance gates for the exact release artifact:

- Dictation in a real target app: hold-to-talk, hands-free, second shortcut, repeated paste, physical typing interruption and remote desktop; imported cues and device routing.
- Back-to-back meetings: stop one and start another during finalization; microphone/system audio on built-in, Bluetooth and changed routes; verify both retained recordings and retry after restart.
- Meeting reminders: opt-in/off behavior, supported native/browser calls, dismissed prompts and explicit Record action; no unexpected recording.
- Library video: navigation during extraction, Show/Hide while downloading, retained audio, offline behavior and signed yt-dlp/FFmpeg helpers.
- Real model transcription on representative speech and supported hardware, including long recordings and limited-memory machines.
- Exact Developer ID app/DMG, required echo assets, notarization Accepted, Gatekeeper, installation and Sparkle upgrade from 0.8.10; no publication before artifact identity is verified.
- Deploy the companion website telemetry allowlist patch described below before releasing the app; source tests do not prove the live service has it.

## Verification

Existing baseline CI run `41323390324` succeeded for `bb1ebcc37974bfb363f2bec46250bc0532009f17`; this is not evidence for later changes or physical capture/distribution qualification.

- Original implementations reproduced failed source-only meeting retry and unavailable retained audio after video cancellation (`regression-red.log`). The separate active-lock fixture initially compared a timestamp across JSON serialization; it now checks unchanged on-disk bytes, the actual preservation contract.
- Initial focused Swift suite on the code committed as `ee3f9b87e`: **165 passed**, zero failures, covering capture/locks, queue/coordinator/detail retry, media/video and CLI version (`focused-tests.log`). This predates the gate's follow-up fix.
- Final focused suite on `d66cfae0f868c95be5fa37ec31e6f64c56cf362e`: **177 passed**, zero failures, adding failed-video restoration and executable audio-probe I/O cases (`final-focused-tests.log`).
- CI helper tests: **46 passed**. Distribution policy fixtures passed for version, privacy, Mach-O minimum OS, echo asset preparation and echo verification.
- Ask helper: **14 passed** using the packaged helper path. An initial harness invocation omitted that path and could not locate its notices; using the CI environment fixed the invocation without source changes.
- CLI persistence smoke passed across independent processes. Subsystem README references passed. All 104 Swift telemetry events are accepted by the sibling website checkout's 110-entry allowlist; this is a source compatibility check, not a live ingestion test.
- Changed-file Swift lint exited zero with style warnings on the initial code and again on `d66cfae0f` (`final-focused-lint.log`); `git diff --check` passed. Local Greptile cannot run because the installed CLI is not signed in. Independent code reviews completed.
- No-mistakes run `01M6C5E5TASPVSPTMJTNXW5H9C` completed its local review gate at `d66cfae0f`. It found the additional failed-video restoration case; its fix round also implemented the confirmed probe-I/O finding. Test/lint/rebase/intent/document/publication/PR/CI stages were explicitly skipped: the parent owns verification and this task does not publish. The remaining informational comment about test attribution is addressed by the exact-commit receipts above. Six audit/manifest files lacked tool coverage; the parent reviewed them and verified both manifests byte-for-byte against the pinned git comparison.
- The initial cold build was interrupted by concurrent edits to a compilation input; the subsequent focused commands rebuilt successfully. The single full suite completed successfully on `d66cfae0f`: **8,519 XCTest cases, zero failures/errors**, plus **30 Swift Testing tests passed**. The xUnit format does not report skipped cases, so the case count is not represented as an all-executed count. See the [summary](evidence/full-test-summary.md). The invocation used `--skip-build --parallel --num-workers 4` with the CLI and Ask runtime paths explicitly set.
- After integrating current main, **231 focused tests passed**, zero failures, on `b9eab04a1`. These cover title generation, transcription, capture/recovery, playback, audio probing and CLI version. The full suite was not repeated, respecting the one-run limit.
- Upstream main CI [41336689600](https://github.com/moona3k/macparakeet/actions/runs/41336689600) passed for `f7d1a4457`: Tests and Swift 6, Release and Bundle, including its CLI contract smoke. That is separate evidence for the integrated upstream title change; this local branch has not been pushed or run in hosted CI.
- Real Parakeet v3 transcription, fresh-process history and Markdown export passed on synthesized audio. A second transcription explicitly selecting audio track 1 passed through the real shipped FFmpeg binary on `d66cfae0f`, exercising the repaired probe (`evidence/smoke/`). Both opt-in process-kill/crash-recovery tests passed on the initial candidate; their capture code is unchanged by the gate follow-up.
- Local health safely reports schema skew for this machine's existing library (`v0.10.1-quick-prompts-pin` is newer than this release branch understands). It was not modified. Persistence and transcription qualification use disposable databases; this personal development-library state must not be mistaken for a failed 0.8.10 upgrade test.
- Release Xcode GUI and SwiftPM CLI builds passed on `b9eab04a1f4f`. The canonical bundle script included real FFmpeg, yt-dlp, Node, Ask helper and required LocalVQE assets. Developer ID signing and strict deep verification passed, including the privacy surface, echo model hash, runtime minimum OS and signature checks. No notarization submission or DMG was created.
- After signing, bundled CLI **5.2.0**, yt-dlp **2026.08.19**, FFmpeg **9.0.2** and Node **24.13.1** ran successfully. Packaged Markdown colors/icons resolved, CLI JSON contract smoke passed, Ask remained disabled with and without developer opt-in, and independent-process persistence passed. The signed CLI also passed real Parakeet v3 transcription, history and Markdown export in a disposable database. Strict bundle signature verification passed again after these executions.

Raw local logs are retained in `evidence/` and excluded from source history. The full-suite summary and signed-candidate receipt are committed; the latter records the exact artifact identity. Local Greptile, native/physical and distribution gaps above remain explicit.

## Recent reports and integration

The [recent-issue risk assessment](recent-issue-risks.md) distinguishes the fixed temporary-output defect from existing system-audio startup failures (#1266) and the unreproduced Whisper silence report (#1278). These remain known risks, not proven fixes or newly introduced regressions. Do not close those reports based on this review.

Remote main advanced to `f7d1a4457efbe7acaff76091ae8666d7d7313acf` (meeting-title fix, #1309) while verification was underway. An independent read-only integration review found no concrete conflict with capture recovery: it changes title validation/generation, respects persisted row titles/overrides, and bounds retry/cancellation. It was integrated locally in `b9eab04a1` after the full run and verified with the focused integration suite above. The earlier full run does not cover that combined tree.

No step used Jev: this work involved code reasoning, fixed contract checks and synthetic regression tests, with no new semantic-decision integration.

## Fresh review requested after the initial handoff

Live GitHub and git checks confirm PR [#1309](https://github.com/moona3k/macparakeet/pull/1309) merged at `f7d1a4457` and was already included in the initial candidate. Remote main still pointed to that commit when this pass began. Fresh reviewers independently inspected stable `v0.8.10` through `93e7b3944`, including the first review's fixes, rather than assuming the earlier verdict was sufficient.

- [Capture/recovery review](fresh-capture-review.md): no additional confirmed introduced P1/P2 in capture, lease ownership, queue settlement, retry, editing or deletion. Native and high-latency AEC acceptance remain separate.
- [Interaction/playback review](fresh-interaction-review.md): no additional actionable P1/P2 in input, URL consent, sounds, vocabulary, Settings or media ownership/cancellation.
- [Title/services review](fresh-title-services-review.md): one pre-existing P2 and one introduced P3 were confirmed and fixed. A calendar name such as `Meeting May Hiring Plan` could be overwritten by the old fallback-name heuristic. A recording that actually uses its saved calendar title is now protected. Distinct probable calendar metadata on manual recordings still allows automatic titles. PR #1309 also allowed generic labels with only a year appended; `Meeting 2027` is now rejected while descriptive topic years remain accepted.

Both findings reproduced against the prior implementation: two focused cases produced 14 failed assertions. Adversarial review caught an overly broad first calendar guard before commit; a probable-snapshot regression reproduced three failed assertions and drove the narrower adopted-title comparison. Final focused title/transcription/capture/queue/detail-retry verification: **206 tests, zero failures**. Both reviewers rechecked the correction with no remaining finding. Changed-file lint exited zero with existing style warnings; whitespace checks passed. The earlier full-suite receipt applies to its recorded commit, not these follow-up fixes; the full suite was not repeated.

The parent also rechecked Release feature gates, URL integration, telemetry fields and packaging scope. Experimental Voice Control/Ask/sharing/profile gates remain closed in Release; the new meeting reminder runtime remains opt-in. No publication, live telemetry event or external review comment was submitted.

Final no-mistakes review run `01M6CBJR7KSK4JMJH6H9D5TFGG` completed at `0146098b013e` and returned branch custody without source changes. It found no additional behavioral defect. Its release-README mismatch was valid and is corrected by pointing to the refreshed artifact. Its suggestion to reuse `AppPaths.tempDir` in the probe was declined as a nonblocking reuse preference: both paths resolve to the same `macparakeet` child of `NSTemporaryDirectory`, and the existing injected-root tests cover creation/read/cleanup. Intent/rebase/test/document/lint/push/PR/CI stages were explicitly skipped; parent verification remains separate. No hosted CI result is claimed for this local branch.

The canonical Release app/CLI rebuild, Developer ID signing, strict signatures, privacy/echo checks and Sparkle trust-anchor check passed for **0146098b013e / 20261101201053**. Post-signing helpers, Markdown resources, CLI contract, Ask release gate, independent-process persistence, and real Parakeet v3 transcription/history/export passed again in disposable storage. Strict signature verification passed after execution. The earlier full-suite receipt remains attributed to its earlier source; this follow-up uses the 206-case focused suite plus the new Release/package checks.

### Companion telemetry integration fix

Event-name compatibility alone missed a value-normalization gap. Website `origin/main` at `1921d66` accepts the existing event names but converts `trigger=url_control`, `trigger=activity_detection` and `setting=meeting_activity_detection_mode` to `unknown`. A local SQLite-backed route test reproduced all three losses; this affects telemetry attribution rather than recording behavior.

The isolated website branch `fix/release-0811-telemetry-dimensions` contains companion commit **18727cf**. It adds only the three finite categories. **69 focused tests passed, zero failures/skips**, covering ingestion, public dimensions, privacy, statistics and rollups. Independent review confirmed exact Swift enum alignment; the fixture uses the app's actual `prompt` setting value. The website's existing unrelated work was preserved. Its `docs/release-0811-telemetry.md` records validation and deployment ordering. No website deployment or live ingestion verification was performed. Deploy the companion before app publication; no app rebuild or schema migration is required for that server-side change.

## PR #1310 follow-up

Hosted CI [41399206771](https://github.com/moona3k/macparakeet/actions/runs/41399206771) passed all tests, CLI qualification, Swift 6 language mode and Release bundle checks on `5a1ae90973cb611f93b0fb7d75ca68c704f15012`. This is the pre-follow-up head, not evidence for later changes.

One narrow title edge case was confirmed: an unnamed manual recording can receive a probable calendar snapshot whose title exactly matches its generated timestamp name. The old equality guard then suppressed generation. Protection now requires confirmed calendar provenance as well as equal normalized names. Calendar selections produce confirmed snapshots; unnamed manual/hotkey starts produce probable snapshots; explicit user edits retain their separate override protection. The new case reproduced three failed assertions before the condition changed. Final focused title/transcription/calendar-start/probe/CLI verification passed **142 tests**, zero failures. Independent review found no further issue in the delta. Changed-file lint exited zero with existing warnings; whitespace checks passed. The local full suite was not repeated.

PR feedback also tightened the unreadable-probe-output test: it now verifies successful helper completion, the exact failed path, Cocoa read error and underlying EISDIR before checking cleanup. CLI version test names now accurately describe the source version, including prepared candidates. Audit range/commit attribution, the local-only issue snapshot hash, video recovery conditions and companion telemetry test references are clarified.

The other source concerns were assessed and declined with evidence in their PR threads: retry uses the persisted transcription ID and separate lease token rather than the placeholder capture UUID; the same-user scratch pathname race predates this release and has no demonstrated exposed privilege boundary; no error-after-create mechanism was established for the zero-length write. These are not claimed as newly fixed product defects.

The notarized build `20261101201053` is retained at `dist/qualified-20261101201053/` and superseded by the title follow-up. Its acceptance IDs and hashes remain historical evidence. The replacement candidate and final head CI are tracked in the current artifact receipt and PR. Native/audio acceptance, installation and a real Sparkle upgrade remain pending; the personal development library remains untouched.

### Final PR-head hosted verification

[CI run 41404657126](https://github.com/moona3k/macparakeet/actions/runs/41404657126) passed at `04c97338bb3075ff06ef48a28933d3a87bb7ae83` before PR #1310 merged. Its downloaded report records **8,533 XCTest cases, zero failures/errors**, with skipped cases not reported by the XML, plus **30 passing Swift Testing tests**. Swift 6 language mode, Ask CLI qualification, separate-process persistence, meeting process recovery, Release bundle and CLI contract checks passed. The subsequent receipt-link/spec-copy cleanup changes no executable source, tests, manifests, scripts, or release-note content; the notarized candidate remains unchanged.
