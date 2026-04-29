# Meetings list polish

> **Status:** COMPLETED — implemented in PR #182.
> **Branch:** `feat/meetings-list-polish`
> **Created:** 2026-04-28
> **Completed:** 2026-04-28

## Overview

Meeting recording is implemented on `main` as Labs/Beta but has not yet shipped to a public DMG. The Meetings list (`MeetingsView`) is the first surface a user lands on after recording — currently it shows generic "Meeting {date} at {time}" titles, an icon-strip metadata row (👥 speakers · 📃 words · 🔧 Recovered), a giant left-rail duration, and a mid-sentence transcript snippet. The list is functional but visually noisy, redundant (date appears twice), and not Apple-grade.

This plan brings the list to enterprise/Apple-minimal polish without removing any information — every existing data point remains reachable via hover, right-click, or detail view. The redesign:

- Derives a smart **auto-title** and **substantive snippet** at save-time and persists them on the row.
- Groups meetings by **date headers** (Today / Yesterday / Previous 7 Days / etc.).
- Replaces the icon-strip metadata with **conditional decorators** (recovered → 6px amber dot; speakers → inline text only when ≥2; word count → hover/detail only).
- Adds **hover, selected, focus** states + **keyboard nav** + **right-click menu**.
- Refines the **Record Meeting** button + adds an **active recording banner** at the top of the list.
- Gates **sub-5s recordings** at save-time so trivial dead recordings don't clutter the list.

Scope is the meetings surface only. Many of the underlying changes (derived columns, smart title/snippet) live on `Transcription` and benefit other surfaces (Library, history) as a side effect — that's intentional but no other view's UI is changed in this plan.

## Design references

- **Apple Voice Memos** — closest reference. Two-line rows (title + duration). No icon strip. Edit-mode for bulk actions. Active recording pinned.
- **Apple Mail (macOS)** — conditional decorators (paperclip, flag, VIP star) appear only when relevant. Trailing column is two-line (date / sender or preview). Hairline dividers between groups.
- **Apple Notes (macOS)** — first-line title derived from content. Date group headers. Generous spacing. No filter chips.

## Decision log

