# MacParakeet 0.8.0 release verification

**The candidate is validated for final user QA.** The combined app and DMG are signed, notarized and verified; the exercised GUI, CLI and regression checks passed within the scopes below. Both exact-head CI runs passed, and [PR #979](https://github.com/moona3k/macparakeet/pull/979) merged into main at `e476f156` on 2026-09-08 00:07:14 UTC. This is not certification of every matrix combination, and no release download, appcast or GitHub asset has been published by this QA task.

## Candidate and evidence provenance

| Item | Exact scope |
| --- | --- |
| Stable baseline | `v0.7.3`, `d6321f87dccecf29bd4792113f522bb0c98d1f35` |
| Initial main / baseline GUI | `8548c099af5ee2ab0ed4dd9efe757d85c498cca0` |
| Single full-suite product source | `96b2025253ad71d01566713560ea7d101a13c53d` |
| First rebuilt GUI after QA fixes | `3827999ddb84c8a8e0edcb3ac190e66813fc95fe` |
| Combined saved-notes source / final built candidate | `250bbe2994a4b60b4ef81ac257f0ee6bb70874d3` |
| Main merge | `e476f1567d0e1ed8aaeedf29751c871262d33b93`; same tree as tested source `250bbe29` |
| Final app / build / embedded CLI | `0.8.0` / `20260907232424` / `3.3.0` |
| App ZIP notarization | `52abbad6-6f63-49a6-a3de-4fd7f7ba2cb3` — **Accepted** |
| DMG notarization | `faa10966-3c5d-41e1-990f-bf2f9bafa45f` — **Accepted** |

The owning branch is `release/0.8.0-qa`, based in a dedicated checkout. The later main update added saved meeting notes from PR #959; the combined candidate received its own focused tests, build, package verification and notes GUI pass. Report-only commits do not change the built source identity. GUI checks used an isolated copy with bundle ID `com.macparakeet.qa.release080` and a verified owned SQLite path. That copy has a separate test identity from the notarized distribution app.

[Package verification](package-runtime.md) records strict signatures, staples, Gatekeeper acceptance, app/ZIP/DMG payload equality, signed helper startup and exact artifact hashes. The final stapled DMG is 167,213,899 bytes with SHA-256 `17fbf6c6a2a3ed6ada8ce3f0816adae041832f27d7b3a9a2ac9e3499859bcb22`. Preserve those bytes when producing matching release metadata.

## Verified results

| Area | Observed result and limit |
| --- | --- |
| Full suite, once | At `96b20252`: **5,461 XCTest tests, 20 skips, zero failures**, plus **29 Swift Testing tests, zero failures**. [Summary and raw-log hash](evidence/full-swift-test-summary.log). This run predates the saved-notes merge. |
| Combined-source regression gate | At `250bbe29`: **694 focused tests passed**, covering notes, database, prompts, cache and recovery integration. [Gate evidence](evidence/merged-notes-focused-summary.log), [merge review](new-main-notes-review.md). The full suite was not repeated locally. |
| Final exact-head CI | Both [push](https://github.com/moona3k/macparakeet/actions/runs/34169966386) and [PR](https://github.com/moona3k/macparakeet/actions/runs/34169968359) CI passed at `250bbe29`, including Release build, CLI/bundle smoke, concurrency, Swift 6 and the full test step. Both reached 5,563 parallel test items and explicitly reported 29 Swift Testing passes; the parallel log does not supply an XCTest skip count. [Receipt and raw-log hashes](evidence/pr979-ci-summary.json). |
| Three concrete fix families | Recovery discard now respects ownership and preserves retry markers; timed transcript caches/actions are scoped to the displayed record; packaging preserves a real Sparkle framework root. Deterministic RED/GREEN evidence, independent source review and actual package checks support these fixes. |
| Baseline destructive GUI | Vocabulary **1025 → 1023 → 926 → 0**, with cancellation preserving data and one snippet untouched. Track cancellation created no row; English selection persisted ordinal 0. Transcript editing preserved raw text. Actual GUI DAPT output passed validation. [Baseline GUI](gui-runtime.md). |
| Rebuilt transcript/Markdown GUI | At `3827999d`: ALPHA/BRAVO navigation kept active-record content; 10,000 timed words reached sentence 1000. Rich saved summary/chat rendered. At `250bbe29`, whole-summary and table Copy passed again. Code-block Copy remains unverified. [Rebuilt GUI](gui-rebuilt.md). |
| Saved notes on final built source | At `250bbe29`: **six GUI checks passed** for autosave, navigation, revision preservation, ordinary quit, relaunch and `notes.md`. Raw transcript unchanged. [Saved-notes pass and inspected screenshots](saved-notes-gui.md). |
| CLI and exports | Synthetic loopback-provider contracts and legacy-schema migration passed; three representative DAPT fixtures passed XSD and BBC rules with Markdown/SRT/JSON preservation checks. [CLI matrix](cli-runtime.md), [DAPT matrix](dapt-runtime.md). Live external-provider behavior was not exercised. |
| Real file audio | Six embedded-track/diarization cases and **29 assertions passed**. Engine/language samples produced observed transcripts; extended Japanese/Korean/Mandarin Cohere probes completed. Earlier timeouts and boundary attribution/wording errors remain recorded. [File audio](file-audio-runtime.md), [engine matrix](audio-runtime.md), [Cohere follow-ups](cohere-extended.md). Sample completion is not general accuracy certification. |
| Microphone | Test Input detected actual input; two microphone-only meetings retained audio. The low-level replay had no recognized text; the louder public-speech replay produced 116 characters, and volume was restored. [Runtime observations](microphone-runtime.md). |
| Hardware and actual AEC assets | Root's microphone hardware gate: **10 passed, three skipped**. Actual packaged AEC runtime: **two tests passed**; 60 seconds conditioned in 5.426 seconds (**11.06× realtime**). These earlier asset/hardware runs do not establish Bluetooth or real-conversation echo quality. Exact local-log hashes are retained below. |
| Packaging | All **24 synthetic preflight commands** met expected outcomes. The actual final package subsequently passed signature, privacy/assets, helpers, dependency, DMG payload and notarization checks. [Preflight](package-preflight.md), [final artifact](package-runtime.md). |

Recovery history remains available: [stale-owner RED](evidence/recovery-discard-red.log), [first GREEN/cache RED](evidence/cache-red-recovery-green.log), [cache GREEN](evidence/cache-green.log), [partial-delete RED](evidence/recovery-partial-delete-red.log), [87-test GREEN](evidence/recovery-partial-delete-green.log), [mutex-release RED](evidence/recovery-mutex-release-red.log), and [88-test GREEN](evidence/recovery-mutex-release-green.log). Five changed Swift files introduced no new formatter diagnostics relative to their base ([comparison](evidence/format-comparison-final.json)).

Root's local hardware log `hardware-microphone-tests.log` has SHA-256 `6bcffaacdace6fe8d6f9c6155b4c9008661cd677f8e81c22ddc39fc4b7fb7334`. Its three skips cover default-input mutation, the three-minute idle gap and extended cycle stress. The local `packaged-aec-runtime.log` has SHA-256 `66e5b93b0e5576d7c571b8ee9e0f0abb5a141684f38736e0686112bacf53720c`. These logs were read for their summaries; this report update did not rerun those gates.

## Methodology and reusable lessons

The [dashboard](index.html) and [evidence data](evidence.json) retain actual candidate, expected behavior, observation, status and limits per check. Historical RED and later GREEN stay separate. A later build or untested combination does not inherit a pass from an earlier snapshot.

1. Map stable-to-candidate changes to workflows, contracts and failure paths; split independent source reviews while one owner controls desktop and product builds/tests.
2. Verify disposable paths before destructive actions. A dev bundle ID alone does not isolate databases, named preferences or Keychain. `CFFIXED_USER_HOME` redirected Foundation paths after a resolver/open-database check; named suites and credentials required separate treatment.
3. Exercise actual GUI/CLI actions, then check persisted rows, retained audio, export/clipboard contents or validators. A successful automation call is not proof that the UI changed.
4. Establish deterministic regressions before narrow fixes, run focused families during iteration, and reserve one full local suite. Validate later merged source with the affected combined families.
5. Verify the exact rebuilt package and relevant GUI paths. Keep package acceptance, user QA, merge and publication distinct.

Native AppKit/ApplicationServices inspection, AX actions and focused input supported GUI verification after the available browser computer-use runtime could not operate on this host. No runtime guard was bypassed. Pure AX value-setting did not consistently reach SwiftUI bindings. Numeric AX indices drifted as windows changed; resolving stable attributes inside the same process that actuated them fixed navigation. Relaunch verification had to wait for the actual startup alert rather than assume a fixed tree.

The first notes navigation attempt received concurrent user input and was invalidated. Desktop work stopped, private input was preserved outside curated evidence, and all six checks were rerun successfully once the desktop was available. Clean replacement captures were individually inspected. A missing owned Downloads directory initially blocked GUI export; creating that directory resolved the fixture problem. Low replay volume produced usable audio frames without recognized speech, so capture success was not mistaken for recognition success.

Curated media contains inspected app-window synthetic/public content only. Raw AX trees, file panels, unrelated user input, original clipboard backups and private audio are excluded. JSON path redaction must account for escaped slashes; parsed before/after comparisons and source/curated hashes now verify that only intended path values changed. [Browser validation](report-validation.md) records its own two HTML fixes and historical 106/107 then 26/26 assertion results and a further 26/26 pass against the completed 43-check snapshot.

## Remaining coverage and release boundaries

- Global hotkeys and automatic paste remain unverified. Accessibility setup reached system authorization, but System Settings disappeared during the add flow; permission and end-to-end paste success were not established.
- System-audio capture, Bluetooth/device transitions, pause/mute, and quiet completion while another app owns focus remain open. Both quiet options were observed off while the QA app was already frontmost.
- Code-block Copy lacks a working AX activation route and did not produce verified content with targeted clicks. Full-summary/table copying work; whether the code-label click failure is automation or product behavior remains unresolved.
- Sparkle upgrade from an installed stable app, a second physical Mac, and live external-provider requests remain unverified. Saved seeded Markdown/chat and loopback requests do not cover live streaming/provider combinations.
- The inherited stale Library snippet after transcript editing and completed-session repeated-discard UX remain documented follow-ups. Missing recovery locks must not authorize deleting retained audio.
- [PR #979](https://github.com/moona3k/macparakeet/pull/979) merged after both CI checks passed at the tested head. The accepted local artifacts have not been published. Final user QA and release publication are subsequent decisions.

Additional source and method reports: [release inventory](release-inventory.md), [audio/recovery review](audio-review.md), [CLI/data review](cli-data-review.md), [UI review](ui-source-review.md), [hosted review dispositions](pr-review-disposition.md), [reusable GUI fixtures](gui-fixtures.md), and [historical setup log](runtime-log.md).
