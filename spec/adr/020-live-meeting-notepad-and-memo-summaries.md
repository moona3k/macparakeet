# ADR-020: Live Meeting Notepad + Memo-Steered Summaries

> Status: Proposed
> Date: 2026-04-25 (proposed) · Amended 2026-04-25 (post-review)
> Related: ADR-013 (prompt library + multi-summary), ADR-014 (meeting recording), ADR-017 (calendar auto-start), ADR-018 (live meeting Ask tab), ADR-019 (crash-resilient meeting recording)

## Amendment (2026-04-25, post-review)

After parallel design reviews by Codex and Gemini against this ADR in its first-draft form, the following corrections and clarifications were folded in. None of them change the product shape; all of them fix correctness, concurrency, or scope-clarity gaps in the original spec.

- **§4 substitution semantics:** specified single-pass simultaneous substitution to prevent injection via user notes containing `{{transcript}}` literals.
- **§5 auto-run guard:** the new built-in prompt is inserted with `isAutoRun = true` only when the user has at least one auto-run prompt today, preserving ADR-013's "zero auto-run is valid" invariant.
- **§7 NSPanel popover:** added implementation notes calling out SwiftUI `.popover` traps inside `KeylessPanel` and committing to an in-view overlay with `onKeyPress` interception.
- **§8 lock-file ownership:** `MeetingNotesViewModel` no longer writes the lock file directly. All `recording.lock` writes are serialized through `MeetingRecordingService.updateNotes(_:)` so notes-saves cannot race with state-transition writes.
- **§9 lock-file evolution:** `notes` is added as a `decodeIfPresent` optional at the same schema version (additive). The notes field is decoded independently so a malformed `notes` value cannot block recovery of the audio metadata. Future hard schema bumps will relax the `==` version guard to `>=`.
- **§11 invariant enforcement:** named the single code-level write path that keeps "Notes are user-authored only" enforceable, not just documentary.
- **§3 length cap:** soft cap of 8,000 words with UI warning + truncation suffix at summary generation time, to protect LLM context windows.
- **Rationale:** added subsections explaining which prompt classes benefit from memo-steering (open-ended yes, tightly structured marginal) and rebutting reviewer pressure to split the PR.
- **Consequences:** added entries for cloned-prompt customizations not auto-gaining `{{userNotes}}`, the raw-markdown rendering gap vs Char's TipTap, and the panel-width tab-label collapse strategy.
- **Architecture diagram:** updated to route notes writes through `MeetingRecordingService`.
- **Tests:** added literal-string-insertion assertion for slash commands.
- **§10:** fixed `⌥1` → `⌘1` typo in pre-meeting toast copy.

## Context

ADR-014 ships meeting recording. ADR-018 adds an Ask tab next to the live transcript. ADR-019 makes the recording crash-resilient. After all three, the live meeting panel surfaces two postures for the user: **read the transcript** or **interrogate the AI**. Both are passive with respect to the meeting itself. There is no place for the user to write down what *they* think matters as the meeting unfolds.

