# Library UI polish — implementation plan

Status: approved for implementation and PR/merge on September 8, 2026.
Base: origin/main edfaa4889b8beac34b28712829d3850f88bd8fd3.

## Goal
Make Library classification and status legible, compact, and consistent while preserving current card structure, persistence, filtering semantics, and actions.

## Settled behavior
- Label assignment popover: full-width search at top; selected chips in separate wrapping area; compact content-sized container with bounded scrollable results. Display available labels even with empty query. All matches reachable (remove prefix(4)); create row near search for valid new label. Preserve create/assign/remove/error behavior. Keyboard search/Return selection, Escape dismissal, focus, and VoiceOver names must work.
- Labels use one shared identity-based color resolver across cards, list, detail, filter, selected editor chips, suggestions, prompt targeting. Honor supported explicit stored tokens including blue. Missing/unknown tokens map deterministically from UUID bytes, never index, name, hashValue. No migration, stored value rewriting, or color picker.
- Filter: searchable vertical rows with color dot, label name, selection check; compact Labels/count trigger and Clear action. Show selected option. Explain Match any selected label. Preserve repository OR semantics, selected filters through search, and distinguish clearing query/filter from removing an assignment. No new Any/All mode or persistent row of every filter pill.
- Routine audio state: remove repeated Audio saved/removed text pills from grid/list. Use a small accessible status icon in existing metadata layout, with tooltip and focusable/activatable explanation for unavailability. Existing item audio actions remain; do not add playback button plumbing just for this pass. Missing audio and partial capture retain explicit amber warnings. No retention/files/database changes. Removed means no retained path, not proof of user deletion.
- Favorite: small persistent filled amber star near title for favorited items in grid/list/detail, tooltip and accessibility Favorite. Passive marker plus existing context menu; no empty stars on all other items. Preserve toggling/filter persistence. Applies to recordings, imports, URLs.
- Preserve current card dimensions/thumbnails. Compact-card redesign and generated covers belong elsewhere.

## Source map
MeetingClassificationControls.swift: editor232–364, fixed340x210 popover655–669, tint860–870. Positional fallback also used in badges/filter/prompt views. MeetingAudioStateChip.swift; TranscriptionThumbnailCard.swift; MeetingRowCard.swift; TranscriptResultView.swift; PromptLibraryView.swift.

## Invariants and verification
UI presentation only: no public CLI signature or schema changes, no core capture processing edits, no personal data or private screenshot fixtures. Use existing parakeetAction style. Cover empty/many/long labels and explicit/unknown stable colors. Check filter selection and audio warning semantics with meaningful focused tests, build Swift6 clean, inspect native synthetic-data presentation if practical. User will perform live visual QA after merge.

## Ordered execution and ownership
Worker owns this isolated worktree, implementation, relevant focused tests, and spec/04-ui-patterns.md updates. Other worktrees are active: never modify or revert them. Read current governing specs before edits; add final behavior there, not new REQ IDs. No full swift test locally: root owns the single final combined full-suite run after integration. Do not launch/restart user's app; root coordinates final rebuild. Limit Swift build concurrency to avoid process exhaustion (e.g. --jobs 4).

Commit reviewed-ready work with rich intent, push branch and open PR against main, but do not merge; root reviews/checks exact head and owns merge. Use explicit file staging. Record focused commands/counts, compile result, changes/deviations, and remaining native QA. Checkpoint a durable commit after focused checks; do not invoke a gate that silently runs another full suite.

## Review and landing
Independent review of UI state, accessibility and failure paths; fix findings then relevant focused checks. Hosted CI on current head; merge this PR before recording-cover PR. Root will use direct focused checks plus independent review because two automatic baseline full-suite gates would duplicate the single combined local suite budget. No website deployment or release publication.
