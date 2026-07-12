# Plan: Transcript Detail Refresh (media-document reading)

> **Executor instructions**: This is the audit's "Move 1" (highest daily-use UI
> value, lowest product ambiguity) from
> [`docs/research/open-source-ui-reference-audit-2026-05.md`](../../docs/research/open-source-ui-reference-audit-2026-05.md).
> The goal is to make `TranscriptResultView` read like a first-class **media
> document** (text-first, time-aware, quiet persistent playback) — not to turn
> it into a Descript-style editor. **Much of Move 1 already ships** (persistent
> `AudioScrubberBar`, auto-scroll-to-active-segment, tap-to-seek, active-line
> highlight, text selection). This plan only closes the genuine gaps and breaks
> up the god-file as it goes. Ship Phase 1 first; it is self-contained and
> view-only.
>
> **Drift check (run first)**:
> ```bash
> git fetch origin
> git diff --stat origin/main -- \
>   Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift \
>   Sources/MacParakeet/Views/Transcription/TranscriptTimestampedContentView.swift \
>   Sources/MacParakeet/Views/Components/AudioScrubberBar.swift \
>   Sources/MacParakeetViewModels/MediaPlayerViewModel.swift
> # Re-confirm the "already exists" claims below before building; if any have
> # changed since 672ee1028 the scope below may already be partly done.
> ```

## Status

- **State**: **ON HOLD** — shipped work stays as-is; remaining architecture and
  layout work waits for the future transcript UI revamp.
- **Priority**: P2
- **Effort**: L (staged; Phase 1 is S)
- **Risk**: MED overall — LOW for Phase 1, MED for the find-bar and the
  video-mode rail unification (layout-touching).
- **Depends on**: none. Soft-sequences *after* any in-flight
  `TranscriptResultView` edits to avoid churn (drift-check first).
- **Category**: ui, transcription, library, view-decomposition
- **Planned at**: commit `672ee1028`, 2026-06-28

### Progress

- **Phase 1 — DONE** (commit `e91ca2699`): U1 per-segment hover actions + U4
  reading font-size. `swift build` + full `swift test` green.
- **U2 in-transcript find — DONE** (this branch): testable `TranscriptFindModel`
  (`MacParakeetViewModels`, 17 unit tests) + pinned `TranscriptFindBar` (modeled
  on `SettingsSearchField`, ⌘F focus / ⌘G·⇧⌘G nav / Esc clear-then-close /
  "X of Y" counter) + shared `TranscriptFindHighlight` (`AttributedString`
  accent wash, current match bolded). Works in **both** Timed (per-segment rows,
  scroll by `startMs`) and Text mode (paragraph blocks anchored by line index).
  Find-navigate sets `autoScrollPaused` so playback-follow doesn't fight it.
  Verified: default build, Swift-6 language-mode gate, full `swift test` all
  green. Live GUI eyeball deferred (concurrent agent sessions on this Mac steal
  GUI focus).
- **Remaining**: U3 (one quiet rail in every mode), U5 (finish god-file
  decomposition).

### Architecture decision — 2026-07-09

**Keep the current implementation as-is. Do not execute U3 or U5 as a
standalone architecture refactor.** A fresh deep-module review found real
locality friction in `TranscriptResultView`: find navigation, playback
following, scroll arbitration, and derived transcript caches still coordinate
inside the view. It did not find a current correctness problem that justifies
paying the migration risk now.

A broader transcript UI revamp is expected later. Refactoring the current
interaction shape before that design exists would likely create two migrations:
first into an abstraction shaped around today's UI, then again around the new
UI. The meaningful time to revisit the seam is when the revamp defines the next
reader interaction model.

When that work starts:

- Re-run the drift check and characterize the existing find, seek, active-line,
  auto-scroll, manual-scroll-pause, and transcript-change behavior first.
- Prefer one concrete internal transcript-navigation module only if the new UI
  needs it. Do not begin with a protocol hierarchy, generic reader framework,
  or speculative adapters.
- Keep the candidate seam narrow: find/playback/auto-scroll/cache coordination.
  Prompt results, chat, export, editing, retranscription, STT, persistence, and
  meeting finalization remain outside it.
- Require a deletion-test win: the change must materially remove state and
  coordination knowledge from `TranscriptResultView`, not merely relocate the
  same code behind a wider interface.
- Ship the architecture change with the UI slice that needs it, in small
  behavior-preserving steps with focused tests.

This is a deferral decision, not a rejection of the future transcript revamp or
of eventual decomposition. The shipped U1/U2/U4 behavior remains supported.

