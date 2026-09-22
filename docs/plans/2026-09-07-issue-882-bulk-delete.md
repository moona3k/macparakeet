# Fix Words: bulk deletion interaction study

2026-09-07. Approved HTML prototype. The screenshots show the proposed interaction, not the native app implementation.

[Open the comparison](2026-09-07-issue-882-bulk-delete.html) · [Issue #882](https://github.com/moona3k/macparakeet/issues/882)

## Design direction

Preserve the current Custom Words sheet reached through Vocabulary > Fix words > Manage words. Add a quiet **Select…** action beside the rule count. In selection mode, replace the enable switches with checkboxes and hide the individual trash buttons. Reuse the list header for Select all, selection count, Delete…, and Cancel. Keep the action header visible while scrolling a long list.

This gives bulk deletion one entry point without adding persistent checkboxes, a new toolbar, or a separate Delete all action. Selecting all and deleting uses the same confirmation as selecting a few. The Add Rule form is temporarily hidden during selection.

```text
Normal:     Word Rules                         6 rules  Select…
            [on/off]  word                              [trash]

Selecting:  [ ] Select all          0 selected  Delete…  Cancel
            [ ]       word
```

Use count-specific confirmation, leave Cancel focused initially, and preserve selection when cancelling the alert. Leaving selection mode clears the selection without changing enabled states. With a search active, Select all means all matching rules; changing the search clears selection so hidden rows cannot be deleted accidentally. The prototype announces that reset. These are proposed behaviors for discussion.

## Visual plan and brief review

- Palette: outer canvas `#edf0f3`, app background `#fafaf7`, grouped rows `#ffffff`, primary text `#1a1a1a`, secondary text `#6b6b6b`, app coral `#e86b3b`. Red is confined to destructive actions.
- Type: the macOS system font stack throughout; 22px sheet title, 14px word text, 12px secondary copy. Preserve existing uppercase section labels inside the recreated app.
- Layout: two aligned sheets, each up to the native 640px width and 560px height. Stack on narrow screens. Review controls and explanation sit outside the app mockups.
- Restraint: reproduce the existing visual language rather than redesign the vocabulary page. Selection replaces existing controls in place; no second control column or permanent bulk-action bar.

## Source fidelity

The current panel is an HTML recreation from development main at `a5cd486a8958610f559697e31aba765930574607`, not a screenshot or a claim about the installed app. Sample vocabulary is invented. SwiftUI rendering, system alert styling, and fonts may differ slightly.

- [CustomWordsView](https://github.com/moona3k/macparakeet/blob/a5cd486a8958610f559697e31aba765930574607/Sources/MacParakeet/Views/Vocabulary/CustomWordsView.swift): header, search, grouped rows, switches, single-item deletion, and add form.
- [VocabularyComponents](https://github.com/moona3k/macparakeet/blob/a5cd486a8958610f559697e31aba765930574607/Sources/MacParakeet/Views/Vocabulary/VocabularyComponents.swift): spacing, section labels, fields, and trash icons.
- [VocabularyView](https://github.com/moona3k/macparakeet/blob/a5cd486a8958610f559697e31aba765930574607/Sources/MacParakeet/Views/Vocabulary/VocabularyView.swift): entry point and 640 × 560 sheet size.
- [DesignSystem](https://github.com/moona3k/macparakeet/blob/a5cd486a8958610f559697e31aba765930574607/Sources/MacParakeet/Views/Components/DesignSystem.swift): colors and typography.

The proposed sticky list header is a deliberate change for large lists. All interactions affect only the page's in-memory sample data; reloading or resetting restores it.

## Prototype verification

Checked in Chrome at 1440 × 1000 and 390 × 844. Verified individual deletion, selection, mixed and all-selected states, count-specific confirmation, cancellation and Escape, preservation of enable states, filtered selection, deletion to the empty state, adding a word, duplicate feedback, and reset. Command-A selects rules in selection mode while text fields retain their normal selection behavior.

An injected 1,024-word sample confirmed that Select all covers every match and that the action header remains visible at the bottom of the list. A narrow-screen overflow with the longer count was corrected and rechecked. Screenshots of the normal, selection, confirmation, and mobile states were visually reviewed. Browser checks found no script errors; the deletion flow also worked offline without external requests.

This validates the HTML interaction only, not SwiftUI, database deletion, or the shipped app. Preview screenshots: [comparison](2026-09-07-issue-882-preview/current-proposed.png), [selection](2026-09-07-issue-882-preview/selection.png), [confirmation](2026-09-07-issue-882-preview/confirmation.png).
