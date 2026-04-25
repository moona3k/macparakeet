# ADR-020: Live Meeting Notepad + Memo-Steered Summaries

> Status: Proposed
> Date: 2026-04-25
> Related: ADR-013 (prompt library + multi-summary), ADR-014 (meeting recording), ADR-017 (calendar auto-start), ADR-018 (live meeting Ask tab), ADR-019 (crash-resilient meeting recording)

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

### 2. Plaintext editor for v0.6

The Notes pane is a `TextEditor` with placeholder copy. No rich-text, no NSTextView wrapper, no markdown rendering during the meeting. Slash commands (§7) cover the highest-signal structuring needs (action items, decisions, timestamps) without a formatting infrastructure.

Rich-text is deferred to Future Work. Plaintext is enough to ship the memo→summary mechanic, which is where the user value lives.

### 3. Notes persist on `transcriptions.userNotes`

A new nullable column `userNotes TEXT` is added to the `transcriptions` table via the standard inline-migration path in `DatabaseManager.swift`. One-to-one with the recording; no separate notes table.

Empty notes is a valid state — short meetings, audio-only attention, anything where the user just wanted a transcript. The column is `NULL` when the user wrote nothing.

A separate `meeting_notes` table was considered for future versioning support and was rejected as premature. If multi-version notes ever become a feature, the column can be promoted to a table without breaking history (same shape as the v0.5 `transcriptions.summary` → `summaries` table promotion).

### 4. `{{userNotes}}` template variable threaded into prompt rendering

A minimal `PromptTemplateRenderer` substitutes `{{key}}` markers in a prompt's content with values supplied at render time. Initial keyset:

| Variable          | Source                                              |
|-------------------|-----------------------------------------------------|
| `{{userNotes}}`   | `Transcription.userNotes`, empty string if `nil`    |
| `{{transcript}}`  | The transcript text the prompt would have used today |

This is string substitution, not a template engine. No conditionals, no loops, no helpers. Prompts that reference `{{userNotes}}` must read sensibly when the value is empty (handled by the prompt copy itself, e.g., "If the user took no notes, infer structure from the transcript alone.").

Existing prompts that don't use the variables continue to work — they receive the rendered transcript via the same path the unrendered transcript flowed through before.

### 5. New built-in prompt: "Memo-Steered Notes"

A new built-in prompt is added to `Prompt.builtInPrompts()` and seeded on next launch. Approximate copy:

> *You are summarizing a meeting. The user took these notes during the meeting — treat them as the structure and priorities of the summary. Expand each note with detail from the transcript. If the user wrote nothing, infer structure from the transcript and produce a clean meeting-notes view.*
>
> *USER NOTES:*
> *{{userNotes}}*
>
> *TRANSCRIPT:*
> *{{transcript}}*
>
> *Output:*
> *- Each user note expanded with supporting detail from the transcript*
> *- Action items (only if the transcript supports them)*
> *- Decisions made*
> *- Open questions*

The new prompt is marked `isAutoRun = true` by default for fresh installs, replacing the existing default auto-run prompt. Users with custom auto-run configurations are not migrated automatically — their explicit choices win. The shipped "Meeting Notes" and similar prompts are updated to reference `{{userNotes}}` optionally; the wording must degrade gracefully when notes are empty.

### 6. Snapshot user notes on the summary record

Per the prompt-snapshot principle from ADR-013, each `Summary` record gains a `userNotesSnapshot: String?` column. The value of `userNotes` at the moment of summary generation is captured alongside the existing prompt snapshot. Editing notes after a summary has been generated does not retroactively change that summary's metadata.

This makes summaries self-contained for the same reason ADR-013 made them self-contained: a summary should always accurately reflect what produced it.

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

### 8. Notes auto-save with idle debounce

Every keystroke queues a 250 ms idle debounce. On debounce fire:

- Notes are written to the ADR-019 lock file (`recording.lock` JSON marker, alongside audio fragment metadata)
- Notes are written to a transient field on the in-flight recording session

On meeting finalize, the final notes value is committed to `transcriptions.userNotes` in the same transaction as the transcript and metadata.

There is no save button. There is no dirty indicator. Persistence is invisible.

### 9. ADR-019 lock-file extension carries notes

