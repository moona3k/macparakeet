# ADR-022: Transforms — System-Wide LLM Rewrites on Selected Text

> Status: **Accepted / Implemented**
> Date: 2026-05-12
> Implementation: Phase 2 merged to `main` on 2026-05-13; `AppFeatures.transformsEnabled` is now `true`.
> Related: ADR-002 (local-first processing, BYO-key amendment), ADR-009 (custom hotkey support), ADR-011 (LLM via cloud + optional local providers), ADR-012 (telemetry), ADR-013 (Prompt Library + multi-summary)

## Context

PR #278 shipped a behind-flag spike of *Transforms* — hotkey-triggered LLM rewrites that operate on whatever text is currently selected anywhere on macOS, replacing the selection in place with the LLM's response. The spike validated the end-to-end primitive (AX-capture → LLM stream → in-place replace) against a hardcoded *Polish* prompt on `⌥⌃ Opt + Ctrl + 1`, including the hard cases: AX failures fall back to clipboard hijack with snapshot/restore; layout-aware Cmd+C/V resolution; stale-progress guarding by run-ID; restore-on-abandon on every error/cancel path.

The design exploration (`docs/research/transforms-design-2026-05.md`) frames Transforms as the **hotkey-driven half of a future Command Mode** primitive — the same selection-capture → LLM-rewrite → in-place-replace pipeline that the voice variant tracked in `plans/active/2026-05-voice-command-agent-mode.md` will need, with a simpler trigger. Building the hotkey path first validates the AX coverage question (decision gate of Phase 1) before we invest in voice routing.

This ADR locks the architecture for the productized Phase 2 surface from the design doc. Phase 2 has shipped on `main`; future voice-driven command mode and richer per-Transform controls remain out of scope here.

## Decision

### 1. Transforms are stored as `Prompt` rows with `category == .transform`

The existing `Prompt` model (introduced by ADR-013 for the multi-summary system) already has `Category.transform`. Phase 2 adopts that category as the unit of Transform storage, rather than introducing a parallel `transforms` table.

Rationale:
- `Prompt` already gives us identity (UUID), name, content (prompt body), `isBuiltIn`, `isVisible`, `sortOrder`, `createdAt`, `updatedAt`. All of those are Transform-shaped.
- A separate table would force a join for what is essentially the same lifecycle (CRUD, reconcile-built-ins-on-launch).
- The `prompts` table is small (single-digit-to-low-tens of rows in practice) — adding two nullable columns for Transform-specific concerns is a smaller cost than the duplicated CRUD + repository + reconciler that a parallel table would require.

`.result` prompts (transcript summaries) and `.transform` prompts (selection rewrites) share storage but never share UI surfaces. They are functionally separate features with the same persistence shape.

### 2. Schema extensions

Two nullable columns are added to `prompts` via a forward-only migration:

| Column | Type | Purpose |
|---|---|---|
| `keyboardShortcut` | TEXT (JSON), nullable | Encodes a `KeyboardShortcut { modifiers, keyCode, keyLabel }` struct. NULL means "this Transform has no bound shortcut" (a valid, dormant state). |
| `runningLabel` | TEXT, nullable | Optional gerund-form label for the floating progress pill (e.g., *"Polishing…"*). NULL means "derive via the `{Name}ing…` heuristic; fall back to *Transforming…* for awkward names." |

Migration is additive. `.result` prompts ignore both columns (they will always read NULL, and they have no UI to set them). No data migration needed for existing rows.

### 3. AX-first capture with clipboard-hijack fallback (locked by spike)

`SelectionCaptureService.captureSelection()` returns one of:

```swift
public enum SelectionCaptureResult {
    case ax(text: String, element: AXUIElement)
    case clipboard(text: String, savedClipboard: NSPasteboardItemSnapshot?)
    case empty
    case failed(SelectionCaptureError)
}
```

