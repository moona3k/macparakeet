# Host tools

Native Accessibility operations are **tools**. Unique intent compiles and runs without a model. Jev chooses among competing tools; it does not execute them, and it is not a second “are you sure?” on ordinary named clicks.

Pay / delete / send still confirm after a compiled press. A numbered pick is not authority.

## What compiles locally

| Spoken intent | Tool | Notes |
|---|---|---|
| `Save` / `the Save button` / `click Save` | press unique control | Bare names only on a plain window. Overlay rows stay landings. |
| 2–6 same names | numbered list in the panel | Isolated `1` / `two` / `the second one`. `the other one` is not option 1. Rematch by id and label. |
| `click Search` with unique `Search flights` | press (word prefix) | Exact match wins first. `research` does not match `search`. |
| `press return` / `escape` / `tab` | key on the focused field | Not a hunt for a button named Return. `click Return` is the button. Ordinary — no confirm. |
| `type hello` when the field already holds hello | skip | Does not skip when a selection is present. Consecutive type utterances join with a space at the caret. |
| Unique running app | activateApp | `open Settings` prefers a visible Settings *control* if one exists. Help says so. |
| `open Gmail` / YouTube / Maps / Wikipedia / web search | code-owned URL, then fill | Jev never sees `role=url`. |
| Unique Gmail Compose | press | |
| Flights origin / destination / date / unique city / Search | domain plan | Competing cities are landings. |
| `replace X with Y` | precise setValue | Missing or ambiguous source asks; it does not rewrite the whole field. |
| `undo` | restore last owned text edit | Snapshot-local, time-bounded. |
| `click Total $412` when only pixels show it | press on-screen text (`role: "text"`) | Opt-in Vision source. AX first; pixel click only when no handle. Receipt is transition-only. |
| `click Note 900` when the row is scrolled out | AXPress by exact name (`isOffscreen`) | Never offered to Jev; receipt is transition-only. Dropped when a visible control has the same label. |
| `scroll up` / `scroll down` | scroll | Asks which pane if several. |

Help lists observed unique controls and reminds: “If several controls match, say the number.”

## Grammar

Isolated utterances only. See [product](product.md) for typing vs command.

Confirmation accept: `yes`, `confirm`, `confirm this action`. Decline: `no`, `cancel`, `cancel task`. Payment words are `pay`, `purchase`, `checkout`, `order`, `booking` — not `book` or `reserve` (Address Book / calendar false positives).

## What stays host-owned forever

URLs, form values, arithmetic, dates, counts, ordinals, app switching, overlay Escape, and keystrokes. The model never generates a selector, a URL, or a script.

## Not yet tools

On-screen number overlays. `File > Export` menu paths. Named references (`mark as inbox`). Container-scoped “scroll a little more”. Completing a spoken-tool press when Accessibility returns “unknown” (plan-driven presses must keep pausing). See [later](later.md).
