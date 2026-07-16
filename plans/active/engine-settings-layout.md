# Engine settings layout: one Speech Engine section, one advanced disclosure

Status: active (2026-07-16)
Owner: Daniel (design), Codex (implementation)
Scope: Settings → Engine tab UI/copy plus navigation that expands and scrolls
to the advanced control. No persistence, routing, or engine-lifecycle changes.

## Problem

The engine split (live engine vs. engine for post-hoc transcription) shipped
to `main` with a layout that leaks the advanced concept into the default path:

1. The primary card grid is titled **"Live Speech"**, but with the override
   off (the default, ~all users) that choice governs *everything* — dictation,
   preview, meetings, files, media. Users must understand the live/final
   split just to parse the default screen.
2. The override is a full top-level **"Advanced"** card (icon + toggle +
   segmented picker) — heavy for one setting, and physically separated from
   the engine grid it modifies.
3. **"Final transcripts"** is pipeline vocabulary. For YouTube/media/file
   drag-drop there is no "final vs. normal" transcription; even for meetings
   it is confusing. The honest user-facing dichotomy is **live speech** vs.
   **recordings & files**.
4. Nothing tells the user *why* they'd use the override. The reason is:
   recordings have no real-time constraint, so you can trade wait time for
   accuracy or language coverage.
5. The toggle + segmented control render in system blue inside an otherwise
   all-coral pane.

Approved mockup (both states): internal artifact
`engine-settings-proposal` — the copy below is the source of truth; the
mockup is directional for layout, not pixel-exact.

## Design decisions (settled — do not re-litigate)

1. **Rename** the selector card: title `Speech Engine`. Subtitle is dynamic:
   - Override off: `Your selected engine handles dictation, meetings,
     recordings, and files.`
   - Override on (example): `Parakeet handles dictation and live preview ·
     Nemotron handles recordings and files.` (interpolate the two engine
     display names; use the `·` separator).
2. **Delete the separate "Advanced" card.** Its function moves into a collapsed
   `Advanced transcription` disclosure *inside* the Speech Engine card, below
   the tiles/banners and separated by a `Divider()`. The collapsed summary says
   either `Optionally use a different engine for recordings & files.` or names
   the active override. Expanding it explains the default one-engine model and
   reveals:
   - Label: `Recordings & files`
   - Control: a **menu-style `Picker`** (not segmented, not a toggle) whose
     first option is `Same as <SelectedEngine>` (the default) followed by the
     engine display names. The inherited option maps to
     `usesDifferentFinalTranscriptionEngine == false`; picking an engine sets
     the flag true and selects that engine. Picking the same engine as live
     is equivalent to the inherited option — collapse it back rather than
     showing a degenerate split.
   - Explanation: `MacParakeet uses your selected speech engine for everything
     by default. You can choose another engine for completed meeting recordings,
     files, media, and URLs—for example, for higher accuracy or broader language
     support when a longer wait is okay.`
   - Hint text under the row, override off:
     `Using <LiveEngineName> for all speech recognition.`
   - Hint text, override on:
     `Dictation and live preview stay on <LiveEngineName>.`
   - Keep the existing error text
     (`viewModel.engine.transcriptionSpeechEngineError`) rendering beneath.
3. **Role chips on tiles when split.** When the override is active, the live
   engine's tile shows a filled accent chip `Live` (replacing the checkmark)
   and the recordings engine's tile shows an outlined accent chip
   `Recordings`, with a lighter selected-border treatment on the recordings
   tile. When the override is off, tiles look exactly as today (checkmark on
   the selected tile). Chips must be VoiceOver-legible (e.g. accessibility
   label "Selected for live speech" / "Selected for recordings and files").
4. **Model-variant cards get role context when split.** The per-engine model
   cards (`Parakeet Model`, `Nemotron Model`, `Cohere Model`) already render
   only for engines in use via `usesSpeechEngine(_:)` — keep that. When the
   override is active and the card's engine serves exactly one role, append
   the role to the subtitle, e.g. `Used for live speech.` / `Used for
   recordings & files.` When the override is off (or the engine serves both
   roles), no role line.
5. **Accent discipline.** No system-blue controls in this pane. The menu
   picker and any chips use the existing `DesignSystem.Colors.accent` /
   standard settings styling. (Removing the `.switch` toggle and `.segmented`
   picker resolves the current blue.)
6. **Search index follows the rename.** Update `SettingsSearchIndex` entries
   `engine.selector` (title `Speech Engine`, subtitle naming the default
   one-engine behavior) and `engine.transcriptionSelector` (title
   `Recordings & Files Engine`, keywords gain `recordings`, `files engine`,
   `accuracy`, `slower`, keep the old terms `final transcript`, `advanced`,
   `same as live` as findable synonyms). Point `engine.transcriptionSelector`
   at the disclosure's dedicated anchor, expand it when that search result or
   external destination is opened, and scroll the control into view.

## Non-goals / must-not-change

- No changes to `EngineSettingsViewModel` semantics, persistence keys,
  routing, or engine lifecycle. This is a view + copy restructure; small
  view-model *additions* (e.g. a derived binding for the menu picker) are
  fine, in `MacParakeetViewModels` with tests.
- Download banners, switch banners, unavailable reasons, first-optimize flow,
  Whisper language card, Local Models card: behavior unchanged.
- Do not touch Cohere gating (`AppFeatures.cohereEngineEnabled`) beyond
  keeping the menu options consistent with today's
  `transcriptionEngineOptions` filter.
- Tiles' strengths/taglines/help text: unchanged in this PR (copy pass for
  tile bullets is a separate task).

## Where the code lives

- `Sources/MacParakeet/Views/Settings/SettingsView.swift` — `engineSelectorCard`
  (~line 2038 on `main`), `transcriptionEngineCard` (~2162, delete/absorb),
  `engineTab` composition (~399–417, ids `engine.selector` /
  `engine.transcriptionSelector`), per-engine model cards (~2234, ~2359,
  ~2460), `engineSelectorCardStatus` (~2633).
- `Sources/MacParakeet/Views/Settings/Components/` — `EngineOptionTile` lives
  here; extend for the role chip.
- `Sources/MacParakeetViewModels/SettingsSearchIndex.swift` (~275–300).
- `Sources/MacParakeetViewModels/` engine settings view model — for the
  derived "recordings engine or same" selection if added.
- Tests: `Tests/MacParakeetTests/ViewModels/SettingsSearchIndexTests.swift`
  plus existing engine-settings view-model tests near the code they cover.

## Acceptance criteria

1. Engine tab shows: Speech Engine card (tiles + variant/download banners +
   divider + collapsed Advanced transcription disclosure), then per-engine
   model cards for engines in use, then existing Whisper language / Local
   Models cards. No standalone Advanced card remains.
2. Override off: the collapsed summary explains that a different recordings
   engine is optional; expanding it shows `Same as <SelectedEngine>` and the
   one-engine explanation above; tiles look as today.
3. Override on: menu shows the engine name; subtitle narrates the routing;
   chips `Live` / `Recordings` appear on the right tiles; both engines'
   model cards render with role subtitles.
4. Selecting the live engine in the recordings menu returns to the inherited
   state (flag false), not a degenerate A/A split.
5. `swift build` clean; focused tests green
   (`swift test --filter SettingsSearchIndexTests` plus the engine settings
   view-model suites touched); full `swift test` once as the final gate.
6. Accessibility: chips and the menu row have sensible VoiceOver labels;
   keyboard focus works on the menu.
7. Search for "final transcript", "recordings", and "accuracy" expands and
   scrolls to the Advanced transcription disclosure; "engine" lands on the
   primary selector.