| Decision | Choice | Rationale |
|---|---|---|
| Information strategy | Progressive disclosure | Keep all data reachable; gate visibility per row's relevance. Apple Mail pattern. |
| Auto-titles | Tier-1 deterministic at save; tier-2 LLM deferred | Don't gate polish on LLM availability. Tier-1 (substantive sentence picker) ships now; tier-2 (background LLM) is a post-launch follow-up. |
| Speaker count | Inline text `· N speakers`, only when ≥2 | "1 speaker" is the default assumption — no signal. Show only when it's news. |
| Word count | Demoted to hover tooltip + detail view | Rarely actionable at list-glance for a transcription app. |
| Recovered status | 6px amber dot before title (not a chip) | Status, not a stat. Tiny visual decorator like Mail's flag. Tooltip explains. |
| Date grouping | Today / Yesterday / Previous 7 Days / Previous 30 Days / by month | Apple Notes / Mail pattern. Demotes the redundant right-side relative time. |
| Filters / sort menu / density toggle | Not in this plan | Apple Notes ships without these. Default sort (date desc) + search is enough. |
| Bulk actions / multi-select | Deferred (P2) | Not enterprise table-stakes for a single-user voice app. Voice Memos uses Edit mode if needed later. |
| Sub-5s recordings | Gate at save (don't persist) | Most Apple-minimal answer. Cleaner than a "Short recordings" subgroup. |
| Performance budget | 1000 fixture rows scroll at 120 fps on M1 base | All derived fields persisted. No async per-row. Animations opacity-only. |
| Branch from | `main` (not `feat/vocabulary-import-export`) | Independent of in-flight worktrees. |

## Current state

### What exists

- `MeetingsView` renders `LazyVStack` of `MeetingRowCard`s, no grouping, no states.
- Title is `transcription.fileName` ("Meeting Apr 28, 2026 at 1:53 PM" — set at recording stop).
- Snippet is first 120 chars of `cleanTranscript ?? rawTranscript` computed inline per render.
- Metadata row is icon + label triplet (speakers / words / recovered), always shown.
- No hover state, no selected state, no keyboard navigation, no context menu.
- No active-recording indicator on this surface.
- No sub-5s recording validation; trivial recordings persist as rows.

### Key files

| File | Lines | Role |
|---|---|---|
| `Sources/MacParakeet/Views/MeetingRecording/MeetingsView.swift` | 1–171 | Header, search, list container |
| `Sources/MacParakeet/Views/MeetingRecording/MeetingRowCard.swift` | 1–248 | Row component (target of redesign) |
| `Sources/MacParakeetCore/Models/Transcription.swift` | 1–55 | Data model (target of derived fields) |
| `Sources/MacParakeetCore/Database/TranscriptionRepository.swift` | — | CRUD; new fetch path for grouped lists |
| `Sources/MacParakeetCore/Database/DatabaseManager.swift` | 53–549 | Migrations (inline closure pattern) |
| `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift` | 1–73 | Owns filter/sort/scope; needs grouping output |
| `Sources/MacParakeet/Views/Components/DesignSystem.swift` | — | Tokens (use `Colors.warningAmber`, `Animation.hoverTransition`, etc.) |

## Information placement

| Info | List row | Hover | Detail | Rule |
|---|---|---|---|---|
| Auto-title | always (line 1) | — | full title | derived; falls back to time-of-day if no transcript |
| Snippet | always (line 2) | — | full transcript | substantive sentence; alpha-mask trim |
| Duration | always (trailing line 2) | — | playback timeline | `tnum` monospace |
| Time of day | always (trailing line 1) | absolute date | full timestamp | locale 12/24h |
| Date group | header above row | — | — | Today / Yesterday / Previous 7 / 30 / month |
| Recovered | 6px amber dot before title | "Recovered from crash on {date}" | banner | only when `recoveredFromCrash == true` |
| Speakers | inline `· N speakers` after title | speaker names if known | speaker timeline | only when `speakerCount >= 2` |
| Word count | — | tooltip | always | not in list — low signal |
| Engine | — | tooltip | always | not in list — internal detail |
| Active recording | top-of-list banner | — | — | only when recording is live |
| Pinned (future) | leading pin glyph | — | — | only when pinned |
| Has summary (future) | trailing ✦ | — | — | only when summary present |

## Visual spec

### Row

```
Today
─────────────────────────────────────────────────────────────────
•Mercedes Benz Wake prep · 7 speakers                      1:53 PM
 …concern about the dress structure before tomorrow's show…  1h 46m

 Quick voice memo                                           9:12 AM
 …a thought about the new packaging direction…                 5s

Yesterday
─────────────────────────────────────────────────────────────────
 Identity crisis in the new collection                      9:53 PM
 …a bit of a creative block on the second look…                2s
```

### Spec

- **Row height:** 58pt fixed (vertical rhythm).
- **Padding:** 20pt horizontal, 10pt vertical inside row.
- **Title:** `DesignSystem.Typography.bodyLarge` (15pt) semibold, tracking -0.01em, `Colors.textPrimary`.
- **Snippet:** `DesignSystem.Typography.bodySmall` (13pt), `Colors.textSecondary` (~55%), single line, alpha-mask trim on overflow.
- **Time of day:** `DesignSystem.Typography.bodySmall` (13pt), `Colors.textTertiary` (~38%), trailing top.
- **Duration:** `DesignSystem.Typography.duration` (monospace, 13pt), `Colors.textTertiary`, trailing bottom, right-aligned, `tnum` numerals.
- **Speaker inline:** `DesignSystem.Typography.bodySmall`, `Colors.textTertiary`, prefixed with `·`.
- **Recovered dot:** 6pt circle, `Colors.warningAmber`, 6pt leading offset before title.
- **Date group header:** 12pt semibold uppercase, tracking +0.04em, `Colors.textTertiary`, 16pt top padding, 8pt bottom.
- **Hairline divider:** 1px, white @ 6%, only between adjacent rows inside a group (not above first or below last).
- **Hover bg:** `Colors.rowHoverBackground` (overlay, opacity-only).
- **Selected bg:** accent @ 12%; title shifts to accent color.
- **Focus ring:** 2px, system accent @ 60%, 8pt corner radius, no inset shift.
- **Animations:** `Animation.hoverTransition` (0.12s easeInOut) for hover; `Animation.selectionChange` (0.15s) for select.

### Active recording banner (top of list when recording)

```
┌───────────────────────────────────────────────────────────────┐
│  ●  Recording · 12:34                              [Stop ⌘⇧⏎]  │
└───────────────────────────────────────────────────────────────┘
```

- 44pt height, full-width, slight tint over base bg.
- Red pulsing dot (existing recording-pill animation language).
- Live timer in `Typography.duration`.
- Stop button mirrors keyboard shortcut.

### Record Meeting button (idle state)

- Solid red pill, white text, 32pt height, ⌘R hint shown on hover.
- Becomes the active recording banner when recording starts (button itself disappears or transforms).

## Phases

Each phase is independently shippable. Phase A is bedrock data work; Phase B–D are layered UI work on top. After each phase: focused tests + manual verification + `swift test`.

### Phase A — Bedrock (derived columns, grouping, sub-5s gate)

Low-risk, no UI chrome change. Lands the data plumbing the visual phases depend on.

#### A.1 Add `derivedTitle` and `derivedSnippet` columns

**Files:**
- `Sources/MacParakeetCore/Database/DatabaseManager.swift` — register new migration
- `Sources/MacParakeetCore/Models/Transcription.swift` — add fields

**Migration name:** `v0.9-derived-title-snippet` (or next-available; verify at impl time).

```swift
migrator.registerMigration("v0.9-derived-title-snippet") { db in
    try db.alter(table: "transcriptions") { t in
        t.add(column: "derivedTitle", .text)
        t.add(column: "derivedSnippet", .text)
    }
}
```

**Acceptance:**
- [ ] Migration runs cleanly on a v0.8 database.
- [ ] Existing rows have `nil` for both fields immediately post-migration.
- [ ] Existing tests in `MacParakeetTests` still pass.

#### A.2 Backfill derived fields on first launch

**Files:** new `Sources/MacParakeetCore/Services/DerivedFieldsBackfillService.swift`

- On app start, query for `transcriptions WHERE derivedTitle IS NULL AND status = 'completed'`.
- Run derivation in batches of 50, on a low-priority background queue.
- Update each row in a write transaction.
- Idempotent: safe to re-run.

**Acceptance:**
- [ ] 1000-row fixture DB backfills in <2s.
- [ ] No main-thread stalls during backfill.
- [ ] Re-running the service is a no-op.

#### A.3 Tier-1 auto-title derivation

**Files:** new `Sources/MacParakeetCore/TextProcessing/TitleDeriver.swift`

Algorithm:
1. If `cleanTranscript ?? rawTranscript` is empty or <30 chars → fall back to `"{time-of-day}"` (e.g., "1:53 PM").
2. Otherwise:
   - Sentence-tokenize the first 10% of the transcript (or first 1500 chars, whichever smaller).
   - Strip leading filler tokens (`"so"`, `"yeah"`, `"okay"`, `"and"`, `"um"`, `"uh"`, `"like"`).
   - Pick the longest sentence whose stripped length ≥ 20 chars and ≤ 80 chars.
   - If no candidate, take the first sentence ≥ 20 chars and trim to 60 chars at a word boundary, append `…`.
   - Strip trailing punctuation.
3. Return string.

**Acceptance:**
- [ ] Pure function, deterministic.
- [ ] Handles empty / nil / whitespace-only transcripts.
- [ ] Snapshot tests against ≥10 real meeting transcripts (use existing fixtures).
- [ ] Runs in <5 ms for a 12k-word transcript.

#### A.4 Smart snippet derivation

**Files:** `Sources/MacParakeetCore/TextProcessing/SnippetDeriver.swift`

Algorithm:
1. From the first 10% of transcript, find the longest sentence in [40, 140] chars after filler-stripping.
2. If none found, fall back to the longest sentence in the first 30%.
3. Final fallback: first 120 chars, trimmed to word boundary.

**Acceptance:**
- [ ] Pure function. Snapshot tests on real transcripts.
- [ ] Snippet should differ from `derivedTitle` (don't pick the same sentence).
- [ ] <5 ms for 12k-word transcript.

#### A.5 Hook derivation into save path

**Files:** `Sources/MacParakeetCore/Services/MeetingRecordingService.swift` (or wherever transcription completes)

After transcription completes, before saving the row:
```swift
record.derivedTitle = TitleDeriver.derive(from: record)
record.derivedSnippet = SnippetDeriver.derive(from: record)
```

**Acceptance:**
- [ ] New meetings get both fields set on save.
- [ ] Re-transcription updates the fields.
- [ ] File transcriptions and YouTube transcriptions also get fields (free benefit).

#### A.6 Sub-5s recording gate

**Files:** `Sources/MacParakeetCore/Services/MeetingRecordingService.swift` — `stopRecording()`

If recorded duration < 5000 ms:
- Don't persist a `Transcription` row.
- Surface a non-blocking toast: "Recording too short — discarded."
- Clean up audio source files.

Threshold lives as a constant `MeetingRecordingService.minPersistedDurationMs = 5000`.

**Acceptance:**
- [ ] Recording <5s does not appear in the list.
- [ ] Audio source file is cleaned up.
- [ ] User sees a toast.
- [ ] Threshold is a single source of truth (not duplicated).

#### A.7 Date grouping in view model

**Files:** `Sources/MacParakeetViewModels/TranscriptionLibraryViewModel.swift` — extend with `groupedTranscriptions: [(DateGroup, [Transcription])]` computed property.

```swift
public enum DateGroup: Hashable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(year: Int, month: Int)
}
```

Group computation:
- O(n) pass over `filteredTranscriptions`, partition by group, preserve sort order.
- Memoize on `filteredTranscriptions` identity — recompute only when input changes.
- Pure logic; unit-testable.

**Acceptance:**
- [ ] 1000-row computation <5 ms.
- [ ] Empty groups omitted.
- [ ] Month groups labeled correctly across year boundaries (Dec 2025 vs Jan 2026).
- [ ] Snapshot test fixed-clock fixture.

### Phase B — Visual layer

#### B.1 New `MeetingRowCard` layout

**Files:** `Sources/MacParakeet/Views/MeetingRecording/MeetingRowCard.swift` — full rewrite.

Replace the duration column / icon strip / inline-snippet structure with the two-column layout in the spec above. Use `derivedTitle` / `derivedSnippet` for content. Conditional decorators per the placement table.

**Acceptance:**
- [ ] Renders title from `derivedTitle ?? formattedTimeOfDay`.
- [ ] Renders snippet from `derivedSnippet ?? legacyInlinePreview`.
- [ ] Amber dot only when `recoveredFromCrash`.
- [ ] `· N speakers` only when `speakerCount >= 2`.
- [ ] Trailing column shows time-of-day + duration, both right-aligned, monospaced numerals.
- [ ] Row height stable at 58pt regardless of content.
- [ ] No icon strip.
- [ ] No giant left-rail duration.

#### B.2 Date group headers in `MeetingsView`

**Files:** `Sources/MacParakeet/Views/MeetingRecording/MeetingsView.swift` — replace `LazyVStack` of rows with sections.

```swift
LazyVStack(alignment: .leading, spacing: 0) {
    ForEach(viewModel.groupedTranscriptions, id: \.0) { group, items in
        DateGroupHeader(group: group)
        ForEach(items) { item in
            MeetingRowCard(transcription: item)
            if item.id != items.last?.id { HairlineDivider() }
        }
    }
}
```

**Acceptance:**
- [ ] Groups render in order.
- [ ] Empty groups don't render.
- [ ] Hairline only between rows within a group.
- [ ] Headers stick visually but don't pin (no sticky behavior in v1).

### Phase C — Interaction

#### C.1 Hover, selected, focus states

**Files:** `MeetingRowCard.swift`

- `onHover { hovering in withAnimation(.hoverTransition) { isHovered = hovering } }`
- `selected` driven by view model's selection state.
- Focus via SwiftUI `FocusState<Transcription.ID?>` in `MeetingsView`, bound per-row with `focused()`.
- Tap or click on row → toggle selection; double-click → open detail.

**Acceptance:**
- [ ] Hover bg appears on mouse-over with 0.12s fade.
- [ ] Selected bg + accent title color persist when row is selected.
- [ ] Focus ring visible when keyboard-focused, distinct from selection.
- [ ] Hover and selection do not coexist visually awkwardly.

#### C.2 Keyboard navigation

**Files:** `MeetingsView.swift`

- ↑ / ↓ → move focus + selection.
- ↩ → open detail.
- ⌫ → delete (with confirmation alert).
- ⌘F → focus search field.
- Space → QuickLook (deferred to P2; stub for now).

**Acceptance:**
- [ ] Arrow keys move focus and scroll into view.
- [ ] ↩ opens detail.
- [ ] ⌫ shows confirm alert; on confirm, row is deleted with animation.
- [ ] ⌘F focuses the search field.
- [ ] Existing pointer interactions still work.

#### C.3 Right-click context menu

**Files:** `MeetingRowCard.swift`

```swift
.contextMenu {
    Button("Open") { ... }
    Button("Rename") { ... }
    Button("Favorite") { ... }    // toggles existing isFavorite
    Divider()
    Button("Export") { ... }
    Button("Copy Summary") { ... }
    Divider()
    Button("Delete", role: .destructive) { ... }
}
```

**Acceptance:**
- [ ] Right-click anywhere on the row opens the menu.
- [ ] Each menu item works.
- [ ] Destructive Delete shows confirm alert (same as keyboard ⌫).

### Phase D — Recording UX & meta surfaces

#### D.1 Active recording banner

**Files:** new `Sources/MacParakeet/Views/MeetingRecording/ActiveRecordingBanner.swift`; insert at top of `MeetingsView` list when recording is live.

- Subscribes to `MeetingRecordingService.state`.
- Shows when state is `.recording` or `.transcribing`.
- Fixed 44pt height, smooth insert/remove transition.
- Stop button wired to `MeetingRecordingService.stopRecording()`.

**Acceptance:**
- [ ] Banner appears on record-start, disappears on stop.
- [ ] Timer updates each second without dropping frames.
- [ ] Stop button works.
- [ ] Banner doesn't shift the list scroll position when appearing.

#### D.2 Record Meeting button refinement

**Files:** `MeetingsView.swift` (lines 42–82, the existing button).

- Solid red pill, white text "Record Meeting".
- ⌘R keyboard shortcut.
- Hover lift (subtle, 0.12s).
- When recording is active, button is disabled or replaced by banner contextually.

**Acceptance:**
- [ ] Button has stronger affordance vs current low-contrast pill.
- [ ] ⌘R triggers recording start.
- [ ] Disabled state during recording is visually clear.

#### D.3 Hover meta tooltip

**Files:** `MeetingRowCard.swift`

When hovered for >800 ms, show a small tooltip near cursor with:
- Absolute created-at timestamp
- Word count
- Engine + variant (e.g., "Parakeet TDT 0.6B-v3")

**Acceptance:**
- [ ] Tooltip appears after dwell delay, dismisses on mouse-out.
- [ ] Doesn't interfere with selection or click.
- [ ] Native `.help()` style if it works in this NSWindow context (per memory: standard NSWindow is fine; not a `KeylessPanel`).

## Performance budget

- **Target:** 1000 fixture rows scroll at 120 fps on M1 base.
- **Per-row render compute:** zero — all derived fields read directly from the row.
- **Date grouping:** O(n) per `filteredTranscriptions` change, memoized on identity.
- **Animations:** opacity-only (no blur, no shadow shifts, no scale).
- **Backfill:** background queue, batched, <2s for 1000 rows.
- **Auto-title / snippet:** runs at save (one-shot per recording, <5 ms each); never on render path.

Verification: instrument with `os_signpost` around list render and grouping; capture trace with 1000-row fixture before merge.

## Migration plan

1. Ship Phase A behind no flag — derived fields backfill silently, sub-5s gate is invisible improvement.
2. Phase B–D require Phase A's derived fields; don't merge B–D before A's backfill completes a clean run on a real database.
3. No reverse-migration story needed: derived fields are additive and nullable. A downgrade leaves them in the schema unused.

## Testing

| Layer | What | How |
|---|---|---|
| Unit | `TitleDeriver`, `SnippetDeriver` | XCTest with real transcript fixtures |
| Unit | `DateGroup` partitioning | XCTest with fixed-clock fixture |
| DB | Migration v0.9 | Existing in-memory DB pattern |
| ViewModel | `groupedTranscriptions` recomputation, sort | XCTest on `TranscriptionLibraryViewModel` |
| Integration | Backfill service idempotency | XCTest |
| Manual | Hover / selected / focus / keyboard nav / context menu | Run app, walk through every interaction |
| Manual | Active recording banner during real recording | Run app, record meeting, observe banner |
| Manual | 0 / 1 / many rows; recovered / not; speakers 1 / 2 / 7 | Run app, exercise edge cases |
| Manual | Light + dark mode, VoiceOver labels, contrast | Inspect with system tools |
| Performance | 1000-row scroll, grouping recomputation | Instruments trace |

## Open questions

1. **Auto-title fallback when transcript is empty / pending:** plan says "use time-of-day". Confirm acceptable for in-progress transcriptions vs showing "Transcribing…".
2. **Sub-5s threshold:** 5000 ms is the current pick. Should it be 3000? 7000? Recommend 5s; user to confirm.
3. **Hover meta tooltip:** native `.help()` (single-line) vs custom popover (multi-line)? Recommend native — Apple-minimal.
4. **Speaker label wording:** `· 7 speakers` vs `· 7 voices`? Recommend "speakers" (current model field name, clearer).
5. **Active recording banner placement:** above date headers (always visible) or pinned to viewport? Recommend above date headers — list scroll is preserved, banner is unmissable when present.
6. **Apply to Library too?** The derived columns benefit Library/history rendering. Plan scope is Meetings only, but the columns themselves are written for any `Transcription`. Is it OK that Library starts using `derivedTitle` automatically? Recommend yes — free win, no behavior regression.

## Risks

- **Backfill on a multi-thousand-row database** could be slow on cold start. Mitigation: low-priority background queue, batched writes, idempotent so partial completion is recoverable.
- **`SwiftUI` keyboard focus** in long lists is finicky. May require explicit `ScrollViewReader` + `proxy.scrollTo(id, anchor:)`. Plan will iterate during Phase C.
- **Date group memoization** must be on `filteredTranscriptions` identity (or a structural hash), not by recomputing per render — easy to get wrong.
- **Sub-5s gate** must run *after* the recording is finalized, *before* the row is persisted. If the gate fires mid-flow, audio cleanup must still happen (otherwise we leak source files).
- **Concurrent agents on other branches:** unrelated worktrees are in flight (`pr-181-review`, `feat/engine-settings-polish`, `feat/settings-polish`). None touch meetings code or `Transcription` model — verify before merge.

## Sequencing summary

| Phase | Items | Effort | Ship-ready? |
|---|---|---|---|
| A | A.1 – A.7 | ~1 day | Yes — silent improvement |
| B | B.1 – B.2 | ~1 day | Yes — visual lift |
| C | C.1 – C.3 | ~1 day | Yes — interaction polish |
| D | D.1 – D.3 | ~1 day | Yes — recording UX completion |

Total: ~4 focused days. Each phase is a clean PR and can ship independently.
