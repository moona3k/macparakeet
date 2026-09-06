# Upstream review remediation

Status: corrections implemented and independently reviewed; publication and screenshot approval pending.

The review of upstream `1159dfca` against fork `7c36fdc0` identified eight
cross-component defects. Correct and validate them in the fork before updating
the upstream proposals and marking them ready for review.

## Invariants

- Preserve current user-owned meeting metadata during asynchronous recognition.
- Preserve original recognition output; apply speaker corrections once, and use
  the same effective attribution in UI, AI context, CLI and files.
- Prompt-policy mutation and execution must share label semantics. Unrelated
  prompt edits must preserve existing restrictions, including migrated shapes.
- Provider validation must accept models supported by the existing catalog.
- A retained Markdown pane must resume after its consumer is cancelled. Images
  remain disabled, links remain restricted, and table text/actions are accessible.
- Keep migration identities and CLI/artifact contracts explicit in each slice.

## Corrections

1. Transactional preservation and returned snapshots for retranscription metadata.
2. Speaker revision in rich-AI cache keys and submission freshness checks.
3. DB-bound attribution reader for CLI classification artifact refresh.
4. Pass the complete speaker projection through GUI artifact refresh.
5. Active label-policy CLI setters and explicit rejection of obsolete type flags.
6. Gemini/Gemma compatibility aligned with the existing model catalog.
7. Preserve exact targeting policies when targeting itself has not changed.
8. Fresh replaying Markdown subscriptions after cancellation.

Also repair the existing renderer fork's macOS table selection and action labels.
The layout smoke-test harness now waits for actual bounded quiescence instead of
assuming the first observation window after scrolling is already idle.

## Validation and publication

- Add regressions at the real composition boundaries, not only isolated helpers.
- Run focused suites from the checkout owning each change, then an integrated
  selection after all fixes are composed. Report old full-suite evidence separately.
- Independently review the composed correction diff and resolve valid findings.
- Update the fork and each affected upstream slice; verify the final assembled
  upstream tree equals the corrected fork. Keep all PRs in draft until this gate.
- Refresh descriptions with actual validation, isolated comparisons and dependency
  order, then mark ready and monitor CI/bot feedback.

The original full run executed 5,547 XCTest tests (20 skipped) with one transient
layout-settling failure; the subsequent eight-test layout run passed. All 17 Swift
Testing tests passed. Those runs predate these corrections and do not certify them.

Upstream series: #955 Discover, #956 inference, #957 Markdown, #958 Library,
#959 notes, #960 speakers, #961 versions/labels. Notes depends on inference;
speakers depends on notes; the final manager proposal integrates all six.

## Completed validation (2026-09-06)

- Corrected assembled source: 1,579 focused tests, one skip, zero failures.
- Extracted Markdown branch: seven tests passed; notes: 109 passed; speakers:
  323 passed. Prompt corrections: 214 passed in their owning checkout.
- Independent review of all eight corrections and the Markdown dependency patch
  found no additional actionable defect.
- Native table selection regression passes. The accessibility-host test skips
  because its accessibility tree is empty; real VoiceOver validation remains manual.
- `git diff --check` and README reference validation pass. no-mistakes and the
  Greptile CLI are unavailable; automated upstream CI requires maintainer approval.
- The user requested screenshots for all seven PRs. Prepare them from synthetic
  data and obtain user approval before attaching or publishing any screenshot.
