# Auto Meeting Titles — Merge PR #553 + Manual/Bulk "Generate Title"

**Status:** ACTIVE PLAN — not started
**Date:** 2026-06-18
**ADRs:** ADR-011 (LLM providers), ADR-013 (Prompt Library / multi-summary), ADR-020 (memo-steered summaries — shares the post-meeting LLM path)
**Requirement:** REQ-MEET-021 (proposed)
**Issues:** #546
**Decision (owner, 2026-06-18):** **Option 1.** Get the existing automatic
title generation in (PR #553), **and** add a manual "Generate title" action so
the *existing backlog* of timestamp-named meetings can be cleaned up — single-row
via context menu, and as a **bulk** action riding on the Library multi-select
substrate (`2026-06-18-library-bulk-delete.md`). No silent mass auto-rewrite of
the backlog.

## What this plan closes out

#546: meetings are named "Meeting Jun 17, 2026 at 09:59", which is unsearchable —
*"especially when there are multiple recordings in a day."* The reporter's pain is
two-part: (a) new meetings should get a real title automatically, and (b) their
*existing* library of timestamp names is hard to navigate.

Part (a) is **already built** in **PR #553** (`feat/auto-meeting-titles`,
`MeetingTitleGenerator`, 510 insertions, `swift test` green) — but the PR is
**merge-conflicting with `main`** and **unreviewed**. Part (b) is the small
follow-on this plan adds: a user-initiated "Generate title" that reuses #553's
generator and #498's selection.

## Why this is two workstreams, sequenced
1. **Merge PR #553** (automatic titles for new meetings) — review + de-conflict +
   confirm a few product choices. No fresh implementation.
2. **Manual + bulk "Generate title"** (backlog cleanup) — small, depends on the
   #498 Library multi-select substrate for the bulk path.

## Scope boundaries

### In scope
- Review, conflict-resolve, and merge **PR #553**: conservative automatic title
  generation after a meeting finishes transcribing — only replaces timestamp-style
  fallback names, preserves calendar/custom names, gated on a configured LLM +
  the default-on `auto-meeting-titles` preference, rejects generic/date-like
  output, falls back silently.
- A **single-row "Generate title"** context-menu action on meeting rows (Library
  meetings list + meeting detail) that runs the same generator on demand.
- A **bulk "Generate titles"** action in the Library multi-select action bar
  (depends on `2026-06-18-library-bulk-delete.md`) that **only targets
  fallback timestamp-named meetings in the selection** (skips calendar/custom
  names) and runs with a **bounded concurrency cap of 3–5 in-flight LLM calls**;
  a large cloud-key batch shows a one-line spend heads-up before starting.
  [Gemini, Greptile P2]
- Behavioral rule on overwrite: **automatic** and **bulk** paths only replace
  fallback timestamp names (never clobber a calendar/custom name); the
  **single-row** "Generate title" is an explicit per-item action, so it
  regenerates whatever the current title is (this is also how a user re-rolls a
  title they dislike).

### Out of scope
- **Automatic backlog sweep** (silently titling all old meetings) — rejected;
  cloud cost + surprise. Backlog is cleaned only by user-initiated manual/bulk.
- New title-generation logic — reuse `MeetingTitleGenerator` from #553 verbatim.
- Titling non-meeting items (files/YouTube already derive titles from content via
  a different path).

### Invariants
- **No silent spend.** Manual/bulk generation is explicit; automatic is gated by
  the (default-on) preference + a configured provider; no provider → no-op.
- **Never clobber a deliberate name except by explicit single-item intent.**
  Calendar event titles and user renames survive both the automatic path (#553
  guarantees this) and the **bulk** path (which targets fallback names only);
  only the **single-row** action overwrites a deliberate name, because the user
  asked for that specific one. [Gemini]
- **Graceful degradation.** Generation failure leaves the existing title intact;
  surfaces a quiet error on the manual path, silent on the automatic path.
- Bulk generation reports succeeded/failed counts; one failure never aborts the batch.

## Verified current state (file:line)

- PR #553 (`feat/auto-meeting-titles`): open, **`mergeable: CONFLICTING`**,
  not draft, `swift-test` SUCCESS, no review yet. Adds
  `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTitleGenerator.swift`
  (~148 lines), an `auto-meeting-titles` pref (AI Settings + settings search +
  `UserDefaultsAppRuntimePreferences` + `macparakeet-cli config`), and a
  finalize-time integration call. Title gate: replaces only "Meeting" / "Meeting
  <date>" fallback patterns; ≥12-word context gate; 2–8 word output; rejects
  generic/multiline/>70-char/date-like/`NO_TITLE`.