A review of [Char (formerly Hyprnote)](https://github.com/fastrepl/anarlog), the leading open-source Granola alternative, surfaced the pattern that defines the Granola-class flow:

1. The notepad is the **primary surface** during the meeting. Transcript is a collapsible footer; the writer is in a TipTap editor that fills the panel.
2. The user's notes feed the **post-meeting summary prompt** as a first-class input alongside the transcript. The summary respects what the user emphasized.
3. There is no chat during the meeting — the AI's job is to expand the user's notes after the fact, not to converse during the call.

Char's framing: "Take notes to guide Char's meeting notes." The summary feels intelligent because the user's structure becomes the summary's structure. Without a notepad, the summary is generic; with one, it reads like the user's mind on paper.

We already differ from Char on the third point — our Ask tab (ADR-018) is a deliberate edge over Char's post-meeting-only chat, and reviewers like the thinking-partner framing. We should keep it. But we are missing the first two points entirely. This ADR adds them in a way that respects the Ask surface we just shipped.

The underlying primitives mostly exist:

- `MeetingRecordingPanelView` already has tab infrastructure (Transcript / Ask, ⌘1/⌘2)
- `Prompt.builtInPrompts()` already seeds prompts; new ones are additive
- `SummaryViewModel` already accepts a prompt and runs it against the transcript
- `MeetingRecordingRecoveryService` + `MeetingRecordingLockFileStore` already persist meeting state every second
- `TranscriptionRepository` migrations are routine

What's missing: a place for the user to type during the meeting, a column to persist what they typed, a way to thread that text into the existing prompt rendering, and a slightly richer pre-meeting toast for calendar-triggered starts so the meeting opens with context.

## Decision

### 1. Three tabs in the live panel: Notes / Transcript / Ask, Notes default

`MeetingRecordingPanelView` grows from two tabs to three. The Notes tab is selected by default when the panel opens. Tab labels carry live state hints so the user gets situational awareness from the tab bar:

```
┌────────────────────────────────────────────────┐
│ ● Recording 6:03                               │
├────────────────────────────────────────────────┤
│  Notes · 24w   Transcript · LIVE   Ask · 3     │
├────────────────────────────────────────────────┤
│                                                │
│  [content for selected tab]                    │
│                                                │
└────────────────────────────────────────────────┘
```

Keyboard: ⌘1 → Notes, ⌘2 → Transcript, ⌘3 → Ask. The floating recording pill remains the canonical Stop control; the panel footer behavior from ADR-018 is unchanged (hidden on Ask, shown on Transcript). On Notes, the footer is hidden — the writing surface owns the bottom edge.

The Notes default is the deliberate signal: this is the main event during a meeting. Transcript and Ask are the supporting cast.

**Tab-label collapse at narrow panel widths.** The current panel has a 360px minimum width. State-bearing labels (`Notes · 24w`, `Transcript · LIVE`, `Ask · 3`) will not fit at the minimum. Strategy: per-tab measurement at layout time. When the available cell width is below the measured label-with-badge width, the badge collapses into the tab's tooltip and the label renders as the plain noun (`Notes`, `Transcript`, `Ask`). Verified at 360px during Phase 2; the rich label is the goal at default panel widths (~440px+) where it consistently fits.

**Escape-hatch threshold.** The collapsible-transcript-ticker-inside-Notes pattern (Char's collapsible footer) is listed under Future Work. The trigger to promote it from Future Work to required is concrete: if Phase 2 manual usability testing shows users switching between Notes and Transcript more than ~3 times per minute on average, the cost of the switch outweighs the cost of the inline ticker. The decision is taken before Phase 3 freezes — not at "tired of looking at the branch" time.

### 2. Plaintext editor for v0.6

The Notes pane is a `TextEditor` with placeholder copy. No rich-text, no NSTextView wrapper, no markdown rendering during the meeting. Slash commands (§7) cover the highest-signal structuring needs (action items, decisions, timestamps) without a formatting infrastructure.

Rich-text is deferred to Future Work. Plaintext is enough to ship the memo→summary mechanic, which is where the user value lives.

### 3. Notes persist on `transcriptions.userNotes`

A new nullable column `userNotes TEXT` is added to the `transcriptions` table via the standard inline-migration path in `DatabaseManager.swift`. One-to-one with the recording; no separate notes table.

Empty notes is a valid state — short meetings, audio-only attention, anything where the user just wanted a transcript. The column is `NULL` when the user wrote nothing.

A separate `meeting_notes` table was considered for future versioning support and was rejected as premature. If multi-version notes ever become a feature, the column can be promoted to a table without breaking history (same shape as the v0.5 `transcriptions.summary` → `summaries` table promotion).

**Soft length cap of 8,000 words.** The schema column is unbounded (`TEXT`), but the user-facing surface enforces a soft cap. `LiveNotesPaneView` displays an inline footer notice once the user crosses 7,500 words ("Approaching 8,000-word soft cap; longer notes may be truncated for summary generation."). At summary generation time, `SummaryViewModel` truncates `userNotes` to 8,000 words *for the prompt only* (the persisted note is unmodified) and surfaces a small banner above the new summary: "Notes were truncated to 8,000 words for this summary; full notes preserved." The cap exists to protect the LLM context window — at typical English word-to-token ratios, 8,000 words ≈ 11k tokens, leaving budget for transcript + system prompt + response in even modest context windows. The cap is intentionally soft so users typing fast during very long meetings are not silently censored from their own data.

### 4. `{{userNotes}}` template variable threaded into prompt rendering

A minimal `PromptTemplateRenderer` substitutes `{{key}}` markers in a prompt's content with values supplied at render time. Initial keyset:

| Variable          | Source                                              |
|-------------------|-----------------------------------------------------|
| `{{userNotes}}`   | `Transcription.userNotes`, empty string if `nil`    |
| `{{transcript}}`  | The transcript text the prompt would have used today |

This is string substitution, not a template engine. No conditionals, no loops, no helpers. Prompts that reference `{{userNotes}}` must read sensibly when the value is empty (handled by the prompt copy itself, e.g., "If the user took no notes, infer structure from the transcript alone.").

Existing prompts that don't use the variables continue to work — they receive the rendered transcript via the same path the unrendered transcript flowed through before.

**Substitution is single-pass and simultaneous.** Replacements are computed against the original prompt text and applied atomically — no second pass, no recursion. User notes containing the literal string `{{transcript}}` (a paste of code, a quoted template, etc.) are not interpreted as a template token in a later pass. This eliminates a small but real injection vector where a user's own notes could double-inject the transcript or smuggle other variables into a position the prompt author never intended. Tested explicitly with adversarial inputs in `PromptTemplateRendererTests`.

### 5. New built-in prompt: "Memo-Steered Notes"

A new built-in prompt is added to `Prompt.builtInPrompts()` and seeded on next launch. Approximate copy (the literal prompt string — no markdown formatting, the asterisks below are the spec's emphasis only):

```
You are summarizing a meeting. The user took these notes during the meeting —
treat them as the structure and priorities of the summary. Expand each note
with detail from the transcript. If the user wrote nothing, infer structure
from the transcript and produce a clean meeting-notes view.

USER NOTES:
{{userNotes}}

TRANSCRIPT:
{{transcript}}

Output:
- Each user note expanded with supporting detail from the transcript
- Action items (only if the transcript supports them)
- Decisions made
- Open questions
```

**Auto-run insertion guard.** The new prompt is inserted with `isAutoRun = true` *only when the seeding step finds at least one existing prompt with `isAutoRun = true` in the database*. If the user has explicitly disabled all auto-run prompts (a valid state per ADR-013), the new prompt is inserted with `isAutoRun = false` to preserve their explicit choice. On fresh installs the migration seeds all built-ins together; the guard reduces to "the new prompt is auto-run if any built-in default is auto-run," which holds.

**Existing built-in prompt updates.** The shipped "Meeting Notes" and similar prompts are updated to reference `{{userNotes}}` optionally; the wording must degrade gracefully when notes are empty (verified per-prompt during implementation). The reconciler in `DatabaseManager.reconcileBuiltInPrompts()` already pushes content updates to built-in rows on every launch — existing users with unmodified built-ins receive the new content automatically. **Customized clones are not migrated** — see Consequences.

### 6. Snapshot user notes on the summary record

Per the prompt-snapshot principle from ADR-013, each `Summary` record gains a `userNotesSnapshot: String?` column. The value of `userNotes` at the moment of summary generation is captured alongside the existing prompt snapshot. Editing notes after a summary has been generated does not retroactively change that summary's metadata.

This makes summaries self-contained for the same reason ADR-013 made them self-contained: a summary should always accurately reflect what produced it.

**Pre-migration summaries have NULL snapshots.** Summaries generated before this migration have `userNotesSnapshot = NULL` (no notes existed). The summary detail view treats `NULL` and empty string identically: the "Notes used" section is omitted entirely rather than rendered as an empty block. Only non-NULL, non-empty snapshots render the section.

### 7. Slash commands in the Notes pane: minimal set

The Notes pane supports a small slash menu invoked by typing `/`:

| Command     | Insertion                          |
|-------------|------------------------------------|
| `/action`   | `**Action:** ` (cursor after)      |
| `/decision` | `**Decision:** ` (cursor after)    |
| `/now`      | `[MM:SS]` (current elapsed time)   |

That is the entire menu. `/ask` is explicitly **not** in the set — see Rationale §"Why not /ask in the slash menu."

The popover is a thin SwiftUI overlay positioned at the caret, dismissed on Escape, navigable with arrow keys. First time we ship a slash menu in the codebase; the implementation is intentionally local to the Notes pane and not generalized.

The bold-asterisk insertions are plaintext markers, not rendered formatting. Post-meeting markdown rendering (Future Work) will surface them as headings/labels.

#### Implementation notes — NSPanel pitfalls

The slash menu must be implemented as an **in-view SwiftUI overlay anchored to the editor frame**, not a detached SwiftUI `.popover(isPresented:)` modifier. The `MeetingRecordingPanelView` is hosted in a non-activating `KeylessPanel`, where SwiftUI popover behavior is unreliable on three counts:

- **Clipping.** `.popover` and `.overlay` content can clip to the SwiftUI view's frame; popovers near panel edges may be invisible at the bottom of the panel.
- **First-responder stealing.** A presented `.popover` can pull focus away from the underlying `TextEditor`, dismissing the caret and breaking the typing→commit flow.
- **Key event routing.** Arrow-key and Return routing into a popover from a non-activating panel is documented-flaky territory (see CLAUDE.md Known Pitfalls re: `NSTrackingArea` for the parallel hover case).

Implementation pattern: intercept `keyDown` events in the `TextEditor` via `onKeyPress` (or, if `onKeyPress` proves insufficient inside `KeylessPanel`, drop to an `NSTextView` wrapper). Render the menu as a `ZStack` overlay positioned at the caret's measured frame. Keyboard navigation (↑/↓/Return/Esc) is handled by the same `onKeyPress` interceptor — the overlay never owns first responder.

### 8. Notes auto-save with idle debounce — service-routed

Every keystroke queues a 250 ms idle debounce. On debounce fire:

- `MeetingNotesViewModel` calls `MeetingRecordingService.updateNotes(_:)` — an actor-isolated method that owns *all* writes to `recording.lock`. The service merges the new notes value into the current lock-file struct without changing the recording `state` field, then atomically rewrites the file.
- The service also updates a transient `currentNotes` field on its in-flight session for finalize handoff.

The view model **never writes the lock file directly.** This is the load-bearing rule for ADR-019 compatibility: state-transition writes (`recording → awaitingTranscription` on stop, `awaitingTranscription → completed` after persistence) and notes-debounce writes both target the same JSON file. Routing all writes through one actor serializes them and removes any chance of a stale-state notes write overwriting a fresh state transition (which would mark a clean-stopped meeting as crashed in the recovery scanner's eyes).

On meeting finalize, `MeetingRecordingService.persistNotes(_:)` writes the final notes value to `transcriptions.userNotes` in the same transaction as the transcript and metadata.

There is no save button. There is no dirty indicator. Persistence is invisible.

### 9. ADR-019 lock-file extension carries notes — additive and decode-independent

The `recording.lock` JSON schema gains a `notes: String?` field. `MeetingRecordingLockFileStore` reads/writes it; `MeetingRecordingRecoveryService` restores it onto the recovered session at launch time. Recovery flow is otherwise unchanged — the recovered meeting opens with whatever notes were persisted at the last debounce fire before the crash.

**Schema versioning.** The addition is backward-compatible at the existing schema version. The `notes` field is decoded with `decodeIfPresent`: lock files written by previous app versions (no `notes` key) decode with `notes = nil` and recover normally. New lock files include the key. **The schema version is not bumped.**

The current `MeetingRecordingLockFileStore.read()` guards on `schemaVersion == currentSchemaVersion`. Because we are not bumping the version, that guard continues to behave correctly. Any *future* hard schema bump must relax the guard to `>=` first (separately) — otherwise a Sparkle-update window where the new app version reads lock files written by the previous version would silently discard recoverable sessions. This is called out for the implementer of any future bump and tracked as a follow-up.

**Notes decoded independently.** The `notes` field is decoded as a separate `try?` step *after* the structural fields decode successfully. A malformed `notes` string (or any future encoder bug specific to that field) causes the recovery scanner to fall back to `notes = nil` for that session, but the audio metadata and recoverability of the recording itself are preserved. The user loses the typed notes for one specific recovery, but the meeting itself is still recoverable. Without this split, a single corrupted notes byte would tank the entire recovery.

The Ask conversation persistence sketched as Future Work in ADR-018 is **not** addressed here. Notes and Ask have different recovery requirements: notes are user-authored intent and must survive; Ask is a conversational scratch surface where loss is annoying but not load-bearing.

### 10. Rich pre-meeting countdown toast for calendar-triggered starts

When the auto-start countdown (ADR-017 Phase 2) fires from a `MeetingMonitor` event with attached calendar metadata, `MeetingCountdownToastView` renders a richer variant:

```
┌────────────────────────────────────────────┐
│ Q2 Planning                                │
│ Starts in 5s · 4 attendees · 🎥 Zoom       │
│ ─────────────────────────────────────────  │
│ Discuss roadmap, OKRs, and headcount…      │
│ ─────────────────────────────────────────  │
│ Take notes to shape the summary. ⌘1 = Notes │
│                                            │
│            [Cancel]   [Start Now]          │
└────────────────────────────────────────────┘
```

Manual-start toasts (hotkey, menu bar, panel button) keep the minimal variant — no new friction for paths that already work cleanly.

### 11. Notes are user-authored only — code-level enforcement

The Notes surface contains exactly what the user typed. Ask responses live in the Ask thread, never in Notes. This is the load-bearing invariant for the memo→summary mechanic: feeding AI-generated text back into AI prompts dilutes the user's voice and produces recursive summaries that gradually drift from intent.

The corollary: there is no "insert this Ask response into Notes" affordance. If the user wants Ask output in Notes, they retype it (which is friction by design — it forces the user to commit to what's worth keeping).

**Code-level enforcement.** `Transcription.userNotes` is set on the row by exactly two call sites:

1. `MeetingRecordingService.persistNotes(_:)` — called at finalize, reads from `MeetingNotesViewModel.notesText`
2. `MeetingRecordingRecoveryService.restoreNotes(_:)` — called at launch when a recoverable session has notes in its lock file

`MeetingNotesViewModel.notesText` is a single property bound exclusively to the `TextEditor` in `LiveNotesPaneView` via `$notesText`. The view model exposes no public mutator that writes to `notesText` from anywhere else. A future engineer who wants to insert AI-generated content into notes would have to either bypass `MeetingNotesViewModel` (caught in code review) or add a programmatic setter to it (which the type guards against by keeping the property `private(set)` for external readers). Either change is a visible signal that the invariant is being touched.

The invariant is therefore enforced by surface area, not by hope.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│              MeetingRecordingPanelView                   │
│  ┌──────────┐ ┌───────────┐ ┌─────┐                      │
│  │ Notes·Nw │ │Transcript │ │Ask·N│  ← tabs (⌘1/⌘2/⌘3)   │
│  └──────────┘ └───────────┘ └─────┘                      │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │ MeetingRecordingPanelViewModel                   │    │
│  │   ├── notesViewModel: MeetingNotesViewModel  ←── │    │
│  │   ├── chatViewModel: TranscriptChatViewModel     │    │
│  │   ├── previewLines, chatTranscript               │    │
│  │   └── selectedTab: LivePanelTab (default .notes) │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼ debounce 250ms
        ┌─────────────────────────────────────────┐
        │ MeetingRecordingService (actor)         │
        │   .updateNotes(_:)  ─ merges notes into │
        │                       lock-file struct  │
        │                       without touching  │
        │                       state field       │
        │   .persistNotes(_:) ─ called at         │
        │                       finalize          │
        └─────────────────────────────────────────┘
                          │ (single serialized writer)
                          ▼
        ┌─────────────────────────────────────────┐
        │ MeetingRecordingLockFileStore           │
        │   recording.lock { state, notes?, … }   │  ← ADR-019 file
        │   notes decoded with decodeIfPresent;   │
        │   independent try? so corruption of     │
        │   notes never blocks audio recovery     │
        └─────────────────────────────────────────┘
                          │
                          ▼ at finalize
        ┌─────────────────────────────────────────┐
        │ TranscriptionRepository                 │
        │   transcriptions.userNotes ← notes      │
        └─────────────────────────────────────────┘
                          │
                          ▼ at summary generation
        ┌─────────────────────────────────────────┐
        │ SummaryViewModel                        │
        │   ├── reads userNotes from row          │
        │   ├── PromptTemplateRenderer            │
        │   │   {{userNotes}}, {{transcript}}     │
        │   └── snapshots userNotes on Summary    │
        └─────────────────────────────────────────┘
                          │
                          ▼
                   ┌──────────────┐
                   │  LLMService  │
                   └──────────────┘
```

## Rationale

### Why notes-first instead of transcript-first

Reading scrolling text is passive. Watching an AI think back at you (Ask) is passive. Typing your own notes is active — it forces engagement with the meeting and produces structured intent the AI can later build on. Char's strongest single decision is making the user's writing surface the default. We adopt it.

### Why three tabs and not Notes-with-collapsible-transcript-footer

Folding the transcript into a one-line footer inside Notes (Char's pattern) was the leading alternative. Three reasons we kept tabs:

- **Ask is fat-target.** ADR-018 just shipped; reviewers and users like the thinking-partner pills. Demoting Ask to a slash command (`/ask`) buries them and forces users to remember they exist.
- **State-bearing tab labels** (`Notes · 24w`, `Transcript · LIVE`, `Ask · 3`) reduce the cost of three tabs by giving the user situational awareness from the tab bar. They don't need to switch as often.
- **The collapsible-footer pattern can still come later** as a polish refinement *inside* the Notes tab — a one-line "last sentence" strip at the bottom — without removing the Transcript tab. We can have both.

### Why not `/ask` in the slash menu

Slash commands shine when the AI's job is to **help you write** (Notion, Cursor). Ask's job is to **think alongside you about the meeting**. Inserting Ask responses inline in Notes would:

1. **Break the memo→summary invariant** — AI text in `userNotes` would be re-fed into AI prompts, recursively diluting the user's voice.
2. Force a hybrid editor that distinguishes user-authored from AI-authored spans.
3. Bury the thinking-partner pills behind a `/` keystroke they have no current home for.

Ask remains a peer surface. Notes stay user-only.

### Why plaintext, not rich-text, for v0.6

We have no native macOS rich-text infrastructure in the app today. Wrapping `NSTextView` for SwiftUI is a real piece of work and not where the user value is. Meeting notes are typically short and low-format; the highest-signal structuring patterns (action items, decisions, timestamps) are covered by three slash commands. Rich-text is a Future Work item; it's not blocking the memo→summary win.

### Why a column on `transcriptions`, not a `meeting_notes` table

One-to-one with a meeting. Simpler queries. Smaller migration. No new repository. Promotion to a table later (for note versioning, multi-author notes, etc.) is mechanically the same as the v0.5 `summary` column → `summaries` table promotion, which we know how to do safely.

### Why minimal slash commands

Three commands cover ~80% of structured note-taking during a meeting. Adding more invites feature creep and dilutes the menu (decision fatigue at the moment the user wants speed). Users can type freeform anyway. Future Work lists candidate additions; ship the minimal set first and let usage decide.

### Why snapshot user notes on the summary

Same principle as ADR-013's prompt snapshots. A summary should always accurately reflect what produced it. If the user edits their notes a week later and regenerates a summary, the original summary's snapshot proves what it was built from. No retroactive history rewriting.

### Why `{{userNotes}}` is optional in prompts

Empty notes is a valid state. Built-in prompts must produce useful summaries with or without notes. The new "Memo-Steered Notes" prompt handles the empty case explicitly in its copy ("If the user wrote nothing, infer structure from the transcript alone."). Existing prompts that gain optional `{{userNotes}}` references must read sensibly with empty substitutions — verified by tests.

### Why upgrade only the calendar-triggered countdown toast

Calendar-triggered starts already carry rich event metadata for free; not surfacing it is a missed opportunity. Manual starts have no metadata to show — adding the rich layout would just be empty fields, more friction, and would pull every manual-start path into a redesign for no benefit.

### Which prompt classes benefit from memo-steering

Memo-steering provides the strongest signal to **open-ended summary prompts** where the LLM is otherwise free to weight transcript topics evenly. The user's notes act as a priority mask — topics the user noted get expanded; topics the user ignored get compressed. The new "Memo-Steered Notes" prompt is the canonical case.

**Tightly structured prompts** (e.g., "Action Items only", "Decisions table") receive marginal benefit because their output structure is fixed regardless of user emphasis — the LLM extracts action items the same way whether the user wrote about them or not. For these prompts we update the wording to *reference* `{{userNotes}}` only when the reference adds value (e.g., "Cross-check action items against any tasks the user noted explicitly"); for prompts where the reference is purely additive ceremony, the update is skipped.

This is verified per-prompt during implementation. The shipped Memo-Steered Notes prompt is the user-facing default; the others are tools.

### Why a single PR despite review pressure to split

Both first-pass reviewers (Codex and Gemini) suggested splitting this into two PRs (Phase 1 schema + plain notepad, Phase 2 slash + memo-steering). We are intentionally keeping it as one PR for three reasons:

- **The user-facing value is the *combination*.** A notepad without memo-steering is a scratchpad; memo-steering without a notepad is unreachable. Shipping one without the other lands an incoherent half-feature.
- **The phased commit clusters within the PR provide the same review-walk benefit a split would**, without forcing users into an awkward intermediate release with a half-wired feature.
- **The risk surfaces** (lock-file integration, prompt rendering, panel restructure) **are the same files either way.** Splitting reschedules the risk; it doesn't reduce it.

If post-implementation the diff is genuinely too large to review in one sitting, that is a delivery problem (open the PR earlier, walk reviewers through it commit-by-commit) rather than a design problem.

## Consequences

### Positive

- The user's notes become first-class structural input to the summary — high perceived intelligence at zero new LLM cost
- Differentiator vs every other "chat with your meeting" tool: notes-steered output is qualitatively different
- Three live tabs keep Ask's hard-won UX (ADR-018) intact while making Notes the primary surface
- No new tables, single-column migration, no repository churn
- Plaintext keeps implementation cost low and ships in v0.6 alongside meeting recording
- Auto-save with no save button matches Char-grade UX baseline
- Crash-recovery extension is trivial: notes ride the existing ADR-019 lock file
- Pre-meeting toast upgrade reuses calendar metadata we already fetch
- Summary snapshot keeps history immutable — same guarantee ADR-013 provides for prompts

### Negative

- **Three tabs in a small floating panel risks feeling cramped.** Mitigated by Notes default, tab-label collapse strategy at narrow widths (§1), and state-bearing tab labels at wider widths. If Phase 2 usability testing shows users switching too frequently, the collapsible-transcript-ticker-inside-Notes pattern is a planned escape hatch with a defined trigger threshold (~3+ switches/min).
- **No inline formatting during the meeting.** Plaintext + slash commands cover headings/labels via plaintext markers; bold/italic/lists are not available. Char's TipTap renders formatted blocks live; ours render raw `**Action:**` characters until post-meeting markdown rendering ships (Future Work). Users coming from Char will experience this as a visual regression. Acceptable v0.6 compromise; markdown rendering is one of the first follow-up PRs.
- **Customized clones of built-in prompts will not gain `{{userNotes}}` automatically.** Users who cloned a built-in into a custom prompt for editing will continue to see their custom prompt produce notes-blind summaries. There is no migration path that touches custom prompts (by design — we don't rewrite user content). The new "Memo-Steered Notes" built-in is the recommended path for users who want notes-aware summaries; the prompt library UI surfaces this via copy on the new prompt's card.
- **One more thing to do during a meeting.** Whether to type notes is now a live decision. Placeholder copy nudges; no force.
- **First slash menu in the codebase.** Local to the Notes pane, intentionally not generalized. Future menus (e.g., for the dictation overlay) would copy the pattern, not share infrastructure. NSPanel-specific implementation pitfalls flagged in §7.
- **Updated built-in prompts affect existing users' default outputs.** The new "Memo-Steered Notes" prompt is additive and respects the auto-run guard (§5). Updates to other built-in prompts that thread `{{userNotes}}` are guarded by graceful empty-state copy so existing users see no regression when they take no notes.
- **Soft length cap of 8,000 words is enforced at the UI/summary layer, not the schema.** Users can technically persist longer notes in the database (the column is unbounded), but only the first 8,000 words feed the summary prompt. The full notes remain visible in the post-meeting view. A user who writes 15,000 words and then complains the summary is incomplete is a real possible support load — mitigated by the inline footer warning at 7,500 words.

### Neutral

- LLM cost unchanged. Notes flow into existing summary calls; no new calls fire.
- Privacy posture unchanged. Notes are local-only text.
- ADR-018 Ask tab unchanged. Live → persisted handoff continues to work.
- ADR-019 recovery unchanged structurally; the lock file gains one field.

## Implementation

### Core (MacParakeetCore)

- Migration: add `userNotes TEXT` to `transcriptions` (nullable, default NULL)
- `Transcription` model: add `userNotes: String?`
- `TranscriptionRepository`: read/write the new column
- `MeetingRecordingService` *(extended)*: new actor-isolated APIs `updateNotes(_:)` (debounce write target — merges into in-memory lock-file struct, atomically rewrites the file without changing `state`) and `persistNotes(_:)` (called at finalize; writes notes to `transcriptions` row in the same transaction as transcript metadata). All `recording.lock` writes are serialized through this actor — no other component touches the file.
- `MeetingRecordingLockFileStore`: extend JSON schema with `notes: String?` decoded via `decodeIfPresent`; **no schema version bump** (additive change). Notes decoded as a separate `try?` step so a malformed value cannot block recovery of the audio metadata. Document the future-bump strategy in source comments (any future bump must relax the `==` version guard to `>=`).
- `MeetingRecordingRecoveryService`: surface restored notes onto the recovered VM via a `restoreNotes(_:)` entry point.
- `PromptTemplateRenderer` *(new)*: `{{key}}` substitution. Single-pass simultaneous: all replacements collected, applied atomically. Empty-string fallback for missing keys. Adversarial-input tests (user notes containing `{{transcript}}` literals) verify single-pass semantics.
- `Prompt.builtInPrompts()`: add "Memo-Steered Notes" prompt; update copy on existing built-ins to optionally reference `{{userNotes}}` (per-prompt judgment per Rationale §"Which prompt classes benefit").
- Auto-run insertion guard: when seeding the new prompt, set `isAutoRun = true` only if at least one existing prompt currently has `isAutoRun = true`; otherwise insert with `isAutoRun = false`.
- `Summary` model: add `userNotesSnapshot: String?`
- `SummaryRepository`: read/write the snapshot column

### ViewModels (MacParakeetViewModels)

- `MeetingNotesViewModel` *(new, `@MainActor @Observable`)*: owns `notesText: String` with `private(set)` external visibility (only `TextEditor` `$binding` mutates it). Debounced 250ms idle writes call `MeetingRecordingService.updateNotes(_:)` — never touches the lock file directly. Exposes `commit()` for finalize, `restore(_:)` for recovery. Soft-cap warning surfaces at 7,500 words.
- `MeetingRecordingPanelViewModel` (extended): compose `notesViewModel`; `LivePanelTab` gains `.notes`; default selection becomes `.notes`; tab-state hint values exposed for view binding (used at default panel widths; collapsed at narrow widths per §1).
- `SummaryViewModel`: read `userNotes` from row at generation; truncate to 8,000-word soft cap *for the prompt only* (full notes preserved); thread into `PromptTemplateRenderer`; record snapshot on resulting `Summary`; surface a "Notes truncated for summary" banner when truncation occurs.

### View layer (MacParakeet)

- `LiveNotesPaneView` *(new)*: SwiftUI `TextEditor`, placeholder, focus management, **in-view slash-command overlay** (NOT a SwiftUI `.popover`) anchored to the editor frame; key events intercepted via `onKeyPress` (drop to `NSTextView` wrapper if `onKeyPress` is insufficient inside `KeylessPanel`). Footer notice for soft-cap warning at 7,500 words.
- `MeetingRecordingPanelView`: tab bar grows to three; ⌘3 binding; default selection logic; tab labels render with state hints at default widths and collapse to plain nouns + tooltips at the 360px minimum.
- `SlashCommandOverlayView` *(new, local to Notes)*: in-view overlay (not popover), arrow-key navigation, Escape dismiss, Return commit. Receives all key events from the parent editor's `onKeyPress` interceptor; never owns first responder.
- `MeetingCountdownToastView` (extended): rich variant for calendar-triggered starts (title, attendees count, video link badge, description preview, `⌘1 = Notes` hint); manual variant unchanged.
- `TranscriptResultView` (touched): summary detail view treats `userNotesSnapshot` NULL or empty identically — omits the "Notes used" section entirely.

### Wiring (MacParakeet App)

- `MeetingRecordingFlowCoordinator`: instantiate `MeetingNotesViewModel`, pass to panel VM, hook lock-file persistence, commit notes to row at finalize, restore on recovery
- `AppEnvironmentConfigurer`: wire dependencies as above

### Tests

- Migration: column exists, accepts NULL, persists round-trip
- `PromptTemplateRenderer`: substitution, missing-key fallback, empty-key fallback, **single-pass adversarial input** (user notes containing literal `{{transcript}}` do not trigger second-pass substitution; the literal survives unchanged)
- `MeetingNotesViewModel`: debounce timing, commit on finalize, cancel safety on stop-without-save, soft-cap warning fires at 7,500 words
- `MeetingRecordingService.updateNotes(_:)`: serializes with state-transition writes (concurrent state change + notes write does not corrupt the lock file or revert the state)
- Lock-file round-trip: notes persisted and restored; **old-format lock file** (no `notes` key) decodes with `notes = nil`; **malformed `notes` field** decodes with `notes = nil` and audio metadata still recovers
- `MeetingRecordingRecoveryService`: recovered session opens with restored notes
- `SummaryViewModel`: `userNotes` flows into rendered prompt; snapshot recorded on `Summary`; **8,000-word truncation** applies to prompt input only (full notes preserved on row); banner surfaces when truncation occurs
- Slash command literal-string insertion: `/action` inserts the literal `**Action:** ` characters (not interpreted as markdown by the editor)
- Built-in "Memo-Steered Notes" prompt rendering with empty `userNotes` (graceful)
- Built-in "Memo-Steered Notes" prompt rendering with non-empty `userNotes`
- Existing prompts unchanged when `userNotes` is empty (no regression on default output)
- Auto-run insertion guard: when seeded into a database with zero auto-run prompts, the new prompt is inserted with `isAutoRun = false`; when seeded with at least one auto-run prompt, inserted with `isAutoRun = true`
- `Summary` detail view: NULL `userNotesSnapshot` and empty-string snapshot both render the section omitted (not an empty block)

## Phased Rollout

Single PR; phased commit clusters so review can walk it linearly:

1. **Phase 1 — Schema + plumbing (no UI):** migration, model fields, `PromptTemplateRenderer`, prompt updates, `SummaryViewModel` integration, tests
2. **Phase 2 — Notes pane + auto-save + recovery:** view + VM, panel restructure to three tabs, lock-file integration, recovery integration, tests
3. **Phase 3 — Slash commands + tab polish:** popover, command insertion, tab state-hint labels, title auto-reveal animation, optional one-line transcript ticker inside Notes (evaluate before merge)
4. **Phase 4 — Pre-meeting + degradation copy:** rich countdown toast for calendar-triggered starts, STT-failure copy refinement, speaker color tokens in live transcript
5. **Phase 5 — Docs:** ADR status flip → Implemented, `spec/02-features.md`, `spec/README.md`, `CLAUDE.md`, `MEMORY.md` updates, test counts. Note: a reviewer reading this ADR mid-PR (after Phases 1-4 commits have landed) will see `Status: Proposed` until this final phase. The implication is intentional — the spec is not "implemented" until the docs phase verifies the code matches the spec, and the ADR's primary audience is future readers who will encounter it post-merge.

## Future Work

- **Rich-text notes upgrade.** Wrap `NSTextView` for SwiftUI; ship bold/italic/headings/lists. Re-evaluate after v0.6 ships if users ask. Plaintext + slash commands is the v0.6 floor.
- **Markdown rendering of notes in detail view.** Notes show as plaintext during a meeting; could render as markdown post-meeting in `TranscriptResultView`.
- **`{{participants}}` and `{{calendarTitle}}` template variables.** Calendar metadata is on hand for auto-started meetings; thread into prompts so summaries reference attendees by name. Defer until at least one built-in prompt needs it.
- **Notes versioning / edit history.** Currently overwrites. Promote `userNotes` column to a `meeting_notes` table when anyone asks.
- **Export notes alongside transcript.** DOCX/PDF/JSON export currently dumps transcript + summary; notes slot in naturally.
- **Slash menu expansion.** `/q` for question, `/!` for blocker, `/agenda` to drop in calendar event description. Defer; ship the minimal three first and let usage signal demand.
- **Notes-as-prompt mode.** A future built-in prompt that takes only the notes (no transcript) and structures them — useful for users who write detailed notes and want a tight, transcript-less view.
- **Collapsible transcript-ticker inside Notes.** One-line "…last sentence…" strip at the bottom of the Notes tab, expandable on click. Char's footer pattern, applied inside our tab structure. Try in Phase 3; evaluate before merge.
- **Ask conversation persistence.** Open since ADR-018. Notes get crash recovery; Ask still doesn't. Lower stakes (conversational scratch vs. user-authored intent), so still deferred.