## Why this matters

The transcript detail view is where users land after every file/URL/meeting
transcription — the highest-traffic surface in the app and the moment the audit
frames as "Can I use the transcript effortlessly after it finishes?" Today it
reads like a document page with playback bolted on. Closing the four gaps below
(hover actions, in-transcript search, a consistently-present quiet rail, and
calmer reading density) makes the daily payoff feel finished without adding
product surface area. It also forces a first real decomposition of the
3,166-line `TranscriptResultView` god-file, which every future transcript change
has to fight.

## Summary

Reference-anchored (we looked at these directly): **Descript** — the transcript
*is* the primary surface, media follows the text; **IINA** — playback lives in a
*quiet, hover-revealed rail* woven into the chrome, not a loud control box;
**iOS Apple Podcasts** — calm, readable, line-synced reading (note: *macOS*
Podcasts shows static text, so the synced-reading bar is the iOS reference). Our
view already has the synced split-pane, active-line highlight, tap-to-seek, and
auto-scroll. This plan adds: per-segment **hover actions** (play-from-here, copy,
copy-with-timestamp), **in-transcript find** (⌘F, match highlight, next/prev),
a **quiet playback rail that is always present** (today it is missing in
video-split mode because transport is trapped inside the video frame), and
**reading-density polish** (calmer rows + optional font-size). Each unit
extracts its slice out of the god-file behind a characterization test.

## Scope

### In scope
- Per-segment hover-revealed actions on timestamped transcript rows.
- In-transcript search/find with match highlight and keyboard navigation.
- A single quiet playback rail present in **all** playback modes (including
  video-split), so transport controls are never trapped inside the video frame.
- Reading-density polish: quieter rows for long-form reading + an optional,
  persisted font-size control.
- Incremental, behavior-preserving extraction of the transcript reading pane and
  segment row out of `TranscriptResultView.swift`, each guarded by a
  characterization test.

### Out of scope
- Descript-style **edit-media-by-editing-text** / waveform timeline. We are not
  a media editor; do not build it.
- **Word-level karaoke** highlight. We highlight at segment granularity today;
  word-level is a deferred stretch (see follow-up), partly blocked by data
  (segment timing only — see Invariants).
- Decorative **waveform behind transcript text** and making the transcript
  **card-heavier** — the audit explicitly warns against both.
- Changes to the **Summary / Chat** tabs, export, retranscribe, or meeting
  artifact menus beyond moving code during extraction.
- Cross-meeting / library-wide search (tracked in the meetings-workspace plan).

### Invariants
- **Preserve existing playback behavior**: tap-to-seek (`onTimestampTap`),
  active-segment binary-search highlight, auto-scroll-to-active with the 5s
  manual-scroll pause + >2s seek re-sync, and `.textSelection(.enabled)` must
  all keep working unchanged.
- **Segment timing is start-only.** `TranscriptSegment` has `startMs` and
  **no `endMs`** (`Sources/MacParakeetCore/Utilities/TranscriptSegmenter.swift`).
  Any "current word/segment range" or copy-with-timestamp derives the end from
  the *next* segment's `startMs` (or media duration for the last). Do not invent
  an `endMs` on the model for this feature.
- **All three playback modes keep working**: `.video` (YouTube + sourceURL or
  video file), `.audio` (audio file), `.none` (meeting/local with no media).
  Respect `MediaPlayerViewModel.detectPlaybackMode`. The webm/opus→m4a transcode
  path stays intact (AVFoundation can't decode webm/opus — see
  [[reference_avplayer_codec_limits]]); do not surface a dead transport for
  `.none`.
- **Local-first**: search and all reading affordances are fully offline; no
  network calls added.
- **Coral discipline**: never `.tint(coral)` at hosting roots/sheet wrappers;
  coral cascades only through `parakeetAction`. Use `DesignSystem` tokens
  (`accent`, `surfaceElevated`, `Animation.hoverTransition`, etc.).
- **Swift 6 language-mode clean**; new view-logic that is testable lives in
  `MacParakeetViewModels`, not the view.

## Key technical decisions

- **Extend, don't reinvent.** `AudioScrubberBar` already implements a quiet rail
  (play/pause, scrub, time, drag-to-seek) and is shown in `.audio`/video-hidden
  modes. Promote it to the single playback rail and make it present in
  `.video` mode too, rather than authoring a new control. Keep the video panel
  for the picture; move/duplicate transport into the rail.