- Default title source (on `main`):
  `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`
  — `makeDisplayName(for:)` (~1517-1523) → "Meeting <date> at <time>"; stored in
  `Transcription.fileName`.
- Rename path: `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`
  — `renameCurrentTranscription(to:)` (~1153-1170) updates `fileName`
  (+ `derivedTitle`) and persists `updateFileName(id:fileName:)`.
- LLM call path: `Sources/MacParakeetCore/Services/LLM/LLMService.swift`
  — `generatePromptResult(transcript:systemPrompt:)` (~6); provider presence is
  the "configured" check (service is nil when unconfigured).
- Post-meeting auto-prompt pipeline (where automatic title-gen runs alongside):
  `PromptResultsViewModel.autoGeneratePromptResults()` (~347-377) +
  `TranscriptionService.finalize()` (~1559-1575).
- Bulk substrate dependency: `2026-06-18-library-bulk-delete.md` adds the Library
  multi-select on `TranscriptionLibraryViewModel`.

## Design

### Workstream 1 — merge PR #553
- Rebase `feat/auto-meeting-titles` on latest `origin/main`, resolve conflicts
  (likely in `AppRuntimePreferences`, settings views, settings search, CLI config —
  all surfaces other recent PRs also touch).
- Review against the open questions below; adjust if owner changes a default.
- Greptile LGTM + `swift test` green → merge.

### Workstream 2 — manual + bulk "Generate title"
- Extract the generator trigger into a ViewModel method usable outside the
  finalize path, e.g. `generateTitle(for: Transcription) async -> Result`, calling
  the same `MeetingTitleGenerator` + `LLMService` and persisting via the existing
  `updateFileName` path.
- **Single-row:** context-menu "Generate title" on meeting rows (Library meetings
  list + meeting detail action bar). Shows a brief in-row progress state; on
  success the row title updates in place with a gentle transition.
- **Bulk:** a "Generate titles" button in the multi-select action bar; iterates
  the **fallback-named meetings in the selection** (skips calendar/custom names
  and non-meetings), runs generation with a **3–5 in-flight concurrency cap**,
  and reports `{titled, skipped, failed}`. No LLM configured → a single
  explanatory note rather than N errors; a large cloud batch → a one-line spend
  heads-up first.
- **Single-row** path overwrites the current title (explicit intent); **automatic**
  and **bulk** paths retain #553's fallback-only rule.

## Phases
1. **Merge PR #553** — rebase/de-conflict, review, confirm defaults, merge.
   (Unblocks everything; ships automatic titles for new meetings.)
2. **Extract reusable `generateTitle(for:)`** + unit tests (gating, overwrite
   rule, failure leaves title intact).
3. **Single-row context-menu action** + in-row progress; dev-app verify the
   row updates in place.
4. **Bulk "Generate titles"** (after `2026-06-18-library-bulk-delete.md` lands)
   — action-bar button, bounded concurrency, result summary.
5. **Docs** — `spec/02-features.md`, register REQ-MEET-021, issue reply on #546.

## Testing
- Reuse/extend #553's `MeetingTitleGenerator` tests.
- ViewModel tests for `generateTitle(for:)`: no-provider no-op, success persists,
  failure leaves the old title, manual overwrite vs. automatic fallback-only.
- Bulk: result counts correct; one failure doesn't abort; no-provider yields a
  single skip note.
- `swift test` before merge.

## Open questions (confirm during Workstream 1 review)
1. **Combine title into the summary call?** #553 makes a *separate* LLM call for
   the title; the summary auto-prompt already sends the same transcript. Piggybacking
   the title onto that call halves cloud round-trips at the cost of coupling.
   Lean: keep separate for now (simpler, more robust); note as a future optimization.
2. **Zero-LLM fallback to the calendar event title?** For the local-first majority
   with no LLM, automatic titling is a no-op. When a meeting was calendar-started,
   using the event title is a strong zero-LLM title. In scope here, or a separate
   small follow-up? Lean: separate follow-up (keeps this plan focused on #553 + manual).
3. **Default-on with a cloud key = silent (tiny) spend.** #553 defaults the pref
   on. Confirm comfort, or gate default-on to local providers and prompt for cloud.
   Lean: keep default-on (spend is negligible, matches category norms like Granola).

(Resolved during PR #556 review: bulk "Generate titles" targets fallback-named
meetings only — never clobbers calendar/custom names — and caps in-flight LLM
calls at 3–5 with a spend heads-up for large cloud batches. Single-row stays
overwrite-anything.)

## Docs to update on completion
`spec/02-features.md`, `spec/README.md`, `spec/kernel/requirements.yaml`
(REQ-MEET-021), and an issue reply on #546.