Strategy:
1. Query `AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute` + `kAXSelectedTextAttribute`. If non-empty → `.ax`.
2. AX path fails or empty → snapshot clipboard → simulate Cmd+C (layout-aware via `PasteShortcutKeyResolver`) → poll changeCount with 250ms timeout → if changed, return `.clipboard` with snapshot; else `.empty`.
3. Restore the original clipboard snapshot **only after** the paste-back path completes or the run is abandoned. Restore-on-abandon hooks fire on every failure / cancel path (locked by PR #278 commit `69c2dda8`).

`SelectionReplacementService.replace(with:in:)` returns `SelectionReplacementPath` (`.ax | .clipboardPaste`):
1. `.ax` capture → try AX-write (`AXUIElementSetAttributeValue(elem, kAXSelectedTextAttribute, newText)`). On read-back match, done.
2. AX-write failure OR `.clipboard` capture → set new text on clipboard → simulate Cmd+V → wait ~500ms → restore the original clipboard snapshot.
3. Any clipboard activity is run inside a snapshot-take/restore guard that detects intervening user copies (PR #278 `69c2dda8`).

The 250ms read timeout and ~500ms post-paste delay are conventional values cribbed from Raycast / Espanso. They are the right empirical defaults; documented here for future tuning.

### 4. One process-wide `TransformsHotkeyRegistry` (single event tap, N transforms)

A single global event tap dispatches `KeyboardShortcut → Prompt.ID`. Replaces the spike's hardcoded single-hotkey coordinator.

Collision rules (rejected at bind time in `TransformEditorViewModel`):
- **Modifier required.** Bare-key bindings rejected. Matches WisprFlow's *"Shortcut must include modifier key…"* constraint.
- **No collision with the dictation hotkey** (`HotkeyManager` + `GlobalShortcutManager` user-bound combos).
- **No collision with the meeting-toggle hotkey.**
- **No duplicate Transform binding.**
- **macOS Opt+letter dead-key combos blocked** (`Opt+e`, `Opt+u`, `Opt+i`, `Opt+n`, ``Opt+` `` — these produce alt-characters and stealing them is hostile).
- **Reserved space:** `Opt+digit` (1–9) is the recommended default range. The Phase 2 built-ins use `⌥+1` (Polish), `⌥+2` (Distill), `⌥+3` (Decide). The lineup was synthesized from independent creative-director and staff-PM reviews (2026-05-12); the *Improve → Re-shape → Re-direct* pedagogy is intentional, and the shipped set avoids AI-insider naming in favor of verbs that generalize across the user's full surface (Slack, Linear, email, design docs, tickets).

### 5. No global "Opt in" toggle

The reference (WisprFlow) gates the entire Transforms surface behind a global *Opt in* toggle. We reject that pattern. Justification (settled with the owner 2026-05-12):

> *"User just explicitly presses the key to use it. It's the same with all other features. No need for toggle on or off — it just means that the keys have been set/provided/used or not."*

The mental model: a Transform is "on" if and only if a hotkey is bound to it. Built-ins ship with default hotkeys bound; users can clear them. There is no second-order gate. This is consistent with how the dictation hotkey, the meeting-toggle hotkey, and the global shortcuts in other surfaces work.

The product-level feature flag `AppFeatures.transformsEnabled` exists as a release gate (replaces `transformsSpikeEnabled`) — when false, the Transforms tab is hidden and the hotkey registry isn't initialized at all. It is not a user preference. It is enabled on `main` after the website telemetry allowlist deploy landed.

### 6. BYO-key only (no first-party LLM)

Transforms use the user's configured LLM provider (cloud API key, OpenAI-compatible endpoint, local Ollama / LM Studio, or Local CLI). The product ships with **no** first-party LLM — every transform call is against the user's configured provider. Matches the AI Formatter (PR #100) precedent.

`Polish`, `Distill`, and `Decide` are not gated behind paid tiers. The public build is free / GPL-3.0; Transforms is free.

### 7. CLI parity via `macparakeet-cli transforms` subcommand tree

The CLI is a public, semver-tracked contract (`Sources/CLI/CHANGELOG.md`). Coding agents (OpenClaw / Hermes path per `plans/active/cli-as-canonical-parakeet-surface.md`) need to drive Transforms headlessly for testing and provisioning.

```text
transforms list [--json]
transforms show <name|id> [--json]
transforms run <name|id> [--input FILE | --stdin] [--stream] [--json]
transforms create --name --prompt [--shortcut] [--running-label] [--json]
transforms delete <name|id> [--json]
```

`transforms run` operates on **text the CLI is given directly** (file or stdin). There is no AX-capture from the CLI; that's a GUI-only concern. The CLI is the headless test / provisioning surface.

The existing `llm transform --prompt "..." <input>` continues to exist as the raw-prompt ad-hoc primitive. `transforms run <name>` is the saved-prompt productized surface. They coexist.

### 8. Telemetry — opt-out, per-name counts, no content

Two events:

- `transform_executed` — `transform_name` (built-in name, or `custom`), `capture_path`, `replace_path`, `llm_ms`, `total_ms`. **No** prompt body. **No** selected text. **No** output text.
- `transform_failed` — `transform_name` (or `custom`), `reason` (enumerated).

Custom-Transform names are never transmitted (every non-built-in maps to `custom` in telemetry). This protects users who name a Transform after the company they're using it for, etc.

Both events must be added to `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts` before they fire in production (per `memory/feedback_telemetry_allowlist.md` — the Worker drops the entire batch on any unknown event). This is a two-repo coordination point baked into the rollout plan.

### 9. Feature-flag rollout (`AppFeatures.transformsEnabled`)

Replaces the spike flag `transformsSpikeEnabled`. It was introduced as release-off, then flipped to `true` after the website telemetry allowlist accepted `transform_executed` / `transform_failed`. Current `main` has `AppFeatures.transformsEnabled = true`.

When `false`:
- Transforms tab is hidden from the sidebar.
- `TransformsHotkeyRegistry` is not initialized — no event tap registered, no key dispatch.
- Existing data (Polish / Distill / Decide built-in rows) remain in the DB; reconciler still seeds them so flipping the flag is a no-data-migration operation.
- CLI `transforms` subcommands still work (the CLI doesn't gate on the GUI flag).

## Consequences

### Positive

- The Transforms feature ships on top of existing, exercised infrastructure: `Prompt` table, `LLMService.transform*`, `GlobalShortcutManager`, accessibility permission, paste-back simulation, telemetry pipeline. No new subsystem, just a new top-level surface.
- A single dispatch table means the in-flight model is clear: at most one Transform runs at a time; cancel-then-restart on re-trigger is locally enforceable.
- CLI parity means agent operators (per `cli-as-canonical-parakeet-surface.md`) can drive Transforms headlessly — useful both for our own dogfooding and for the agent-audience growth angle.
- The "no global toggle" decision keeps the feature consistent with the rest of the app's gesture-as-affordance model.

### Negative / accepted trade-offs

- Adding nullable Transform-specific columns to the `prompts` table is mild schema clutter for `.result` rows. Accepted; the cost is a few NULL bytes per summary prompt and is dominated by the joins it avoids.
- Clipboard hijack / restore dance is racy by definition (user copies during the ~500ms window are partially clobbered). Mitigated by PR #278's intervening-copy detection; an unrecoverable edge case is logged and the user's most-recent copy is preserved. Documented as a known limitation.
- The feature ships free, against user-paid LLM providers. If users hammer Transforms against an expensive cloud model, that cost is theirs. The pill's patience threshold + the per-Transform telemetry helps us notice runaway-latency patterns.
- macOS Cmd+Z is the v1 escape hatch for unwanted Transforms. No inline diff or preview. Phase 3 adds the diff viewer; until then, users accept "press it, Cmd+Z if you didn't like it."

### Non-decisions (still open, will be locked in later ADRs if needed)

- **Voice-driven trigger.** Owned by `2026-05-voice-command-agent-mode.md`. The architecture here is general enough to be reused if/when that ships, but this ADR makes no commitment.
- **Per-Transform LLM model override.** Phase 3.
- **Rule toggles (composable Polish rules).** Phase 3.
- **Few-shot writing samples.** Phase 3.

## Alternatives considered

### Alternative A — Separate `transforms` table

Make Transforms a first-class table with its own model, repository, and reconciler. Foreign-key to `prompts` for the prompt body or duplicate it.

Rejected: doubles the lifecycle (two reconcilers, two migrations to keep in sync, two CRUD surfaces) for what is essentially the same data shape. The `Prompt.Category.transform` enum case was added in ADR-013 in anticipation of exactly this — the foundation was laid intentionally.

### Alternative B — Per-Transform `GlobalShortcutManager` instance

Spawn one `GlobalShortcutManager` per active Transform binding (the design doc's Option A). Simpler at first glance.

Rejected: multiple managers compete on the same event tap; one-tap-to-rule-them-all (`TransformsHotkeyRegistry`) is structurally cleaner, makes collision detection trivial, and keeps the cancel-then-restart semantics centralized.

### Alternative C — Inline streaming into the target text field

Stream LLM tokens directly into the focused field as they arrive, instead of waiting for completion + pasting once.

Rejected: every host app handles "rapid-fire inserts via paste" differently — some batch undo, some flicker, some fight with autocomplete. The cost-of-getting-it-wrong is "the user's document looks scrambled mid-transform." The cost of waiting is "the user sees a small rose loader for 1-3 seconds." The patience-threshold pattern from PR #278 commit `94f53067` covers the long-tail latency cases. Streaming-into-field can be revisited if streaming-into-pill ever loses its appeal.

### Alternative D — Implicit Cmd+A on empty selection

WisprFlow appears to do an implicit "select all in focused field" when the hotkey fires with no selection, then transforms the resulting all-text.

Rejected (design doc §"No-selection and error UX"): dangerous in long-text contexts. Imagine pressing Opt+1 in an open Notes document expecting a small adjustment and instead the entire document gets sent to an LLM and replaced. Even Cmd+Z to restore feels scary at that scale. AX `Cmd+A` semantics also vary across apps. The educational toast does the teaching job at far lower risk.

## Implementation pointer

Phase 2 of `docs/research/transforms-design-2026-05.md`, executed per `plans/completed/2026-05-transforms-phase-2-productize.md`. The spike code from PR #278 graduated with minimal change to its low-level services (`SelectionCaptureService`, `SelectionReplacementService`, `TransformExecutor`); the new code is the registry, the productized coordinator, the management UI, and the CLI subcommand tree.
