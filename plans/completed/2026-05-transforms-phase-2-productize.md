# Plan: Transforms — Phase 2 (Productize)

> Status: **COMPLETED** — archived from `plans/active/` during the
> 2026-05-16 docs/spec audit. Phase 2 is implemented on `main`; ADR-022,
> `spec/02-features.md`, and `spec/04-ui-patterns.md` now carry the current
> product contract.
> Author: agent (Claude) + Daniel
> Date: 2026-05-12
> Related:
> - Design exploration: `docs/research/transforms-design-2026-05.md` (PROPOSAL, 2026-05-11)
> - WisprFlow parity audit: `docs/research/wisprflow-parity-2026-05.md`
> - Voice command / Agent Mode plan: `plans/active/2026-05-voice-command-agent-mode.md`
> - Agent Mode vision: `docs/agent-mode-vision.md`
> - Phase 1 spike: PR #278 (`spike/transforms-ax-coverage`, merged 2026-05-12 as `2a729f9a`), polish/correctness follow-ups `94f53067`, `69c2dda8`, `5a977cd6`
> - Locks-on-merge ADR: `spec/adr/022-transforms-system-wide-rewrite.md` (drafted alongside this plan)

---

## TL;DR

The Transforms spike (PR #278) validated the AX-capture → LLM → in-place-replace primitive end-to-end against a hardcoded Polish prompt on Opt+Ctrl+1, with all the hard-won correctness work already landed: clipboard backup/restore, AX-write with paste-back fallback, layout-aware Cmd+C/V resolution, stale-progress guarding by run-ID, premium "rose loader" pill with patience-threshold label reveal.

**Phase 2 is now: productize the surface.** Wire `Prompt.category == .transform` rows to the executor through a new `TransformsHotkeyRegistry` (single event tap, dispatch by combo), ship Polish / Distill / Decide as built-in transforms on Opt+1 / Opt+2 / Opt+3, build a new top-level **Transforms** tab with a premium *Create your own* editor, expose the feature through a new `macparakeet-cli transforms` subcommand tree so coding agents can drive and test it headlessly, gate it behind a single `AppFeatures.transformsEnabled` flag, instrument per-name telemetry.

Three deliberate cuts up front:
1. **No global "Opt in" toggle** (rejected by user 2026-05-12). Always-on; gating happens through whether a user has bound a hotkey to a Transform — same mental model as the dictation hotkey itself.
2. **No diff viewer / rule toggles / per-Transform model picker.** Phase 3 polish. macOS Cmd+Z is the v1 escape hatch.
3. **No voice-driven trigger.** Owned by `2026-05-voice-command-agent-mode.md`.

The bar is **premium, enterprise-grade UI/UX** that reads as the third member of an existing MacParakeet visual system (the dictation overlay, the meeting pill, the Transforms pill), not as a WisprFlow pixel-copy. The reference screenshots inform the *shape* of the surface; our visual language fills it in.

---

## Where the spike got us

PR #278 + the three follow-up commits delivered a substantial foundation. From the merge stats:

| Layer | Status | Path |
|---|---|---|
| `SelectionCaptureService` (AX-first + 250ms clipboard hijack with snapshot) | Built | `Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift` |
| `SelectionReplacementService` (AX-write + Cmd+V paste-back + clipboard restore) | Built | `Sources/MacParakeetCore/Services/System/SelectionReplacementService.swift` |
| `TransformExecutor` (capture → LLM stream → replace; cooperative cancellation; restore-on-abandon) | Built | `Sources/MacParakeetCore/Services/Transforms/TransformExecutor.swift` |
| `TransformPrompts.polish` (hardcoded spike prompt) | Built | `Sources/MacParakeetCore/Services/Transforms/TransformPrompts.swift` |
| `PasteShortcutKeyResolver` (layout-aware Cmd+C/V resolution) | Built | `Sources/MacParakeetCore/Services/PasteShortcutKeyResolver.swift` |
| Floating progress panel — bottom-anchored Capsule, rhodonea (5-petal squared rose, `r(θ) = sin²(5θ/2)`) loader, brand checkmark, "Still polishing…" patience reveal at 5s | Built | `Sources/MacParakeet/Views/Transforms/TransformSpikeProgressPanelController.swift` |
| `TransformsSpikeCoordinator` (Opt+Ctrl+1 hotkey, run-ID stale-event guarding, panel lifecycle) | Built | `Sources/MacParakeet/App/TransformsSpikeCoordinator.swift` |
| LLM service path: `LLMService.transform / transformStream / transformDetailed` | Built (pre-spike) | `Sources/MacParakeetCore/Services/LLM/LLMService.swift` |
| CLI `macparakeet-cli llm transform --prompt … <input>` | Built (pre-spike) | `Sources/CLI/Commands/LLMTransformCommand.swift` |
| Feature flag `AppFeatures.transformsSpikeEnabled` (default `false`) | Built | `Sources/MacParakeetCore/AppFeatures.swift:32` |
| `Prompt.Category.transform` enum case (built-ins seeded by completed Phase 2) | Built (pre-spike) | `Sources/MacParakeetCore/Models/Prompt.swift:19` |
| Test coverage: capture, replacement, executor, paste resolver | Built | `Tests/MacParakeetTests/Services/{System,Transforms}/…` |

**What the spike intentionally skipped:**

- No Transforms tab. The spike has no navigation surface at all.
- No persistence for transforms — the Polish prompt is a hardcoded constant.
- No support for N transforms. The coordinator binds exactly one hotkey to exactly one prompt.
- No Create-your-own editor. No hotkey binding UI for Transforms.
- No CLI subcommand tree for Transforms (the existing `llm transform` is the raw-prompt primitive).
- No telemetry beyond the `llmTransformUsed` / `llmTransformFailed` events the LLM service already emits.

Phase 2 closes every one of those gaps.

---

## What we're building (the product surface)

### The Transforms tab

A new top-level sidebar item (sibling of Vocabulary, Library, Settings — IA confirmed by the design doc). The tab contains:

1. **Hero card** — short framing of what Transforms does, with a *Try it out* and *How it works* affordance. Reference screenshots show a screenshot-collage of target apps (Slack, Notes, Gmail, Linear, ChatGPT, Claude, …) — we'll do our version using MacParakeet's brand visual vocabulary, not a literal collage. The hero is not the toggle; **there is no global toggle.**

2. **My Transforms** grid — three-up cards by default, each showing:
   - Bound hotkey badge (e.g. `⌥ Opt 1`) in our existing key-cap style (same atom as the Discover sidebar / Settings)
   - Transform name (e.g. *Polish*)
   - One-line description (e.g. *Improve clarity and conciseness*)
   - Hover state reveals: Edit button, Reset (for built-ins only)
   - The card itself is the click target for Edit
   - Plus a **Create your own** tile (plus glyph + label) as the final cell

3. **Secondary actions** in the header — *Reset to defaults* (re-seeds any missing built-in transforms), and *Create New* primary action button.

4. **No-provider banner** — when no LLM provider is configured, replace the hero with a calmer inline state: *"Transforms need an LLM provider — configure in Settings."* + `[Open Settings]` button. Doesn't yank the user away; just states the dependency. Disappears once a provider is configured.

5. **Per-Transform empty state for shortcuts** — if a user has cleared a built-in's hotkey, the card shows a *"No shortcut bound"* secondary chip in place of the key-cap; clicking the card opens the editor with the shortcut field already focused.

### Create your own / Edit Transform sheet

Modal sheet. Two-column layout matching the reference shape but earning its own finish:

- **Left rail** — `Create your own` (or `Edit {name}` for existing) title in our serif display face, plus framing copy ("Set up a keyboard shortcut to apply this Transform.")
- **Right column** — three stacked field cards:
  1. **Name** (text field, placeholder *"Boss Mode"*)
  2. **Keyboard shortcut** (hotkey recorder card, reusing `HotkeyRecorderView` from the dictation/meeting hotkey settings flow). Surfaces inline collision detection ("This shortcut conflicts with Dictation").
  3. **Customize prompt** (multi-line text editor with placeholder *"How do you want this Transform to change your text?"*)
- **Footer** — *Autosave On* indicator (consistent with the reference) on the left, *Reset* (built-ins only) on the right, *Save / Cancel* trailing actions. For built-ins, *Save* commits edits; for new transforms, *Save* persists the new row.
- **Writing-samples section** — the reference shows a "Set up the name, shortcut, and prompt above to add writing samples" affordance. **Out of scope for Phase 2.** We won't show the disabled placeholder either — the section simply isn't there. Phase 3 adds few-shot sample editing.

### Floating progress pill (already shipped from the spike)

The pill already exists from the spike — bottom-anchored Capsule, rhodonea loader, brand checkmark, patience-threshold label. **Phase 2 changes nothing in its visual design.** The only wiring change is that the label now derives from the bound Transform's name (e.g., *Polishing…*, *Distilling…*, *Deciding…*) instead of being hardcoded — Phase 2 adds an optional `runningLabel` field on the Prompt model with the existing `{Name}ing…` heuristic as fallback.

### Premium-finish bar

The reference screenshots are baseline references, not pixel targets. The bar we're building to:

- **Visual continuity.** Every new component reuses existing atoms (key-cap chip, card chrome, button roles via `parakeetAction`, sacred-geometry indicators) rather than inventing parallel ones. Same rule as the spike pill polish commit `94f53067`.
- **Empty/error states are first-class.** No empty list of transforms (built-ins are always seeded). No-provider state is calmer than the running state, not louder.
- **Microinteractions are considered.** Hover reveals are eased (not instant), shortcut-recording state has its own visual emphasis, save confirmations are tactile.
- **Typography hierarchy is intentional.** Display serif for the title, body sans for descriptions, monospace only inside the prompt-body editor.
- **Accessibility.** Every interactive element has a label; focus rings honor the system; sheet is dismissible with Esc; recorder is keyboard-only-operable.

---

## Architecture

### Data model — extend the existing `prompts` table

The design doc and the existing `Prompt.Category.transform` enum case make this decision for us: **the Prompts table is the unit of Transform storage.** We add two nullable columns:

| Column | Type | Notes |
|---|---|---|
| `keyboardShortcut` | TEXT (JSON-encoded `KeyboardShortcut` struct), nullable | Modifier bitmask + virtual keycode. Nullable so built-ins shipped without an active binding still persist. |
| `runningLabel` | TEXT, nullable | Optional override for the progress-pill verb form (e.g., *Polishing…*). When `nil`, derive via the `{Name}ing…` heuristic; if even that's awkward, fall back to *Transforming…*. |

Schema migration is additive — no breaking change to `.result` (summary) prompts. GRDB migration `addTransformColumnsToPrompts` runs at app boot.

The `KeyboardShortcut` struct:

```swift
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public let modifiers: UInt          // Carbon-style flags (cmd/option/control/shift)
    public let keyCode: UInt16          // virtual keycode (kVK_*)
    public let keyLabel: String         // display string for the recorded key ("1", "A", etc.)
}
```

### Built-in transforms

Three seeded rows, `isBuiltIn=true`, `category=.transform`. Stable UUIDs (reserved and documented inline next to `1C5A1B4A-7E2C-4D38-B3EF-5C0F8A7E3E1A`, the "Memo-Steered Notes" reserved sentinel):

| Name | UUID (reserved) | Default shortcut | Default prompt |
|---|---|---|---|
| Polish | `0FCE9DDB-7E2D-4B1A-AE3E-6F7C9B2A4D11` | `⌥ Opt + 1` | Promotes tone-preserving clarity. Rewrites the input text to be cleaner, more concise, and grammatically correct without changing register or stylistic voice. Returns only the rewritten text. |
| Distill | `1AD7C2B0-9C6F-4F0E-9C39-5E4D1F1D2A55` | `⌥ Opt + 2` | Compresses rambling text to its signal while preserving actionable meaning, context, and the reasoning behind decisions. Returns only the distilled text. |
| Decide | `2BE8D3C1-4A7F-4EBD-8F12-7C9A1E0B3D44` | `⌥ Opt + 3` | Rewrites discussion into a decision-ready note with the question, options, tradeoffs, recommendation, and any blocking uncertainty. Returns only the rewritten note. |

The prompt bodies will land in the implementation commit with a deliberate, premium tone — these are user-facing built-ins.

Reconciler updates: the existing prompt reconciler gains awareness of `.transform` built-ins. It re-seeds missing rows and preserves user-editable fields on existing Transform built-ins (name, content, shortcut, running label, and edit timestamp), while still normalizing structural fields such as category, visibility, auto-run state, and sort order.

### TransformsHotkeyRegistry (single event tap, N transforms)

New actor in `Sources/MacParakeetCore/Services/Transforms/TransformsHotkeyRegistry.swift`. Owns one process-wide event tap and a `[KeyboardShortcut: Prompt.ID]` dispatch table. Re-registers on prompt repository updates via NotificationCenter.

Collision detection (lifted from the design doc §4):
- Modifier required. Bare keys are rejected with a clear error in the recorder UI.
- No collision with the dictation hotkey or the meeting-toggle hotkey. Surface inline error.
- Cannot duplicate another Transform's binding.
- macOS Opt+letter dead-key combos (Opt+e, Opt+u, Opt+i, Opt+n, Opt+`) blocked with a "this combo produces a special character on Mac" message. `Opt+digit` (1-9) is the safe default range.

The existing `TransformsSpikeCoordinator` is **replaced** by a new `TransformsCoordinator` that:
- Loads `.transform` prompts from the repository
- Registers each bound prompt with the registry
- On hotkey fire, looks up the prompt body and runs `TransformExecutor.run(prompt: ..., onProgress: ...)` (the spike's executor is reused as-is — no changes needed to its contract)
- Manages a single floating-pill instance, cancel-then-restart on re-trigger (existing pattern from the spike)
- Emits per-prompt telemetry events

### CLI surface

New `macparakeet-cli transforms` parent command with subcommands. CLI semver bumps to a new minor — see `Sources/CLI/CHANGELOG.md`.

```
macparakeet-cli transforms list [--json]
    # List all transforms with id, name, hotkey, isBuiltIn.

macparakeet-cli transforms show <name|id> [--json]
    # Print full transform definition including prompt body.

macparakeet-cli transforms run <name|id> [--input FILE | --stdin] [--json] [--stream]
    # Run a transform's prompt body against text input. Uses the saved
    # prompt body, not an ad-hoc one. CLI takes text input directly —
    # there is no AX-capture from the CLI surface. Output goes to
    # stdout.

macparakeet-cli transforms create --name "..." --prompt "..." [--shortcut "..."] [--running-label "..."] [--json]
    # Headless install of a new Transform. Useful for agent-driven
    # provisioning. --shortcut format: "opt+1", "cmd+shift+p", etc.

macparakeet-cli transforms delete <name|id> [--json]
    # Delete a non-built-in Transform. Refuses to delete built-ins
    # (use `transforms reset` if we add one in a follow-up).
```

`--json` envelopes follow the `LLMResult` shape established by PR #138 (the unified `--json` contract). `transforms run --stream` streams tokens to stdout one by one; `--stream` is incompatible with `--json` (same constraint as `llm transform`).

The existing `llm transform --prompt "..." <input>` stays as the raw-prompt ad-hoc primitive. `transforms run` is the saved-prompt productized surface. They coexist.

### Telemetry

Two events per ADR-012's allowlist convention:

- `transform_executed` — fired on successful completion. Properties: `transform_name` (built-in name or `custom`), `capture_path` (`ax | clipboard`), `replace_path` (`ax | clipboardPaste`), `llm_ms`, `total_ms`. **No** prompt body, **no** selected text, **no** output text. Custom-transform names are not transmitted (telemetry sees `custom` for any non-built-in).
- `transform_failed` — fired on failure. Properties: `transform_name` (or `custom`), `reason` (one of `empty_selection | llm_not_configured | llm_failed | replacement_failed | cancelled`). No error message bodies.

**Both events require a two-repo update** before they fire in production: add to `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts` (per `memory/feedback_telemetry_allowlist.md`). The Worker rejects entire batches if any event is unknown — co-batched valid events get silently dropped. This is flagged as a release-gate step in §"Rollout."

### Feature flag

Replace `AppFeatures.transformsSpikeEnabled` with `AppFeatures.transformsEnabled`. The flag was introduced release-off during merge, then flipped to **`true`** after the website telemetry allowlist accepted the Transform events. Current `main` ships productized Transforms enabled.

---

## Implementation phases (this plan)

Single sprint, single branch, multiple logical commits.

### Phase A — Data + service layer (~3 hr)

1. Migration: extend `prompts` table.
2. `KeyboardShortcut` model + Codable.
3. Update `Prompt.Columns` + Codable to round-trip new fields.
4. Seed Polish / Distill / Decide built-ins. Reserve UUIDs. Update reconciler.
5. `TransformsHotkeyRegistry` actor + collision detection.
6. `TransformsCoordinator` (replaces spike coordinator).
7. Tests: migration, reconciler, registry collision rules, coordinator lifecycle.

### Phase B — UI layer (~4 hr)

1. `TransformsViewModel` (list).
2. `TransformEditorViewModel` (create/edit, validation, autosave).
3. `TransformsView` (premium-finish list/grid).
4. `TransformEditorSheet` (modal editor).
5. Wire into main navigation. Hidden behind `transformsEnabled`.
6. Onboarding-style empty/no-provider state.
7. Tests: ViewModels.

### Phase C — CLI (~2 hr)

1. `TransformsCommand` parent + `list / show / run / create / delete` subcommands.
2. `--json` envelope wiring consistent with `llm transform`.
3. CLI tests (`CLITests/TransformsCommandTests`).
4. `Sources/CLI/CHANGELOG.md` minor bump.

### Phase D — Polish, telemetry, docs (~2 hr)

1. Telemetry events + Swift-side allowlist additions.
2. Replace feature flag (`transformsSpikeEnabled` → `transformsEnabled`).
3. Spec updates: `kernel/requirements.yaml`, `kernel/traceability.md`, `spec/02-features.md`, `spec/12-processing-layer.md`.
4. ADR-022 finalized (Status: PROPOSAL → IMPLEMENTED on merge).
5. CLAUDE.md framing update (Transforms as a fourth surface, sibling to the three primary modes).
6. AGENTS.md + integrations/README.md vocabulary update.
7. `swift test` green; dev-build smoke pass.

### Phase E — Rollout (post-merge, owner-driven)

1. Update `ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts`. Deploy.
2. In a follow-up commit on this branch (or a fresh micro-PR), flip `transformsEnabled = true`.
3. Tag a release point that includes both the allowlist deploy timestamp + the flag flip.

---

## Test matrix

| Layer | Tests |
|---|---|
| Migration | Adding `keyboardShortcut` + `runningLabel` columns is idempotent. Existing rows unaffected. Built-in reseed honors user edits. |
| `KeyboardShortcut` | Codable round-trip. Display string for common combos. Modifier-required validation. |
| `TransformsHotkeyRegistry` | Register / unregister. Collision rejection (dictation, meeting, duplicate, dead-key). Re-register on repo change. |
| `TransformsCoordinator` | Hotkey fire → executor invoked with correct prompt body. Cancel-then-restart on re-trigger. Telemetry on success / failure. |
| `TransformsViewModel` | List load, create, delete, reset built-in. No-provider state correctness. |
| `TransformEditorViewModel` | Validation (name, shortcut, prompt). Collision detection inline. Autosave debounce. Reset behavior on built-ins. |
| CLI `transforms` | Argument parsing for each subcommand. `--json` envelope shape matches LLMResult conventions. `run` with `--input` vs `--stdin`. `create` happy path + shortcut-parse failures. `delete` refuses built-ins. |
| Smoke | Dev-build: open Transforms tab, create custom transform, bind shortcut, run on selected text in TextEdit, verify pill animation, verify result paste, verify Cmd+Z undoes. |

All tests deterministic. No network. LLM mocked via `LLMServiceProtocol`.

---

## Out of scope (deferred to Phase 3 or later)

- Diff preview (`See changes in diff` modal from the reference). Cmd+Z is the v1 escape hatch.
- Rule toggles (WisprFlow's "Make more concise" composable polish rules).
- Per-Transform LLM model override picker.
- Writing samples / few-shot example editing.
- Voice-driven trigger ("hold Fn, say 'make this more formal'"). Owned by `2026-05-voice-command-agent-mode.md`.
- Inline streaming into the target text field (deemed too fragile across host apps).
- Per-app routing (Polish-in-Slack behaves differently from Polish-in-Gmail).

---

## Rollout & gates

1. **Merge gate:** `swift test` green, dev-build smoke pass, ADR-022 finalized, spec/kernel updated, plan archived to `plans/completed/`.
2. **Pre-ship gate (telemetry):** `macparakeet-website` Worker `ALLOWED_EVENTS` deployment includes `transform_executed` + `transform_failed`. Confirmed via curl test.
3. **Ship gate:** `AppFeatures.transformsEnabled = true` flip. Single small commit.
4. **Post-ship:** monitor `transform_executed` / `transform_failed` counts for 48 hours. Compare to spike's `llm_transform_used` baseline. Flag any unexpected `reason=replacement_failed` spike (host-app AX coverage regression).

---

## Open questions (very few — most settled by design doc)

1. **Built-in lineup and shortcuts.** Locked 2026-05-12: Polish (`Opt+1`), Distill (`Opt+2`), Decide (`Opt+3`); `Opt+4` through `Opt+9` remain open for user customization.
2. **Reset to defaults scope.** Does *Reset to defaults* on the Transforms tab header restore all built-ins to their defaults (overwriting user edits), or does it only re-seed missing built-ins? Recommend: only re-seed missing. A per-card *Reset* button on each built-in handles overwrite-with-confirmation. → **Locked: only re-seed missing; per-card reset for individual overwrite.**
3. **Custom transform name in telemetry.** Currently planned to send `custom` for any non-built-in. Alternative is to send a hash of the name. Recommend: stick with `custom` for privacy.

If anything else surfaces during implementation, this plan gets amended in place; the implementation commit references the amendment.

---

## Connection to the broader product narrative

Transforms is the hotkey-driven half of what `docs/agent-mode-vision.md` calls *Command Mode* — a primitive that will also be reachable via voice once `plans/active/2026-05-voice-command-agent-mode.md` ships. Building the hotkey path first is the conservative move: it validates the AX/clipboard primitive (done by the spike) and the management UI (this plan), and leaves the voice trigger layer as a thin replacement on the input edge.

The framing in CLAUDE.md needs to evolve from *three co-equal modes* (dictation, file transcription, meeting recording) to *three primary modes + Transforms as a system-wide surface*. Transforms isn't a fourth "mode" — it doesn't have its own capture pipeline; it operates on whatever's selected anywhere in macOS. It earns its own sidebar tab, but the conceptual hierarchy is preserved.
