# 0.8.0 Markdown and transcript UI source review

Candidate: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`; comparison `v0.7.3`.

Verdict: one actionable P2 stale-presentation defect identified and repaired in the QA worktree; focused green verification is pending. No additional actionable defect found in the scoped Markdown adapter/export/lifecycle review. This is source evidence, not a GUI reproduction or release approval.

## Scope and method

Reviewed the delta and current implementation of:

- `Sources/MacParakeet/Views/Components/MarkdownContentView.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptTimestampedContentView.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptBodyLayout.swift`
- Relevant MainWindow/meeting-completion call sites, TranscriptResultActions and existing Markdown/context/layout/identity tests.

Read the governing transcript/Markdown sections of `spec/04-ui-patterns.md` and `spec/12-processing-layer.md`. Inspected the pinned local SwiftStreamingMarkdown checkout only to resolve native link interception, table selection, parser execution and resource/accessibility assumptions; no dependency changes or network installs.

Root owns all GUI, builds, tests and user data. This worker performed no app interaction, playback, build, test, preference/clipboard/database write, or GitHub mutation. The only written file is this report. Inventory findings remain in the separate release inventory.

## P2: Previously rendered timed rows remain interactive during a different transcript's detached rebuild

Primary location: `TranscriptResultView.swift:3668–3693`, especially line 3681.

Concrete trigger: display timed transcript A, then let completed meeting B auto-open while its longer timed cache is being built. `AppEnvironmentConfigurer.swift:512–525` selects and navigates to the completed record in the existing Library detail. `MainWindowView.swift:154–175` supplies the new record to the same `TranscriptResultView` structural identity; it does not key the view by transcription ID. `handleTranscriptionChange()` schedules the new cache at lines 586–590 rather than clearing the old timed rows first.

Evidence:

1. `scheduleSegmentCacheRebuild()` captures B's data and assigns a new request ID, then sets only `cachedTranscriptRowCount = nil` before awaiting the detached builder.
2. `cachedSegments`, `cachedIdentifiedTurnCards`, speaker label/stat/color maps and sorted timestamps still contain A until `applySegmentCache()` executes.
3. `timestampedView` at lines 3416–3454 deliberately renders those cached arrays rather than the current word argument. The header and action context already use B.
4. Consequently A's rows remain selectable/copyable under B's header. Timestamp actions reference the current player; speaker rename constructs an old cached speaker ID and invokes the current view model, so a user acting during the window can seek B using A's time or rename B's matching speaker ID using A's displayed identity.
5. The request-ID and active-transcription guards at lines 3691–3692 correctly reject stale *future publication*. They do not invalidate the already-published cache. There is no existing test for the pending-cache presentation across record IDs; rich-context tests cover a separate loader.

Impact: misleading cross-record transcript presentation and potentially wrong-record row actions. This becomes easier to observe with a large B or CPU load. No persisted text loss has been observed; this is not an assertion that every navigation reproduces visibly. Navigating back through the Library list may destroy the view and avoid the trigger, which is why retained-detail replacement is the important case.

Narrow fix: associate published timed-cache data with its transcription ID and suppress/clear rows and speaker stats when that ID differs from the active record; alternatively clear the previous record's cache synchronously when scheduling its replacement. Preserve `nil` row count during preparation so the conservative lazy-layout policy remains intact. Do not globally disable asynchronous preparation, remove late-result guards, or key the entire large detail view solely to work around one cache's ownership.

Suggested focused verification:

- A deterministic suspended cache-builder test: publish A, switch to B, hold B's builder and assert A's rows/actions are unavailable; complete B and assert only B appears; release a late A result and assert it cannot replace B.
- Same-record speaker rename/retranscription update still refreshes labels/timings correctly.
- No-timestamp replacement clears all timed state.
- Real GUI: keep a long timed A open while a second meeting B finishes with auto-open on; verify the title/body/speaker controls always agree and first opening B remains responsive.

## Source-supported checks without additional findings

| Area | Evidence reviewed | Practical boundary |
|---|---|---|
| Markdown subscription lifetime | A retained snapshot store creates one fresh AsyncStream per consumer, replays the latest snapshot and removes cancelled subscriptions. Structured `.task` lifetime and cancellation checks before/after parse prevent a cancelled parser from overwriting a replacement. Existing `MarkdownContentViewTests` cover cancelled/replacement consumers and suspended old parsing. | Actual SwiftUI hide/reopen and streaming animation remain GUI checks. |
| Streaming pressure | A serial loop consumes `.bufferingNewest(1)` snapshots; intermediate queued updates coalesce rather than spawning one parser per token. The pinned async nonisolated parser uses the generic executor; publication returns to MainActor. | Test suite asserts coalescing, not long-output latency or memory on this Mac. |
| Link/image boundary | Images and every image type are disabled. First-party OpenURL policy allows only HTTP/HTTPS. The pinned macOS paragraph view forwards `clicked(onLink:)` through SwiftUI OpenURL, including table cells rendered by the same paragraph adapter. Raw HTML has no WebView execution surface. | Exercise native link/context-menu behavior; a pure URL-policy test is not proof of every AppKit activation path. |
| Table selection/accessibility | Pinned fork removes table-wide macOS tap gestures, uses selectable NSTextView table cells and exposes persistent named Copy/Download buttons. Heading traits and table position values exist in the dependency. | Native drag selection, VoiceOver ordering, keyboard access and width clipping were not executed here. |
| Clipboard and exported payloads | Full result Copy/export uses original `PromptResult.content`; table actions receive normalized table Markdown. Table export writes atomically off MainActor and presents failures visibly. Existing tests preserve bytes and propagate destination failure. | Clipboard ownership and save-panel Cancel/overwrite/error presentation need actual GUI verification. |
| Text and timed layout | Unknown row count stays lazy; <=400 rows uses VStack; >400 stays lazy. Speaker turns split into <=24-segment cards. Existing layout tests host/scroll the real child view and identity tests preserve content and card identity. | Offscreen tests cannot generate pointer-hover redispatch. The test host also does not include every surrounding detail/header element. Root should repeat actual down/up scrolling and mode switching. |
| Rich AI context | One revision/mode/ID-scoped loader shares detached work, invalidates on navigation/disappearance, checks current identity before actions and prevents old prompt ownership from clearing new work. Existing tests use controlled completion ordering. | Separate from the timed display cache finding; no additional source defect found in these context paths. |
| Timestamp accessibility | Timestamp chip remains Text plus a guarded tap gesture; explicit row play actions carry accessibility labels. | This implementation predates v0.7.3; do not claim it as a new regression. Keyboard/VoiceOver quality is still an honest manual coverage gap. |
| Appearance and incomplete Markdown | Configuration maps dynamic DesignSystem colors/fonts, supports selectable content and disables images; parser tests include incomplete emphasis/fences/tables. | Tests mostly establish nonempty output/configuration, not visual fidelity, dark-mode transitions or typography. |

## GUI checklist handed to root

Use invented records and explicit test-owned output destinations:

1. Saved result with headings, nested ordered/unordered lists, task items, quote, inline code, fenced code, wide table, web link, blocked-scheme link and optional math. Compare original source Copy and Markdown export bytes.
2. Drag-select a table cell, copy table, save table, cancel save, and exercise a write error through an owned invalid destination. Confirm visible actionable labels.
3. Inspect the same content in result, saved chat and live Ask widths. Check horizontal table/code scrolling and dark/light appearance changes.
4. Start a streaming result, switch panes, return and confirm continued appended text. Finish/cancel generation and ensure no stale content returns.
5. Timed small/400/401/reporter-scale (>964 segments) transcripts, one speaker and multiple speakers. Scroll bottom/top with the pointer over rows, select text, use find, seek, change reading size, rename a speaker and switch text/timed mode.
6. The retained-detail A→B cache trigger above, including an explicit builder delay in deterministic coverage if root implements the narrow repair.

## Methodology notes

What worked: inspect view identity and event ownership in callers before deciding that async publication guards solve stale UI; compare the v0.7.3 implementation to avoid filing inherited accessibility limitations as new regressions; inspect the pinned dependency only at native boundaries instead of assuming the adapter's configuration proves runtime behavior.

What did not suffice: policy/configuration tests cannot certify native selection or accessibility; offscreen scrolling cannot reproduce actual hover feedback; green parser tests do not establish rendering performance; a guarded future write does not prove old displayed state belongs to the current record.

## Repair checkpoint: regression extraction awaiting root gate

The approved repair is now being implemented in the QA worktree. The initial checkpoint extracts the existing scattered timed-cache state into a transcript-specific value in `TranscriptResultView.swift` without correcting its stale-display behavior. Four deterministic `TranscriptSegmentCacheTests` cover pre-rebuild A→B display, B pending with late A completion, same-record replacement ordering, and untimed clearing. No sleeps, desktop events or user data are involved. The root agent owns execution; source/tests are frozen awaiting its behavioral red result. No test pass or completed repair is claimed at this checkpoint.

## Observed red and implemented correction

Root executed the combined focused gate at 2026-09-07 15:18 local time; this worker read its log at `/tmp/macparakeet-080-qa/evidence/cache-red-recovery-green.log`. Build completed successfully. Of 89 selected tests, all 85 recovery tests passed. The cache family ran four tests: the two A→B tests failed six behavioral assertions showing A's snapshot/count exposed for B, while same-record refresh ordering and untimed clearing passed. This was an executed behavioral red, not a missing-symbol compilation failure.

The correction now clears the published snapshot when a different transcription starts preparation and guards snapshot/row-count reads by the caller's active transcription ID. That read guard also covers the render before SwiftUI runs `onChange`. Unknown/pending row counts remain nil; same-record refresh may retain its own rows until replacement, and both active-record and latest-request publication checks remain. All cached row text, speaker cards, labels, stats, colors and seek anchors come from the same guarded snapshot.

No tests/builds were run by this worker. Production and test files are frozen for root's focused green gate. Runtime A→B GUI observation remains separate from deterministic cache coverage.
