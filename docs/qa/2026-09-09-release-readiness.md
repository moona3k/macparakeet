# 0.8.0 final release review

This review found and fixed a release blocker in the Meetings auto-run controls.
Final CI and signed-artifact receipts are subsequent gates; the initial bundle
below predates the fix and must not be distributed. No public release, appcast,
Homebrew update, or download upload is authorized by this review.

## Scope and source

- Baseline: `9eebffc7972548d0941456c8017cf46e58fde7f2`, after PR #991.
- Intended release: app **0.8.0**, embedded CLI **4.0.0**.
- Public channel verified on September 9: app **0.7.3**, standalone CLI **3.1.0**.
- Independent Cursor/Grok reviews covered recording/recovery and notes,
  prompt/label state, CLI contracts, packaging, and the Cohere backend decision.
- The earlier [September 7 QA](2026-09-07-0.8.0/README.md) applies only to the
  candidates named there. Its notarized package is not the final candidate.

## Release blocker and correction

The Meetings **After each meeting** chips wrote the development-only
`prompt_meeting_policies` table. Execution read canonical prompt auto-run fields
and label availability instead. Disabling Summary could leave it running;
enabling Action Items could leave it absent from the queue.

The card now writes source-scoped `.meeting` auto-run through the same repository
used by Prompt Library and execution. Its display uses label availability and
`Prompt.autoRuns(for:)`. Other source preferences are preserved. Returning to
Meetings refreshes its prompt snapshot, so edits made in the separate Prompts
screen are reflected without reloading the calendar or recent-meeting list.

Review also identified a misleading fallback on label-policy read errors. The
card preserves its last known restrictions, treats an initial failed load as
unknown, and displays an error instead of offering switches. A successful
legacy meeting-policy reload cannot clear the separate label-policy error.

No reverse migration is appropriate: published 0.7.3 already stores auto-run in
these canonical fields. The legacy table was introduced only in development.
Existing development testers may see the card return to the settings execution
actually used; they can re-toggle it to save their intended setting. No user
preferences were rewritten during this review.

## Verification before final CI

| Check | Evidence and scope |
| --- | --- |
| Baseline full CI | [34320892604](https://github.com/moona3k/macparakeet/actions/runs/34320892604) passed on a tree identical to `9eebffc7`: Release, CLI/package smoke, concurrency, Swift 6, full tests. This precedes the fix. |
| Original defect | Two production-wiring regressions failed before the fix. Real repositories plus a mock LLM prove queue selection without provider calls. |
| Focused fix tests | 72 workspace/result tests passed. Coverage includes Summary off, Action Items on, other-source preservation, hidden prompts, and labeled/unlabeled queues. |
| Tab-return defect | A separate real-repository regression failed before the refresh correction. All 22 workspace tests passed afterward, including unchanged calendar/list fetch counts. |
| Availability read errors | Regression failed before correction; all 23 workspace tests passed afterward. First-load errors hide unknown controls, later errors preserve restrictions, and legacy policy success cannot erase the error. Independent Grok review: LGTM. |
| CLI version | Two `CLIVersionTests` passed. Unreleased gateway notes and inference flags are recorded under the unpublished 4.0.0 release. |
| Distribution fixtures | Version and privacy validation fixture scripts passed; distribution scripts were not changed. |
| Initial real bundle | Built 0.8.0 / `20260909074325` at `9eebffc7`, CLI 4.0.0, required echo assets verified. **Predates fix; not a final artifact.** |
| Initial CLI runtime | Raw-mode local transcription/export and disposable-database collections, prompts, label colors/rename, versioned model/settings, label availability, and reset commands passed in that initial bundle. |
| Intermediate signed bundle | Build `20260909082721`, source `6c0200ae`, passed signing/privacy/echo checks, helper startup, and local transcription/export. Its notarization upload is preserved under submission `a2c56ec5-7fa1-4726-8732-a13f4d46708e`; it predates the availability-error correction and is superseded. |
| Isolated GUI startup | A separately identified copy of `6c0200ae` opened Meetings against a verified disposable SQLite path. Auto-note chips required AI setup, so no GUI toggle or provider configuration was attempted. The QA copy quit normally; the user's open app was untouched. |

Local detailed review and command logs are under `/tmp/macparakeet-release-*` on
the review host. They are supporting local evidence, not durable public assets.
Final artifact identity, final CI, signing/notarization, signed-helper startup,
and repeat transcription/export must be recorded for the corrected candidate.

The installed no-mistakes daemon selects Claude and cannot select Grok per run.
Independent Cursor/Grok reviews and the normal GitHub gates honor the requested
model. Local Greptile requires authentication; its absence is not a review pass.

## Release scope and remaining coverage

| Item | Disposition |
| --- | --- |
| [PR #865](https://github.com/moona3k/macparakeet/pull/865), transcribe.cpp Cohere | Defer. Open/conflicting, significant backend and packaging change. Retain current FluidAudio/CoreML Cohere. |
| [PR #974](https://github.com/moona3k/macparakeet/pull/974), FluidAudio 0.15.6 | Already merged and included; no new inclusion decision. |
| [#933](https://github.com/moona3k/macparakeet/issues/933), [#949](https://github.com/moona3k/macparakeet/issues/949), [#952](https://github.com/moona3k/macparakeet/issues/952) | Existing hardware/hotkey/Whisper reports remain unresolved. Do not advertise them as fixed by this review. |
| [#976](https://github.com/moona3k/macparakeet/issues/976), [#977](https://github.com/moona3k/macparakeet/issues/977) | Existing capture/Line In reports; affected hardware not exercised here. |
| GUI, live external providers, Bluetooth/system-audio combinations, stable-to-candidate Sparkle upgrade | Not certified by these source reviews or mocked tests. |
| Standalone CLI/Homebrew 4.0.0 | Separate publication; the app may embed 4.0.0 while Homebrew remains on 3.1.0. |

## Proposed release highlights

Use the stable-to-candidate inventory when preparing the final public notes:
meeting startup/recovery improvements and saved notes; Library labels, favorites,
and generated recording covers; clearer transcript-prompt and Live Ask management;
model-aware generation controls; richer transcript/results display and export;
and the bundled agent-facing CLI. Do not imply every reported capture problem
or every provider/model combination has been verified.

**CLI 4.0.0 compatibility:** `export --stdout --format txt` now matches TXT file
export, including header, timestamps, and speakers. Callers needing bare text
should use the documented JSON transcript fields. Prompt collections/history,
labels, inference controls, and optional meeting-note context are documented in
[the CLI changelog](../../Sources/CLI/CHANGELOG.md) and
[the integration guide](../../integrations/README.md).