- **Find logic is a testable model, not view code.** Add an `@Observable`
  `TranscriptFindModel` in `MacParakeetViewModels` that takes the segment array
  (or flowing text) + query and produces an ordered match list
  (`segmentIndex`, `Range`), `current`, `next()`, `prev()`. The view only
  highlights (`AttributedString`) and `scrollTo`. This keeps the matcher unit-
  testable and out of the god-file. Model the *field* on `SettingsSearchField`
  (capsule, ⌘F focus, results-as-you-type, clear button), but it is a new
  component (`TranscriptFindBar`) — no reusable FindBar exists today.
- **Hover actions reuse the established pattern** (`@State isHovering` +
  `DesignSystem.Animation.hoverTransition` 0.12s, opacity-gated, never reserve
  space at rest) used by dictation-history rows and chat bubbles. Add them to
  the segment row, not the timestamp chip.
- **Decompose opportunistically.** Each unit extracts exactly the slice it
  touches (segment row, reading pane) behind a characterization test, instead of
  a big-bang refactor of all 3,166 lines.

## High-level design

```
TranscriptResultView (shrinking shell: header card + tabs + action bar + layout)
│
├─ adaptiveLayout (.video split | .audio/.video-hidden | .none)
│   └─ PlaybackRail  ◀── U3: AudioScrubberBar, now present in ALL modes
│
└─ TranscriptReadingPane  ◀── U5 extraction target
    ├─ TranscriptFindBar         ◀── U2 (⌘F)  ── highlights + scrollTo
    │     observes TranscriptFindModel (MacParakeetViewModels)  ◀── U2 testable
    ├─ density / font-size control ◀── U4
    └─ TranscriptTimestampedContentView
          └─ TranscriptSegmentRow  ◀── U5 extraction + U1 hover actions
                (timestamp chip · text · hover: ▶ from here · ⧉ copy · ⧉+time)
```

Existing wiring to reuse verbatim: `MediaPlayerViewModel.seek(toMs:)`,
`.currentTimeMs` (10 Hz), `isSegmentActiveBinarySearch`, the `ScrollViewReader`
auto-scroll `onChange(currentTimeMs)`, and `formatTimestamp(ms:)`.

## Implementation units

Recommended order: **U1 → U4 → U2 → U3**, with **U5** extractions folded into
whichever unit first touches that slice. U1+U4 are Phase 1 (ship together,
view-only, low risk).

### U1. Per-segment hover actions
- **Goal:** On hover over a timestamped segment row, reveal three quiet actions:
  **Play from here**, **Copy text**, **Copy with timestamp**. Mirrors the
  audit's "play from here / copy text / copy with timestamp" line.
- **Dependencies:** none (seek + formatter already exist).
- **Files:** `TranscriptTimestampedContentView.swift` (segment + turn rows);
  new `Sources/MacParakeet/Views/Transcription/TranscriptSegmentRow.swift`
  (extract the per-segment row here — U5 slice); read pattern from
  `DictationHistoryView` hover rows.
- **Approach:** Add `@State isHovering`; gate a trailing `HStack` of borderless
  icon buttons with `.opacity(isHovering ? 1 : 0)` +
  `.animation(DesignSystem.Animation.hoverTransition, value: isHovering)`; do
  not reserve layout at rest. Wire: Play→`seek(toMs: startMs)` then play if
  paused (same as `onTimestampTap`); Copy→`segment.text`; Copy-with-timestamp→
  `"[\(formatTimestamp(ms: startMs))] \(segment.text)"`. Add `.help(...)`
  tooltips. Keep the existing tap-to-seek on the timestamp chip.
- **Patterns to follow:** dictation-history hover actions (Play/Copy/Menu on
  `.onHover`); `parakeetAction(.subtle)` or borderless icon buttons; coral only
  via tokens.
- **Test scenarios:** copy-with-timestamp string format; play-from-here calls
  `seek(toMs:)` with the row's `startMs`; hover actions hidden at rest (opacity
  0) and shown on hover; works in both speaker-turn and flat-segment layouts.
- **Verification:** `scripts/dev/run_app.sh`, open a YouTube/file transcript in
  Timed mode, hover a line, exercise all three actions; paste to confirm format.

### U4. Reading-density polish + font-size
- **Goal:** Calmer long-form reading (the audit warns the current card-per-line
  is too heavy) and an optional, persisted **A− / A+** font-size control.
- **Dependencies:** none; pairs naturally with U1 (same rows). Ships in Phase 1.
- **Files:** `TranscriptTimestampedContentView.swift` /
  `TranscriptSegmentRow.swift`; the transcript pane header in
  `TranscriptResultView.swift` (Text/Timed toggle area, ~1143–1215).
