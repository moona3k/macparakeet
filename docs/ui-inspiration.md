# MacParakeet UI Inspiration

> Status: **ACTIVE**
> Last researched: 2026-05-15
> Purpose: Convert strong open-source app references into practical MacParakeet
> UI direction, especially for Transcribe, Library, and transcript review.

MacParakeet should stay native, quiet, and fast. The useful inspiration is not
"make it look like another app." It is: study how excellent apps make common
workflows obvious, reduce chrome, handle dense information, and keep advanced
power close without making the first screen heavy.

The current UI source of truth remains [`spec/04-ui-patterns.md`](../spec/04-ui-patterns.md)
and the brand source of truth remains [`docs/brand-identity.md`](brand-identity.md).
This document is a product/design map for future polish work.

For the deeper repo-by-repo evidence behind these recommendations, see
[`docs/research/open-source-ui-reference-audit-2026-05.md`](research/open-source-ui-reference-audit-2026-05.md).

## Current Priority

1. **Transcribe** needs to feel more like a confident capture hub.
2. **Library** needs stronger browsing, filtering, and source-aware density.
3. **Transcript Result** needs better reading, playback, review, and AI-output
   organization.
4. **Dictation History** is already in good shape. Keep it, then add small
   power-user refinements only where they clearly help.

## Study Set

### Maccy

- Site: https://maccy.app/
- Repo: https://github.com/p0deje/Maccy
- Why it matters: extreme utility discipline. It is keyboard-first, instant,
  searchable, and visually lightweight.
- MacParakeet application: search, command actions, copy flows, quick open,
  Library keyboard navigation, and Dictation History polish.

Maccy is the reference for "a useful thing should take one thought." In
MacParakeet, the equivalent is: search a transcript, copy text, replay audio,
open the source file, favorite, delete, export, and start a new transcription
without a hunt.

### NetNewsWire

- Site: https://netnewswire.com/
- Repo: https://github.com/Ranchero-Software/NetNewsWire
- Why it matters: calm sidebar/list/detail information architecture that holds
  up with a large personal library.
- MacParakeet application: Library browsing, source grouping, search results,
  date sections, unread/new-style state equivalents, and split-view discipline.

NetNewsWire is the best model for MacParakeet's Library because both products
manage a growing personal archive. The lesson is not the RSS UI itself. The
lesson is the hierarchy: source list, compact row metadata, readable detail,
and very little decoration.

### IINA

- Repo: https://github.com/iina/iina
- Why it matters: native-feeling media controls, playback state, scrubbers,
  video surface behavior, and unobtrusive overlays.
- MacParakeet application: audio/video transcript review, scrubber polish,
  subtitle-style timed text, media panel behavior, and playback affordances.

IINA is the strongest reference for transcript review when the transcript is
also a media object. MacParakeet should make it obvious where playback is,
where the current word/segment is, and how text and audio/video relate.

### CotEditor

- Site: https://coteditor.com/
- Repo: https://github.com/coteditor/CotEditor
- Why it matters: mature macOS-native text editing and document behavior.
- MacParakeet application: transcript reading, transcript editing, Live Notes,
  post-meeting notes, selection, find, typography controls, and text layout.

CotEditor is the reminder that transcripts are documents, not just output
blocks. Text selection, find, keyboard shortcuts, line wrapping, copy behavior,
and editing affordances should feel like macOS.

### Ice

- Repo: https://github.com/jordanbaird/Ice
- Why it matters: polished menu-bar utility behavior with restrained native
  settings and small persistent controls.
- MacParakeet application: menu bar status, idle pill, recording pill, countdown
  toasts, and system-level preferences.

Ice is useful because MacParakeet is partly a normal app and partly a system
utility. The small surfaces need to feel trustworthy, not decorative.

### Loop

- Repo: https://github.com/MrKai77/Loop
- Why it matters: a distinctive floating interaction can make a utility feel
  crafted without turning the whole app into a themed dashboard.
- MacParakeet application: recording pill, meeting tile, completion state,
  subtle motion, and spatial overlays.

Loop is a good craft reference for MacParakeet's expressive surfaces. Use that
energy sparingly: the main window should stay calm; the floating recording
surfaces can carry the magic.

### CodeEdit

- Repo: https://github.com/CodeEditApp/CodeEdit
- Why it matters: native Swift app structure, larger SwiftUI/AppKit composition,
  settings, windowing, and modular packages.
- MacParakeet application: app shell organization, package boundaries, settings
  surfaces, and editor-like panes.

CodeEdit is more useful as an architecture reference than as a direct visual
target. It is worth studying when MacParakeet needs a more sophisticated text
or split-pane surface.

### Zed and Ghostty

- Zed repo: https://github.com/zed-industries/zed
- Ghostty repo: https://github.com/ghostty-org/ghostty
- Why they matter: fast local tools with strong separation between core engine
  and native shell.
- MacParakeet application: preserve the current Core/ViewModels/App split,
  keep latency visible, and avoid turning UI polish into core coupling.

