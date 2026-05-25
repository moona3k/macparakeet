# Vocabulary Surface Refinement

> Status: **IMPLEMENTED** — UI polish pass on the Vocabulary tab + Custom Words /
> Text Snippets sheets, holding them to the bar set by the Dictation Stats
> screen. Shipped on branch `design/vocabulary-refinement`; build + `swift test`
> green. Pending visual sign-off + merge.

## Why

The Dictation Stats screen subordinates chrome to data: distinct metrics, one
coral accent (the lead tile), minimal decoration. The Vocabulary surfaces invert
that ratio — high chrome density, low information density. A single search field
sits inside a full icon-tiled card; coral is everywhere, so it signals nothing;
the actual list (the point of the screen) is the least-emphasized element.

This violates the documented coral discipline (`docs/brand-identity.md`: coral is
a *moment of attention*, not chrome) and the "simplicity is the product"
principle.

## Scope

The three reviewed surfaces only:

- `Views/Vocabulary/VocabularyView.swift`
- `Views/Vocabulary/CustomWordsView.swift`
- `Views/Vocabulary/TextSnippetsView.swift`
- `Views/MainWindowView.swift` (sidebar selection tint)

Shared primitives added in `Views/Vocabulary/VocabularyComponents.swift` and a
`parakeetSwitch()` modifier in `Views/Components/ParakeetActionStyle.swift`.

## Changes

### Coherence (P0)
- **One toggle treatment.** `parakeetSwitch()` (coral) everywhere on these
  surfaces — kills the Voice-Return-coral vs list-toggle-blue split.
- **One coral CTA per sheet.** `Add` stays coral; `Done` moves to a neutral
  header-bar button.
- **Drop Total/Visible/Enabled tiles.** Replaced by a single contextual count
  ("3 rules", "2 off", or "2 of 5" while searching).

### Layout & native feel (P1)
- Sheets get a real header bar (title + subtitle + neutral Done).
- The rule/snippet list leads, in one grouped "collection" surface, instead of
  being the third stacked card.
- Search demoted from a card to an inline coral-focus field.
- Vocabulary tab: redundant "Text Processing" summary card replaced by a slim
  plain page header (the chips just restated the Mode card + Pipeline steps).
- Sidebar selection tinted coral so it stops reading as a stray system-blue pill.

### Detail polish (P2)
- Selected Mode card check: green → coral (green read as "valid", not
  "selected").
- Voice Return examples: `micro` → `caption`, more breathing room.
- Snippet usage count: bare "9" → glyph + count badge.
- Snippet rows drop the redundant "Trigger:" prefix.
- Trash glyph warms to red on hover.
- Text fields use a coral focus ring instead of the system blue one.
- Text Snippets "Guidance" card → collapsed "Tips" disclosure.

## Out of scope / follow-ups
- Settings tab shares the icon-tile card + blue `SettingsToggleRow` patterns.
  Not touched here to keep blast radius to reviewed screens; a future pass could
  adopt `parakeetSwitch()` app-wide for full toggle consistency.

## Verification
- `swift build --target MacParakeet` green (85s).
- `swift test` green — full suite exit 0 (no ViewModel/logic changes; views are
  not unit-tested).
- Manual (pending): launch app, eyeball Vocabulary tab + both sheets in
  light/dark — grouped-surface contrast in dark mode, divider inset alignment,
  Add-button vs field height, and coral sidebar-selection weight.
