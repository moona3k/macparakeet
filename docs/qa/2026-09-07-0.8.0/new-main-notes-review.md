# Saved meeting notes: new-main impact review

Reviewed on 2026-09-07. This is a source and existing-CI review, not a GUI execution report. The reviewer ran no Swift build, test, inference, or desktop operation and changed only this report.

**Verdict:** no actionable defect confirmed in the saved-notes UI/model ownership paths reviewed. The integration resolution also passes the source comparison below. The added feature still needs GUI evidence on the combined release candidate; earlier screenshots and the earlier full suite do not cover this new main delta.

## Exact revisions and prior PR evidence

| Item | Observed value |
| --- | --- |
| Earlier main / release GUI baseline | `8548c099af5ee2ab0ed4dd9efe757d85c498cca0` |
| New main | `c14b1ed43543dde1e73805f48bbabfcb4e03909d` |
| Merged PR | [#959 — Autosave saved meeting notes and capture explicit prompt context](https://github.com/moona3k/macparakeet/pull/959) |
| PR author | `alfred-sa` |
| PR final head | `8fa552d3c26ea27b79a1f871caf8fcb7f509e5c5` |
| Merge time | `2026-09-07T23:13:58Z` |
| New-main delta | 54 files; 5,269 insertions and 233 deletions |
| Combined QA merge reviewed | `250bbe2994a4b60b4ef81ac257f0ee6bb70874d3` |

The new-main merge parents are the earlier baseline and the exact PR head above. GitHub's [CI run 34166760222](https://github.com/moona3k/macparakeet/actions/runs/34166760222) completed successfully at that PR head. Its [swift-test job](https://github.com/moona3k/macparakeet/actions/runs/34166760222/job/101879267574) reports successful release build, CLI contract smoke, release bundle smoke, concurrency safety, Swift 6 language mode, and Swift Test steps. The log reaches `[5552/5552]` parallel XCTest items and reports 29 Swift Testing tests passed. The progress denominator is not a verified non-skipped XCTest pass count; this review did not derive a skip inventory from that CI log.

All 43 review threads were resolved when queried, with no remaining GraphQL page. Exact-head check runs include successful `swift-test` and a completed, neutral `cubic · AI code reviewer`. The PR check rollup also reports CodeRabbit success. `reviewDecision` is empty and exact-head submitted reviews are `COMMENTED`, including [the owner's final review entry](https://github.com/moona3k/macparakeet/pull/959#pullrequestreview-5135549242); this is not evidence of a formal `APPROVED` review. Earlier bot summary comments reference older commits and were not used as an exact-head verdict.

Evidence was obtained with read-only `gh pr view`, commit check-runs, PR reviews/review-thread queries, `gh run view --json`, and the existing run log. No GitHub state was changed.

## Ownership and regression review

All source line references in this section are to new main `c14b1ed4`, before the QA merge's line shifts.

| Path reviewed | Evidence and conclusion |
| --- | --- |
| Draft lifetime and selection | `SavedMeetingNotesCoordinator.swift:21` retains editors by meeting ID while database or deferred artifact work is pending; clean editors can be recreated from the current row. `SavedMeetingNotesViewModel.swift:45` scopes both binding reads and writes to the displayed meeting ID. `TranscriptResultView.swift:4031` binds the new editor immediately and flushes the previous retained editor separately. No previous-meeting binding leak identified. |
| Autosave and flush ordering | `SavedMeetingNotesViewModel.swift:114` shares in-flight persistence/flush work, drains edits made during awaits, and guards reconfiguration with a token. Database saves debounce for 500 ms; derived files refresh at explicit flushes. Existing tests cover debounce, slow saves, overlapping flushes, reconfiguration, and failures. |
| Navigation and AI actions | `TranscriptResultView.swift:242` defines a request-owned action gate. Prompt, chat, and navigation callers retain the initiating editor and check current selection after flushing. Prompt context captures the revision after notes commit and rejects a subsequent unsaved edit. Disappearance invalidates actions while separately flushing the retained draft. Chat also checks conversation ID and input text. No obsolete-action publication identified. |
| Normal quit | `AppDelegate.swift:429` defers termination through the shared coordinator, preserves failure drafts, and resumes the existing live-recording confirmation after successful notes persistence. `SavedMeetingNotesCoordinator.swift:53` rechecks drafts added or edited while awaiting saves. This source review does not establish actual AppKit modal/termination behavior. |
| Missing row and failed read | `SavedMeetingNotesViewModel.swift:172` retires a draft only after an authoritative successful deletion check; read errors retain it. `TranscriptionRepository.swift:583` reports a missing row instead of inserting it. The open editor can retain deleted text for copying while disabling further edits. |
| User metadata during transcription | `TranscriptionRepository.swift:182` merges current user metadata and saves in one GRDB write transaction; a missing row throws. `TranscriptionService` and retranscription completion use that path. Notes, title/favorite, chat, and retained-audio paths are taken from the current row rather than an old processing snapshot. |
| Notes error ownership and artifacts | `TranscriptionViewModel.swift:1602` serializes notes persistence, tracks save errors per meeting/request, and distinguishes a committed write from a failed read-back. `:2094` serializes notes/title/speaker artifact refreshes per meeting and refetches canonical data before materializing. Artifact failure remains separate from the saved database state. |
| Prompt preferences and receipts | `PromptLibraryView` exposes the checkbox for result prompts, including built-ins. Migration `v0.33-prompt-meeting-notes-context` defaults both additive Boolean columns to false. The shared assembler caps only effective notes, avoids automatic duplication when `{{userNotes}}` is present, and records the exact supplied note snapshot. Retry preserves the failed request's snapshot; regeneration uses current notes with the saved preference. Legacy missing JSON keys default false; null/malformed values are intentionally rejected. |

The existing deterministic tests cover the principal failure scenarios above. Their presence was inspected; this reviewer did not execute them. Root subsequently reported **694 focused tests passed on combined commit `250bbe29`**, including the recommended notes/cache/recovery families, plus a successful Xcode Release build. Those are root-executed results and should be cited through the root's gate evidence when presenting the final release verdict.

## Integration resolution

**PASS for the resolution at `250bbe29`.** Its parents are `578bd14f1fbfb15e2b455ef4d64893249c4bbde0` and `c14b1ed43543dde1e73805f48bbabfcb4e03909d`.

The combined diff in `TranscriptResultView.swift` retains the QA branch's ID-scoped `TranscriptSegmentCache` and the new-main notes action gates. The adjacent insertion at the segment-cache section retains both the computed cache properties and the new `handleDisappear` method.

A read-only Python comparison of `git show` contents passed seven assertions:

1. The computed cache-property block exactly equals the first parent's block.
2. The disappearance handler exactly equals the second parent's handler.
3. The cache rebuild/publication section exactly equals the first parent's section.
4. Exactly one `handleDisappear` definition exists.
5. Exactly one `.onDisappear(perform: handleDisappear)` hook exists.
6. The previous unscoped `@State private var cachedSegments` storage was not restored.
7. All three notes action-gate state properties remain present.

This confirms the resolution introduces no changes to either compared implementation. The reviewer authored the earlier cache fix, so this is a merge-resolution comparison, not an independent re-review of that fix's design. Independent cache review and root's combined runtime/test evidence remain the applicable gates.

## Focused test coverage to include

Use these families when validating the combined candidate; root owns their scheduling and execution. There is no request here to repeat a passed gate without a new change or unresolved concern.

| Area | Families |
| --- | --- |
| Draft, navigation, quit, stale action | `SavedMeetingNotesViewModelTests`, `SavedMeetingNotesCoordinatorTests`, `TranscriptNotesActionGateTests`, `TranscriptResultTabOrderingTests` |
| Database/UI publication and completion | `TranscriptionViewModelTests`, `TranscriptionRepositoryTests`, `TranscriptionServiceTests` |
| Preferences, migration, JSON compatibility | `DatabaseManagerTests`, `PromptRepositoryTests`, `PromptsViewModelTests`, `PromptCodableCompatibilityTests` |
| Prompt context and receipts | `PromptResultsViewModelTests`, `PromptTemplateRendererTests`, `PromptsCommandTests`, `MeetingsCommandTests`, `MeetingArtifactStoreTests` |
| QA-fix integration | Existing `TranscriptSegmentCacheTests` and the focused recovery/lock/retention families already selected by root |

Specific useful assertions already present include edits during a pending quit; failed writes versus confirmed deletion; another meeting's queued save not hiding the visible meeting's error; notes artifact refresh waiting for title/speaker rename; retranscription preserving concurrently edited metadata; token-plus-checkbox avoiding duplication; and retry retaining an exact capped receipt.

## GUI additions for the combined build

Use the isolated QA application/database and existing public-speech **meeting** records from [microphone-runtime.md](microphone-runtime.md). The ALPHA/BRAVO/LONG fixtures in [gui-fixtures.md](gui-fixtures.md) have `sourceType=file` and correctly do **not** display Notes. Root can use the completed public-speech meeting and the other owned meeting for A/B selection. No new audio capture or provider configuration is required to verify editing.

Record the running app's source/binary provenance before these actions; baseline `8548` screenshots cannot stand in for them.

| Action | Expected observation and durable check |
| --- | --- |
| Open a completed meeting with AI unconfigured | `Transcript`, then `Notes`, remain available. Notes exposes the accessible editor label `Meeting notes`, automatic-save hint, word count, and `Saved` state. A file transcript has no Notes tab. |
| Enter `QA080 notes A — decision: publish after verification.` and a second line | The plaintext editor preserves punctuation/newlines, changes to `Saving…`, then `Saved` after the idle debounce. Read-only DB inspection shows the exact value on that meeting's `userNotes`, with transcript fields unchanged. `Copy your notes` copies the editor text. |
| Type a new suffix and immediately select Transcript or Back | Navigation finishes after the latest database save. Reopening Notes shows the suffix. At the explicit flush, owned `notes.md`/meeting artifacts should reflect the current DB notes. A debounce-only save need not refresh them yet. |
| Type in meeting A and immediately open meeting B, then return to A | B never exposes A's notes and each row keeps its own value. Returning to A recovers its newest draft/committed text. Repeat using A → file fixture → A to cover the non-meeting editor reset. |
| Type a final suffix and immediately quit normally; relaunch | Normal quit waits for persistence; reopening the same meeting restores the final suffix. Verify only the isolated QA record and its sidecar. This does not prove crash durability between the keystroke and the debounce. |
| Clear all notes or enter whitespace, then leave/reopen | Canonical `userNotes` becomes NULL and the editor reopens empty; transcript text remains unchanged. Use only the owned QA note fixture for this destructive content edit. |
| Open the result Prompt Library | Existing built-ins and new custom prompts default the checkbox off. Expanded built-ins allow toggling notes context while prompt text remains read-only. A custom prompt's change survives Save/reopen; Cancel/discard handling preserves the saved preference. Check the checkbox label and card badge at the supported window size. |
| Type notes and immediately run a configured local test prompt/chat action | The captured request contains the latest committed notes according to the prompt checkbox/token rules; chat uses the current committed notes without that checkbox. Switching meeting/chat or changing input during preparation must not send the obsolete action. If no isolated provider capture is configured, report this as test-backed, not live-provider-verified. |

Failure and stress checks can remain deterministic-test evidence unless root has an isolated runtime harness: persistence failure with Retry/Keep Open, row deletion while a draft is pending, sidecar failure independent of DB success, simultaneous live-recording quit confirmation, and 8,001-word truncation receipts. Do not manufacture failures in a user database or remove meeting audio to simulate them.

No screenshot, keyboard accessibility, real provider request, save-failure dialog, or AppKit quit behavior was executed by this reviewer. The checks above are additions to the release methodology, not completed GUI passes.
