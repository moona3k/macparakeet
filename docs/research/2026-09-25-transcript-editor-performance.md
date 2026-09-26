# Long-meeting transcript editor responsiveness

## Scope

Opening **Edit** in the Text view should not construct a native editor for every
passage in a long meeting. Typing should update the active passage without
rescanning the entire transcript or invalidating the transcript detail view.

Keep passage identity, timing envelopes, the immutable automatic transcript,
remove/restore, whitespace normalization, Cancel, and one atomic `reviseText`
save. Preserve the existing save token and transcription-identity checks.
The follow-up audit below covers other detail tabs. Read-only Text/Timed layout
policy and correction persistence remain unchanged.

## Findings

The reading editor introduced for #1069 uses an eager `VStack` with a multiline
SwiftUI `TextField` for every effective segment. Unlike the timed reading
surface, this editor has no long-transcript virtualization. Draft preparation
only copies segment identity and strings; it does not resolve attribution,
read audio, or hash the recording per passage.

Every field binds through a single `[TranscriptReadingDraft]` state property in
`TranscriptResultView`. Typing therefore invalidates the large parent view.
Its Done button calls `TranscriptReadingEdit.command(for:)` while rendering,
trimming and comparing every draft and allocating a correction command merely
to determine whether any changes exist. The full command is needed only at save.

The earlier #1132 archive-duration issue is a distinct path: current `main`
already memoizes the presentation engine metadata. It does not explain the
editor's eager field creation and whole-session typing invalidation.

## Verification

A native `NSHostingView` regression uses 1,600 synthetic six-word passages
(9,600 words) inside the same ScrollView / outer VStack structure as the
transcript pane. Count actual editable native fields after layout rather than
relying only on a noisy wall-clock threshold. No private recording or transcript
is copied into tests or diagnostics.

Measurements and final validation are recorded below after execution.

## Implementation choice

Use a lazy stack only for the reading editor. Keep the existing read-only
selection/layout policy intact; the editor uses native text fields, not the
per-row selectable Text overlays implicated in earlier timed-view regressions.

A session owns stable observable passage objects, retaining all drafts even
when their views are recycled. Each passage uses the existing correction
builder to determine its own change status. Only clean/changed transitions
adjust the session's count; the public `hasChanges` flag changes only when the
session crosses between zero and nonzero changes. Continuing to type into an
already edited passage does not invalidate the parent or other passages.
The full ordered command is assembled only for Done.

This keeps the current passage editing interaction and timing guarantees.
A single freeform document would require a new way to map arbitrary edits back
to timed segments. That is unnecessary to remove the demonstrated eager layout
and update costs, and would add correctness risk.

## Measured results (macOS 26.6.2, debug build)

| 1,600 six-word passages, 900 × 650 native window | Original editor | Fixed editor |
| --- | ---: | ---: |
| Native editable fields after first layout | 1,600 | 15 |
| First layout, including a 100 ms run-loop pump | 2.469 s | 0.325 s / 0.273 s |

The fixed measurements also include session initialization. These are local
samples on a shared development machine, not release-build latency guarantees.
The regression asserts a bounded field count rather than a fragile time ratio.
The original implementation failed that assertion before the fix. The two
fixed samples include an initial test-harness iteration: its scroll assertion
needed to account for changing lazy height estimates, and its temporary last-row
edit needed to be reset before comparing the final command. The completed test
passes and verifies the final passage actually becomes visible on each cycle.

All 32 focused tests passed: native layout and multiline field-editor binding,
edit-session state/observation, existing reading-command behavior, correction
service persistence, and correction view-model ownership. Independent
correctness and maintainability reviews found no production defects; their
multiline/recycling coverage suggestions were incorporated. Changed standalone
Swift files pass swift-format lint. The final full-suite and hosted CI results
are recorded in the PR.

`no-mistakes` is not installed in this shell, so validation follows the
repository's documented tests, local Greptile, independent review, and CI path.
No Jev step is needed: this change makes no semantic classification or routing
decision. Native tests use direct AppKit field-editor input. They do not prove
physical keyboard/IME interaction, the user's actual recording, or signed-release
behavior.

## Follow-up: other transcript/detail tabs

The expanded review covered Text reading, Timed reading/editing, Notes,
Summary/Chapter/custom results, Chat, and their shared Markdown renderer.
Keep saving, cancellation, conversation ownership, selection behavior, and
on-device data unchanged. Fix measured costs or layout defects instead of
replacing every stack with a lazy layout.

| Surface | Finding and disposition |
| --- | --- |
| Text reading | A single selectable Text is bounded at a 500 pt viewport with 10,000 words and settles after scrolling. No production change. |
| Timed transcript | Existing eager/lazy threshold (400) and speaker-card cap (24) already bound long transcripts while preserving short-transcript selection. All 10 existing native layout smoke cases passed, including 964 single-speaker segments and 10,000 flat segments. No production change. |
| Notes | A separate concurrent Notes workspace refinement already removes nested cards and gives the native editor available height. Reviewed that change and its native fixture report; left its ownership with that branch. Existing saved-note view-model tests pass here. This branch does not deliver the separate Notes changes. |
| Saved results | The outer ScrollView constrained TextEditor to 280 pt even when the window grew 300 pt. A flexible pane now keeps wrapping actions above a scrolling Markdown body or a native editor that owns its scrolling. |
| Chat | The model mutated its observable message array for every token despite downstream Markdown buffering. A 1,000-token burst caused 1,001 message-array publications. Use the existing 33 ms StreamingTextCoalescer before publication, preserve all authoritative tokens, and flush complete text on success. |
| Shared Markdown | Existing serial latest-snapshot renderer and cancellation ownership are sound. Long parsed documents, wide code, and 12-column tables remain inside 500/900 pt panes and settle after scrolling. No renderer change. |

### Follow-up evidence

- The Chat regression failed at 1,001 publications before the fix; the fixed
  run measured **3**, with identical complete UI and persisted content. Buffered
  provider failures and cancellation discard the response and never persist its
  tail. Existing conversation detachment, replacement, Stop, and persistence
  tests pass.
- A test hosts the actual `TranscriptResultView` with synthetic model state and
  isolated UserDefaults. Before the fix its saved-result editor stayed
  **280 → 280 pt**; after the fix it grows **273 → 573 pt** when the window
  grows 650 → 950 pt. It also checks a compact 500 pt pane and return to reading
  without modifying the saved result. Native compact captures were inspected.
- Long Markdown first layout took **0.37–0.55 s**, including a 100 ms run-loop
  pump; the 10,000-word selectable Text took **0.94–0.97 s**. These shared-machine
  debug samples are observations, not latency guarantees. Tests assert bounds
  and eventual quiet layout, not those timings.
- 154 focused tests passed across Chat, publication, coalescing, saved results,
  saved Notes, and native document layouts before adding the two buffered-error
  cases; the six final new publication/document cases also pass. The PR records
  the final full-suite and hosted checks separately.
- Independent correctness and maintainability reviews found no production
  defects. Their suggestions led to buffered-error/cancellation tests and
  compact full-pane checks.

Renderer tests await parsing before hosting `DocumentView` with the app's
configuration. They cover the common rendering layer, not every whole-tab
interaction. The full saved-result pane test does cover actual production view
composition. No private meeting, live provider, physical keyboard/IME, or signed
release behavior was exercised. No Jev step was needed.