These are not SwiftUI design references. They are references for seriousness:
the app feels fast because the architecture protects the critical path.

## Surface Direction

### Transcribe

Current shape: a unified capture hub with YouTube, file drop, and meeting
recording tile.

Direction:

- Make the first screen read as "capture something now" within one second.
- Keep three capture modes, but make each mode's state richer:
  YouTube validation, file drag readiness, meeting permission/recording status.
- Add recent/retry affordances only if they reduce repeat-work friction.
- Treat progress as a pipeline, not a spinner: fetch, normalize, transcribe,
  save, summarize when applicable.
- Keep the inspirational quote low priority. The capture task should own the
  screen.
- Prefer visible state over explanatory text. Disabled, ready, active, and done
  should be readable from icons, color, and placement.

References:

- Maccy for immediacy.
- Ice for utility restraint.
- Loop for the meeting tile's kinetic craft.

### Library

Current shape: filter bar, thumbnail grid for most transcriptions, date-grouped
list for meetings.

Direction:

- Make Library source-aware. Videos can use thumbnails; audio files and
  meetings often work better as rows with strong metadata.
- Consider a list/grid toggle, with the default chosen by source type:
  video grid, audio/list, meetings/date list.
- Promote metadata that helps scanning: source type, title, duration, date,
  speakers, summary availability, favorite state, and audio availability.
- Make search results feel like a real mode, not just a filtered grid.
- Add keyboard navigation and quick actions: open, copy transcript, export,
  favorite, reveal audio, delete.
- Use date groups consistently where they improve orientation.
- Keep favorites as a real retrieval feature, not just a decorative star.

References:

- NetNewsWire for personal archive hierarchy.
- Maccy for fast search and action.
- CotEditor for text/document behavior once a result opens.

### Transcript Result

Current shape: playback-aware detail view with transcript, prompt results, chat,
exports, editing, speaker support, and video split mode.

Direction:

- Make the transcript the center of gravity. AI, export, and playback should
  orbit it, not compete with it.
- Keep playback persistent. The user should never lose the current media state
  while switching between transcript, prompt results, and chat.
- Strengthen text-to-audio connection:
  current segment highlight, click-to-seek, auto-scroll pause, and clear resume.
- Add an outline when data exists: chapters, speaker turns, generated sections,
  or timestamp clusters.
- Separate "generated artifacts" from "conversation" more clearly:
  prompt results are documents; chat is interaction.
- For meetings, make user notes visually distinct from AI-generated content.
- Keep retranscribe/export/edit actions available, but avoid crowding the main
  reading pane.

References:

- IINA for media controls and playback confidence.
- CotEditor for transcript-as-document polish.
- NetNewsWire for detail-pane hierarchy.

### Dictation History

Current shape: grouped chronological list, search, hover actions, bottom audio
player, stats subtab.

Direction:

- Keep the current direction. It already matches the product: short snippets,
  quick retrieval, full text visible, fast copy/replay.
- Small polish ideas:
  keyboard selection, copy focused row, play focused row, reveal raw/clean
  difference more clearly, and export selected dictations.
- Avoid turning Dictation History into another full library. Dictations are
  lightweight voice snippets; the surface should stay lightweight too.

References:

- Maccy for retrieval speed.
- NetNewsWire for grouped list calm.

## Architecture Notes

MacParakeet already has the right broad shape:

- `MacParakeetCore` owns durable logic and should not gain UI ownership.
- `MacParakeetViewModels` keeps app state testable outside the GUI.
- `Sources/MacParakeet/Views` owns SwiftUI/AppKit composition.
- `DesignSystem` and `parakeetAction(_:)` should carry shared styling intent.

Future UI work should keep that shape. For example:

- Library browsing improvements should land primarily in
  `TranscriptionLibraryViewModel` plus focused Library views.
- Transcript review improvements should extend `MediaPlayerViewModel`,
  transcript cache/segment helpers, and local view components before inventing
  broad shared abstractions.
- Transcribe polish should keep recording/transcription state in existing
  view models and coordinators, not in view-only state.

## Backlog Candidates

### P0

- Source-aware Library layout: video grid, audio/list, meeting/date list.
- Stronger Transcript Result reading mode with persistent playback and clearer
  segment focus.
- Transcribe pipeline progress that shows concrete stages and lets users keep
  working.

### P1

- Library keyboard navigation and quick actions.
- Search results mode with better highlighting and source metadata.
- Transcript outline or side rail when timestamps/speakers/chapters exist.
- Clearer prompt-result document organization separate from chat.

### P2

- Optional visual polish for the meeting tile and recording pill.
- More refined empty states for Library and Transcribe.
- Dictation History keyboard shortcuts and selected-row commands.
- Typography controls for long transcripts.

## Design Warnings

- Do not make the main window look like a marketing page.
- Do not overuse sacred geometry or animated ornament in dense reading views.
- Do not make every feature a card.
- Do not spend coral on every interactive element; keep it for the primary
  action or active recording state.
- Do not let visual polish weaken native macOS behavior: selection, focus,
  keyboard commands, search, windowing, and accessibility matter more.