- **Approach:** Reduce per-row chrome for long reading (quieter background, keep
  the active-line highlight as the one strong accent; do **not** add a waveform
  or heavier cards). Add a small font-size stepper that scales the transcript
  body font from `DesignSystem.Typography.body/bodyLarge`; persist the choice in
  `UserDefaults` (one key, e.g. `transcriptFontScale`). Keep speaker color bands
  quiet (per audit).
- **Patterns to follow:** existing `transcriptDisplayMode` Text/Timed toggle;
  `DesignSystem.Typography` + spacing tokens.
- **Test scenarios:** font scale persists across view re-create; active-line
  highlight still the dominant accent at all scales.
- **Verification:** manual reading pass at min/default/max scale on a long
  (30k-word) transcript; confirm active-line still legible.

### U2. In-transcript find (⌘F)
- **Goal:** Search within the open transcript: a capsule find field, live match
  highlighting, "X of Y" counter, and next/prev (⌘G / ⇧⌘G), scrolling matches
  into view. Works in both Text and Timed modes.
- **Dependencies:** none functionally; cleaner *after* U5 extracts the reading
  pane so the find bar mounts on the pane, not the god-file.
- **Files:** new `Sources/MacParakeetViewModels/TranscriptFindModel.swift`
  (`@Observable`, testable matcher); new
  `Sources/MacParakeet/Views/Transcription/TranscriptFindBar.swift` (capsule
  field modeled on `SettingsSearchField`); mount in the reading pane; highlight
  in `TranscriptTimestampedContentView` + the flowing-text path.
- **Approach:** `TranscriptFindModel` takes `[TranscriptSegment]` (and the
  flat text for Text mode) + query → ordered `[Match(segmentIndex, Range)]`,
  case/diacritic-insensitive, with `current`, `next()`, `prev()`. View renders
  matches via `AttributedString` (background `accentLight`, current match a
  stronger `accent` underline/box), shows `current+1 / total`, and
  `proxy.scrollTo(matchSegmentId, anchor: .center)` on navigation — reuse the
  existing `ScrollViewReader`. ⌘F focuses; Esc clears then yields focus; respect
  the existing auto-scroll-pause so find-jumps don't fight playback follow.
- **Patterns to follow:** `SettingsSearchField` (focus/clear/⌘F, capsule with
  `surfaceElevated` + focused `accent.opacity(0.5)` border); existing
  `ScrollViewReader`/`scrollTo` in `TranscriptResultView`.
- **Test scenarios** (model-level, no GUI): match count for a known transcript;
  case/diacritic-insensitivity; next/prev wraparound; empty-query clears;
  multi-match-per-segment ordering.
- **Verification:** ⌘F in both Text and Timed modes; type, ⌘G through matches,
  confirm scroll + counter; Esc clears.

