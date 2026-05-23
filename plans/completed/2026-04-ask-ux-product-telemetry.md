# Live Ask product telemetry

**Status:** Completed — Ask telemetry events and call sites are shipped on `main`; the website Worker allowlist includes both event names.
**Date:** 2026-04-26 · Completed 2026-05
**ADRs:** ADR-012 (telemetry system), ADR-018 (live Ask tab)
**Implementation:** `ask_menu_opened` and `ask_prompt_fired` are typed in `TelemetryEventName`, serialized in `TelemetryEventSpec`, fired from `LiveAskPaneView`, covered by `TelemetryServiceTests`, and allowlisted in `macparakeet-website/functions/api/telemetry.ts`.

## Why

Commit `3e37a38b` (live Ask UX overhaul) added three new prompt invocation surfaces: the empty-state grouped pills, the `✨` menu button → popover, and the trimmed follow-up row. Hover-reveal expands prompt bodies inline. At plan time, we had **zero signal** on:

- Does anyone use the menu button mid-conversation, or do they ignore it and type?
- Which prompts dominate? Which get clicked from never?
- Does the popover surface actually drive use, or just sit there?
- Are users reading the hover-revealed bodies, or firing on label alone?

Without this, the next iteration is opinion-driven. With it, we have signal before the next shipping window.

## Scope

### In scope
- Two new event names: `ask_menu_opened`, `ask_prompt_fired`
- Wire fires from `LiveAskPaneView` (current owner of all three surfaces)
- Keep prompt telemetry lightweight: source/group/label only, with no prompt body and no operation IDs
- Worker allowlist update in `macparakeet-website/functions/api/telemetry.ts`
- Tests in `TelemetryServiceTests` for serialization

### Out of scope
- **Hover-reveal events** (`ask_prompt_revealed`) — high cardinality (every mouse sweep), low signal, easy to add later if a question demands it
- Per-character input typing telemetry
- Time-on-prompt-before-firing (overengineered)
- Custom user prompts (doesn't exist; YAGNI)

### Invariants
- No prompt **text** in events — labels only (low cardinality, identifiable surface, no PII risk)
- Worker allowlist gate — both events MUST land in `ALLOWED_EVENTS` in the Worker BEFORE the Swift PR ships, or the Worker silently drops the entire batch

## Event contract

### `ask_menu_opened`
Fires when the user clicks `PromptMenuButton` to open the popover.

| Field | Type | Notes |
|---|---|---|
| — | — | No props. The event only records that the menu opened. |

### `ask_prompt_fired`
Fires every time a `LiveAskPrompt` is sent to the LLM. Single event covers all three invocation surfaces.

| Field | Type | Notes |
|---|---|---|
| `source` | enum | `empty_state` \| `menu` \| `follow_up` |
| `group` | enum | `catch_up` \| `capture` \| `challenge` \| `follow_up` \| `custom` |
| `label` | enum | Stable built-in slug such as `decisions_made`; edited built-ins and custom prompts collapse to `custom`. Never prompt body text. |

The shared `fire(_:)` path in `LiveAskPaneView` is the natural fire site — it already centralizes both pill-source paths. Pass `source` through as a parameter.

## File-by-file

| File | Change |
|---|---|
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `askMenuOpened`, `askPromptFired` to `TelemetryEventName` |
| `Sources/MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift` | Add `source` param to `fire(_:)`; thread it from each call site (empty-state pill, sparkle menu, follow-up row); emit event via TelemetryService. Emit `ask_menu_opened` from `PromptMenuButton`. |
| `Tests/MacParakeetTests/TelemetryServiceTests.swift` | Serialization tests for both event names |
| `macparakeet-website/functions/api/telemetry.ts` | Add both names to `ALLOWED_EVENTS` |

## Sequencing

1. **Wait for PR #164 to merge** (Codex agent, expected today 2026-04-26)
2. **Open companion website PR** with allowlist additions; merge + deploy first
3. **Open app PR** with event names + fire wiring + tests; verify `ALLOWED_EVENTS` is live before merging
4. **Confirm on dashboard** within 24h post-ship that events land; iterate label/source if cardinality blows up

## After-shipping questions to answer

These are the questions the data should answer in the first week:

1. Of users who get to a `messages.isEmpty == false` state, what % open the menu at least once?
2. Top 3 / bottom 3 prompts by fire rate, broken down by `source`
3. Do `menu` fires correlate with users who came from `empty_state` first (i.e. did the empty state teach them the menu)?
4. Group skew — does CAPTURE dominate as predicted, or do CHALLENGE prompts surprise us?

## Notes

- The two-repo allowlist gotcha bites if the Swift PR ships before the Worker PR deploys. Sequence per step (2)→(3) above.
- This plan does **not** add slash-command telemetry. Slash is deferred until custom commands earn it (per session decision 2026-04-26); product telemetry should arrive bundled with that feature, not pre-built.
- Keep cardinality low. `label` is identifiable but bounded (~14 starters + 5 follow-ups = ~19 distinct values). Adding free-text fields would break dashboard rollups.