The `recording.lock` JSON schema gains a `notes: String` field. `MeetingRecordingLockFileStore` reads/writes it; `MeetingRecordingRecoveryService` restores it onto the recovered session at launch time. Recovery flow is otherwise unchanged — the recovered meeting opens with whatever notes were persisted at the last debounce fire before the crash.

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
│ Take notes to shape the summary. ⌥1 = Notes │
│                                            │
│            [Cancel]   [Start Now]          │
└────────────────────────────────────────────┘
```

Manual-start toasts (hotkey, menu bar, panel button) keep the minimal variant — no new friction for paths that already work cleanly.

### 11. Notes are user-authored only

The Notes surface contains exactly what the user typed. Ask responses live in the Ask thread, never in Notes. This is the load-bearing invariant for the memo→summary mechanic: feeding AI-generated text back into AI prompts dilutes the user's voice and produces recursive summaries that gradually drift from intent.

The corollary: there is no "insert this Ask response into Notes" affordance. If the user wants Ask output in Notes, they retype it (which is friction by design — it forces the user to commit to what's worth keeping).

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
        │ MeetingRecordingLockFileStore           │
        │   recording.lock { notes, fragments… }  │  ← ADR-019 file
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

- **Three tabs in a small floating panel risks feeling cramped.** Mitigated by Notes default and state-bearing tab labels. If user testing says it's too much, the collapsible-transcript-footer-inside-Notes pattern is a planned escape hatch.
- **No inline formatting.** Plaintext + slash commands cover headings/labels via plaintext markers; bold/italic/lists are not available. Acceptable v0.6 compromise.
- **One more thing to do during a meeting.** Whether to type notes is now a live decision. Placeholder copy nudges; no force.
- **First slash menu in the codebase.** Local to the Notes pane, intentionally not generalized. Future menus (e.g., for the dictation overlay) would copy the pattern, not share infrastructure.
- **Updated built-in prompts affect existing users' default outputs.** The new "Memo-Steered Notes" prompt is additive (becomes the default auto-run for fresh installs only). Updates to other built-in prompts that thread `{{userNotes}}` are guarded by graceful empty-state copy so existing users see no regression when they take no notes.

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
- `MeetingRecordingLockFileStore`: extend JSON schema with `notes: String`
- `MeetingRecordingRecoveryService`: restore notes onto recovered session
- `PromptTemplateRenderer` *(new)*: `{{key}}` substitution with empty-string fallback for missing keys
- `Prompt.builtInPrompts()`: add "Memo-Steered Notes" prompt; update copy on existing built-ins to optionally reference `{{userNotes}}`
- `Summary` model: add `userNotesSnapshot: String?`
- `SummaryRepository`: read/write the snapshot column

### ViewModels (MacParakeetViewModels)

- `MeetingNotesViewModel` *(new, `@MainActor @Observable`)*: owns `notes: String`, debounced 250ms idle writes, exposes `commit()` for finalize, `restore(_:)` for recovery
- `MeetingRecordingPanelViewModel` (extended): compose `notesViewModel`; `LivePanelTab` gains `.notes`; default selection becomes `.notes`; tab-state hint values exposed for view binding
- `SummaryViewModel`: read `userNotes` from row at generation; thread into `PromptTemplateRenderer`; record snapshot on resulting `Summary`

### View layer (MacParakeet)

- `LiveNotesPaneView` *(new)*: SwiftUI `TextEditor`, placeholder, focus management, slash-command popover at caret
- `MeetingRecordingPanelView`: tab bar grows to three; ⌘3 binding; default selection logic; tab labels render with state hints
- `SlashCommandPopoverView` *(new, local to Notes)*: arrow-key navigation, Escape dismiss, Return commit
- `MeetingCountdownToastView` (extended): rich variant for calendar-triggered starts; manual variant unchanged

### Wiring (MacParakeet App)

- `MeetingRecordingFlowCoordinator`: instantiate `MeetingNotesViewModel`, pass to panel VM, hook lock-file persistence, commit notes to row at finalize, restore on recovery
- `AppEnvironmentConfigurer`: wire dependencies as above

### Tests

- Migration: column exists, accepts NULL, persists round-trip
- `PromptTemplateRenderer`: substitution, missing-key fallback, empty-key fallback
- `MeetingNotesViewModel`: debounce timing, commit on finalize, cancel safety on stop-without-save
- Lock-file round-trip: notes persisted and restored
- `MeetingRecordingRecoveryService`: recovered session opens with restored notes
- `SummaryViewModel`: `userNotes` flows into rendered prompt; snapshot recorded on `Summary`
- Built-in "Memo-Steered Notes" prompt rendering with empty `userNotes` (graceful)
- Built-in "Memo-Steered Notes" prompt rendering with non-empty `userNotes`
- Existing prompts unchanged when `userNotes` is empty (no regression on default output)

## Phased Rollout

Single PR; phased commit clusters so review can walk it linearly:

1. **Phase 1 — Schema + plumbing (no UI):** migration, model fields, `PromptTemplateRenderer`, prompt updates, `SummaryViewModel` integration, tests
2. **Phase 2 — Notes pane + auto-save + recovery:** view + VM, panel restructure to three tabs, lock-file integration, recovery integration, tests
3. **Phase 3 — Slash commands + tab polish:** popover, command insertion, tab state-hint labels, title auto-reveal animation, optional one-line transcript ticker inside Notes (evaluate before merge)
4. **Phase 4 — Pre-meeting + degradation copy:** rich countdown toast for calendar-triggered starts, STT-failure copy refinement, speaker color tokens in live transcript
5. **Phase 5 — Docs:** ADR status flip → Implemented, `spec/02-features.md`, `spec/README.md`, `CLAUDE.md`, `MEMORY.md` updates, test counts

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
