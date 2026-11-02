# Release risk triage — November 1, 2026

Read-only assessment of issues #1292, #1266, and #1278 against the release review candidate. Source inspection initially used `ee3f9b87e`; the relevant production files were identical to `v0.8.10`. This report preserves the pre-fix assessment and suggested verification. The bounded #1292 repair subsequently landed in `d66cfae0f`; final implementation and test results are recorded in the [release receipt](README.md).

Evidence sources: the local-only `2026-11-01-recent-issue-validity.json` snapshot (SHA-256 `870ab7fa3dbe7be12a5ff3405a3061ebb15a1a712b9a2a80e07ed4d3f9679568`; not a committed artifact), with public originals [#1292](https://github.com/moona3k/macparakeet/issues/1292), [#1266](https://github.com/moona3k/macparakeet/issues/1266) and [#1278](https://github.com/moona3k/macparakeet/issues/1278), current source, focused test source, and the issue-attached diagnostic log already tracked in the repository. No builds, tests, native audio actions, provider calls, or live model evaluation were performed for this triage. No branch files were edited. #1283/PR #1309 was left untouched.

## #1292 — include the bounded temporary-output repair

**Confirmed defect, P2; reporter trigger not established.**

`Sources/MacParakeetCore/Audio/FFmpegAudioTrackProbe.swift:104–109` ignores `createFile` returning false, then opens the nonexistent log. `TranscriptionViewModel.swift:694–709` propagates that error for single-file preflight. A missing temporary parent produces the reported Foundation error shape, as demonstrated in the earlier audit; permissions and external removal remain other possible causes, not proven explanations for this reporter.

The probe also uses `(try? String(contentsOf: logURL, encoding: .utf8)) ?? ""` at line 132. A real output-read failure can therefore turn a successful process into an apparently valid empty track list. Legitimate readable empty stderr must remain a distinct outcome: parsing it can still produce an empty list, while an inaccessible or missing output file should throw.

**Disposition:** fix before the final full suite. Keep the repair limited to robust temporary-output creation/read/cleanup and an internal executable/temp-root testing seam. No new protocol or generic process abstraction is necessary. Keep file-backed subprocess output; switching to undrained pipes would reintroduce deadlock risk. Preserve ChildProcessWaiter timeout/cancellation behavior and remove only this invocation's owned artifacts.

**Precise test suggestions:**

1. Inject a temporary root whose parent does not exist, invoke the real probe process path using a tiny executable fixture that writes a valid FFmpeg input summary to stderr, and verify parsed tracks plus removal of only the probe-owned directory/log. This should exercise the creation repair rather than mocking `ProbeResult`.
2. Supply an invalid parent, such as a regular file occupying the root path. Verify a thrown setup error, no fake-process launch marker, and preservation of the caller-owned parent and neighboring files. This is more deterministic than permissions tests when CI may run with elevated privileges.
3. Have a successful fixture emit no stderr. Verify a legitimate empty track list, preserving parser semantics.
4. Exercise an actual output-read failure through a narrow internal seam or deliberate output-path removal after the process completes. Verify it throws instead of returning zero tracks. Do not silently replace malformed/unreadable bytes with success if decoding is required.
5. Use a nonexistent executable path after successful output setup. Verify launch error propagation and owned-artifact cleanup.
6. Use a controlled long-running helper. Cancel after its launch marker, then verify the process has exited before owned output artifacts disappear. If a timeout seam is available, cover timeout with a short injected deadline; do not make focused tests wait the production 30 seconds.
7. If output size is newly bounded, emit more than the limit and verify a clear bounded failure without an undrained-pipe hang. File-backed output avoids pipe backpressure; cap reads rather than blindly loading the complete file.

Existing `FFmpegAudioTrackProbeTests` only inject completed results and cannot detect setup/read/cleanup defects. Real FFmpeg and media downloads are unnecessary for these I/O regressions.

A read-only check of worktree paths/branch names found no `1292`, `audio-track`, or `audio-probe` named worktree or branch. This was a name-based overlap check, not proof that unrelated differently named work could not touch the same file. The no-mistakes pipeline was the sole designated implementation owner and has returned custody after completing the fix.

## #1266 — verified system-audio loss, unresolved hardware/runtime cause

The report is stronger than an unsupported wake hypothesis. In `diagnostics/1792396450758-dictation-audio.log`, lines 974/1002, 1150/1178, and 1197/1243 pair initial stream-start failure with zero system frames and unavailable system capture. Line 1274 records successful system capture in a new process. The failure is real; association with wake and the underlying ScreenCaptureKit condition are not established by those records.

`MeetingAudioCaptureService.swift:812–819` records initial-start failure and tears down the capture. Runtime failures instead enter bounded recovery at lines 1043–1055. Initial startup and runtime recovery have different lifecycle ownership, so reusing the latter naively could create start/stop races or falsely commit a dead source. Existing focused tests intentionally cover failed-start cleanup and failures before startup commits.

**Disposition:** retain as a material known capture risk and native sleep/wake qualification item. Do not claim it is fixed by the current release or by unrelated capture-finalization changes. Avoid adding broad startup recovery immediately before release without a targeted design, tests for successful retry/exhaustion/cancellation/late callbacks, and native evidence that retry addresses the observed condition. This is an existing stable defect, not an established regression introduced by the release candidate.

## #1278 — credible Whisper accuracy report, no independent audio reproduction

The reporter describes Spanish `large-v3-v20240930_turbo_632MB` emitting standalone “Gracias.” in near-silent meeting windows and provides a comparison with whisper.cpp plus Silero VAD. This is detailed author-reported evidence, but no audio fixture was supplied for independent reproduction in this review.

`WhisperEngine.swift:369–375` sets language and word timestamps without app-owned audio/VAD overlap filtering. Lines 467–474 pass merged Whisper text and words through to the application. The wrapper is unchanged from stable. The code supports the proposed failure mechanism but does not establish that a particular threshold or VAD intervention preserves quiet legitimate Spanish speech.

**Disposition:** keep open as an explicit Whisper accuracy limitation and model/audio qualification item. Do not blacklist “Gracias.” or other legitimate language, and do not add broad VAD suppression without audio-based tests covering silence, quiet speech, timestamp preservation, and cancellation. This is not a verified newly introduced regression, and no fix is claimed.

## Release interpretation

The bounded #1292 repair is suitable for this release-preparation scope. #1266 and #1278 should remain explicit unresolved risks, with native capture/model verification separate from compilation, synthetic tests, or green CI. A release-readiness report should state these limits rather than imply the entire existing issue backlog or physical capture behavior has been proven correct.