### U3. One quiet playback rail in every mode
- **Goal:** Make the persistent playback rail present in **video-split** mode
  too. Today transport is trapped inside `TranscriptionVideoPanel`; the
  `AudioScrubberBar` only appears in `.audio` / video-hidden layouts. Unify so
  there is always one quiet rail (IINA's lesson) and `.none` shows no transport.
- **Dependencies:** none, but it is the most layout-touching unit — do after the
  reading units land so regressions are isolated.
- **Files:** `TranscriptResultView.swift` `adaptiveLayout` (~261–283);
  `AudioScrubberBar.swift`; `TranscriptionVideoPanel.swift`.
- **Approach:** Promote `AudioScrubberBar` to a shared `PlaybackRail` shown
  beneath content in all playback modes except `.none`. In `.video` split mode,
  keep the video picture in the left pane but route transport (play/pause/scrub/
  time, and the existing PlaybackSpeed + subtitle toggles) into the shared rail
  so the frame stays clean. Verify the rail's enter/exit transition and the
  webm/opus transcode-then-play path are preserved.
- **Patterns to follow:** existing `AudioScrubberBar` slide-in transition
  (`.move(edge: .bottom).combined(with: .opacity)`); `playbackMode` switch.
- **Test scenarios:** rail visible+functional in `.video` and `.audio`, absent
  in `.none`; speed + subtitle toggles still reachable; seek from rail updates
  active-segment highlight + auto-scroll.
- **Verification:** `run_app.sh` across a YouTube video, a local `.mp4`, a local
  `.m4a`, and a meeting (`.none`); confirm transport parity and no dead controls.

### U5. God-file decomposition (enabling, behavior-preserving)
- **Goal:** Extract the slices the units above touch out of the 3,166-line
  `TranscriptResultView.swift`, each guarded by a characterization test first, so
  behavior is provably unchanged. Targets (from the structural map):
  `TranscriptSegmentRow.swift` (U1/U4), `TranscriptReadingPane.swift`
  (find + density + timestamped content host, U2/U4), and pure helpers
  (`activeSegmentIndex`/`autoScrollTarget`, speaker color/label maps) into a
  testable helper file.
- **Dependencies:** interleaved with U1/U2/U4 — extract the slice when first
  editing it; do not big-bang.
- **Files:** new `TranscriptSegmentRow.swift`, `TranscriptReadingPane.swift`,
  `TranscriptSegmentHelpers.swift`; trim `TranscriptResultView.swift`.
- **Approach:** Write a characterization test pinning current rendering/behavior
  (segment-active logic, scroll-target selection) *before* moving code; move with
  no behavior change; keep `@State` ownership and the View↔ViewModel boundary
  intact (the layout↔content split at ~262–283 is already a clean seam).
- **Test scenarios:** the extracted pure helpers (`activeSegmentIndex`,
  `autoScrollTarget`, speaker maps) get direct unit tests; a snapshot-ish
  characterization test ensures parity.
- **Verification:** full `swift test`; structural line-count drop on
  `TranscriptResultView.swift`; no behavior delta in manual QA.

## Acceptance examples

- **AE1.** In Timed mode, hovering a transcript line reveals ▶ / Copy /
  Copy-with-time; nothing is shown at rest; Copy-with-time yields
  `[12:03] …text…`. (U1)
- **AE2.** ⌘F opens a find field; typing highlights all matches and shows
  "3 / 17"; ⌘G scrolls to and emphasizes the next match; Esc clears. Works in
  both Text and Timed modes. (U2)
- **AE3.** Watching a YouTube transcript, a single quiet playback rail is visible
  with play/scrub/speed; the video frame has no separate control box; a meeting
  transcript (`.none`) shows no transport. (U3)
- **AE4.** A 30k-word transcript reads calmly; A+/A− changes body size and the
  choice survives reopening; the active line remains the one strong accent. (U4)
- **AE5.** `TranscriptResultView.swift` shrinks materially; `swift test` green;
  tap-to-seek, active-highlight, auto-scroll, and selection behave exactly as
  before. (U5)

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| U3 layout change regresses the `.video`/`.audio`/`.none` branches or the webm/opus transcode-then-play path | Do U3 last; manual matrix QA across all four source types; keep the existing slide transition; assert no transport in `.none`. |
| Find highlight (`AttributedString`) fights the active-segment highlight or auto-scroll | Keep active-line as a row-background accent and matches as inline text background; on find-navigate, set the existing `autoScrollPaused` so playback-follow doesn't yank the view. |
| God-file extraction silently changes behavior | Characterization test *before* each move; pure helpers get direct unit tests; behavior-preserving moves only. |
| Hover-only actions hurt discoverability / touch | Keep tap-to-seek on the chip as the always-visible primary; hover actions are additive; add `.help` tooltips. |
| Scope creep toward a Descript-style editor | Out-of-scope is explicit; this is a *reading* refresh, not editing. |

## Verification plan

- Per-unit: `swift build`; focused filters — e.g.
  `swift test --filter TranscriptFindModelTests`,
  `swift test --filter TranscriptSegment` (helpers).
- Before declaring done: full `swift test`, plus the Swift 6 no-Whisper gate
  build (see [[feedback_ci_swift6_language_mode_gate]]).
- Manual QA via `scripts/dev/run_app.sh` across **four** sources: YouTube URL,
  local `.mp4`, local `.m4a`, and a meeting transcript — exercise hover actions,
  ⌘F/⌘G, the rail, and font-size at each.
- Regression watch: tap-to-seek, active-line highlight, auto-scroll + 5s pause,
  and text selection must be unchanged.

## Deferred follow-up work

- **Word-level (karaoke) highlight** during playback — needs word-time data
  beyond `TranscriptSegment.startMs`; evaluate `wordTimestamps` coverage first.
- **Hover time-preview / thumbnail scrub** on the rail (IINA pattern) for long
  media.
- **Search-across-transcripts** (library/meetings-wide) — belongs to the
  meetings-workspace plan, not here.
- **Reusable `FindBar`** promoted app-wide (notes, meeting transcript) once
  `TranscriptFindBar` proves out.
