# Rebuilt 0.8.0 GUI verification

The initial rebuilt pass exercised an isolated copy of the signed distribution bundle at `3827999ddb84c8a8e0edcb3ac190e66813fc95fe`, after the recovery, displayed-row cache and Sparkle fixes. The unique bundle identifier was `com.macparakeet.qa.release080`; the real open database path was checked with `lsof` before destructive actions. This build predates the later integration of saved meeting notes from PR #959.

## Initial rebuilt pass at `3827999d`

- ALPHA → BRAVO → ALPHA → BRAVO navigation displayed only the active record's distinguishing words and speaker. Timed mode was explicitly selected for each newly opened detail screen; it is not persisted across these navigation transitions. Snapshot sampling cannot force the asynchronous replacement race; deterministic cache tests provide that coverage.
- The synthetic 10,000-word transcript opened in Timed mode with both speakers and 5,000 words per speaker. Moving its native scroll bar to the bottom made sentence 1000 and timestamp 66:36 visible. No blank final region or missing final sentence was observed. This is a functional check, not a scroll-framerate benchmark. Synthetic speaker fixtures do not include complete duration statistics, so their overview duration is zero.
- The saved summary rendered headings, bold/italic/inline code, a three-column table, highlighted JSON, a quote, numbered items, task items, links and the final marker. Scrolling reached the final marker.
- Whole-summary Copy exactly matched the stored Markdown string. Copy table contained all fixture rows. All pasteboard item types were backed up locally and restored in `finally` blocks; original clipboard content is excluded from the repository.
- The saved chat rendered its rich Markdown reply without configuring or changing a provider. These are seeded saved results, not live inference or streaming evidence.

[Inspected screenshots and receipts](evidence/gui-rebuilt/manifest.json), [check results](evidence/gui-rebuilt/results.json).

| Surface | Screenshot |
| --- | --- |
| Rich summary/table | [Top](evidence/gui-rebuilt/updated-markdown-preview.png) |
| Code, list and final marker | [Bottom](evidence/gui-rebuilt/updated-markdown-bottom.png) |
| Saved chat | [Chat](evidence/gui-rebuilt/updated-chat.png) |
| Active ALPHA content | [ALPHA](evidence/gui-rebuilt/updated-timed-alpha.png) |
| Active BRAVO content | [BRAVO](evidence/gui-rebuilt/updated-timed-bravo.png) |
| Long transcript overview | [10,000 words](evidence/gui-rebuilt/updated-timed-long-top.png) |
| Last timed sentence | [Sentence 1000](evidence/gui-rebuilt/updated-timed-long-bottom.png) |

## Combined saved-notes build at `250bbe29`

The later isolated GUI copy used source `250bbe2994a4b60b4ef81ac257f0ee6bb70874d3`, version `0.8.0`, build `20260907232424`. Root repeated whole-summary and table copying successfully: the complete summary matched the stored Markdown and the table included every fixture row. The [current Copy receipt](evidence/gui-rebuilt/copy-controls-current.json) preserves both passes. Its code-block entry is `passed: false` because the expected clipboard result was not verified; this records an unsuccessful verification attempt, not a confirmed general product failure.

Root also completed all six [saved-notes GUI checks](saved-notes-gui.md): autosave, navigation, revision preservation, ordinary quit, relaunch and `notes.md`, with the raw transcript unchanged. The clean [autosaved](evidence/gui-rebuilt/notes-autosaved-current.png) and [reopened](evidence/gui-rebuilt/notes-reopened-current.png) screenshots show this later source. The earlier ALPHA/BRAVO/LONG and rich-rendering screenshots retain their `3827999d` provenance; they were not relabeled as final-build captures.

The [manifest](evidence/gui-rebuilt/manifest.json) now records each file's candidate explicitly. Only approved synthetic/public screenshots and Boolean/synthetic-note receipts were added. Raw clipboard content, backups, private input and raw AX trees remain excluded.

## Automation findings and limits

AX actions on several SwiftUI tab labels returned success without changing the selected tab. A targeted mouse click followed by a fresh tree and screenshot established the actual change. AX page-scroll actions were advertised but returned unsupported/action errors on these scroll views. Numeric `AXValue=1` on the native scroll bar reliably reached the bottom; passing a string instead is not equivalent.

The code-block Copy label did not yield verified clipboard content using repeated targeted clicks, including normal click-count, mouse-down duration and later stable-attribute action targeting on `250bbe29`. At the pinned SwiftStreamingMarkdown revision, the control is `Text.onTapGesture` with an accessibility button trait but no accessibility activation action; its icon has no action. That explains the absent AXPress route but does not by itself establish why targeted clicks failed. The failed attempt remains **unverified**, with a dependency accessibility follow-up; full-result and table copying are verified workarounds. No dependency replacement was introduced during release QA.

The HTTPS and file links were rendered but not opened during this pass. Static saved chat does not prove generation, provider errors or streaming. Some captures show an inactive app window while background hardware verification ran; the displayed fixture content and selected state were inspected.

The notes rerun established that stable attribute selection inside the actuating process avoids AX-index drift. Startup checks must wait for the actual alert/window state. The first notes attempt interrupted by user input is invalidated and excluded; the later completed pass has its own receipt.
