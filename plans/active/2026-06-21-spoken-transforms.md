# Spoken Transforms — Voice-Supplied Instructions over a Selection

**Status:** PROPOSED — not started
**Date:** 2026-06-21
**ADRs:** ADR-022 (Transforms — system-wide LLM rewrites on selected text). Resolves
ADR-022's reserved "voice-driven trigger" non-decision. Consider a short
ADR-026 amendment on approval.
**Lineage:** Revives the removed **F10a "Command Mode" Core** (spec F10a, removed
with the old local Qwen3-8B path) on top of the now-shipped Transforms pipeline
and BYO-provider LLM layer that replaced it.
**Supersedes (in part):** the selected-text-rewrite slice of
`plans/active/2026-05-voice-command-agent-mode.md`. The broader app-action /
agent-handoff / macro scope in that plan stays parked.
**Issues:** none yet (propose filing on approval).

## Summary

A **Spoken Transform** is a Transform whose instruction you *speak* instead of
pre-saving. The user highlights text in any app, holds a dedicated hotkey, says
what they want ("rewrite this as bullets", "make this more formal", "reply to
this politely"), releases, and the result replaces the selection. It is the
natural fusion of MacParakeet's two strongest pillars — dictation and
Transforms — and it is almost entirely a *composition* of code that already
ships, not new subsystem work.

It deliberately stops at **text in → text out on a selection**. No clicking, no
typing into other apps, no screen capture, no OS automation, no agent loop. That
boundary is what keeps it on the trust-first, reversible, local-first side of
the line, and what distinguishes this plan from the parked "agent mode"
exploration.

## Why now, and why it's low-risk

1. **The original blocker is gone.** F10a was removed because it depended on the
   local Qwen3-8B path. Transforms (ADR-022) since built a full provider
   abstraction — local (Ollama / LM Studio) *and* BYOK cloud — so the LLM step
   is solved and configurable, on-device by default for users who want it.
2. **The pipeline is already trigger-agnostic.** Transforms factor cleanly into
   `SelectionCaptureService` → `LLMService.transformStream(text:prompt:)` →
   `SelectionReplacementService`. Only the *trigger* and the *prompt source*
   differ for a spoken instruction.
3. **The LLM side needs no change.** `LLMService.transform(text:prompt:)` /
   `transformStream(text:prompt:)` already accept an arbitrary `prompt: String`.
   Today the GUI feeds a saved `Prompt.content`; we feed the dictated
   instruction instead. The CLI already does exactly this
   (`macparakeet-cli llm transform --prompt "<instruction>" -`), which means
   agent-native parity holds on day one and the Core contract is proven.
4. **The UI partly exists already.** `DictationOverlayViewModel.SessionKind`
   already has a dormant `.command` case with `commandSelectedText` /
   `commandPromptText` and a "Stop & apply" affordance — built for exactly this
   and never wired to a hotkey. We light it up rather than build a new overlay.
5. **The hold-to-talk + non-activating panel mechanics are solved.**
   `HotkeyManager` (`.holdOnly`), the `.nonactivatingPanel` overlays, and the
   resign-key-before-paste discipline already exist and are battle-tested by
   dictation and Transforms.

## User flow

```
1. User selects text in any app.
   "the meeting is scheduled for next tuesday at 3pm"
2. User presses-and-holds the Spoken Transform hotkey.
   - Selection is snapshotted immediately (AX, clipboard fallback).
   - Non-activating overlay appears: shows the captured selection + a live
     transcript of the instruction. Host app keeps focus and selection.
3. User speaks the instruction while holding.
   "make this formal and fix the capitalization"
4. User releases.
   - Spoken audio is transcribed by Parakeet -> the instruction string.
   - LLMService runs transform(text: selection, prompt: instruction), streamed
     into the overlay's progress state.
5. Result replaces the selection (paste-into-current-focus). Cmd-Z undoes it.
   - A local transform_history row is written, like any Transform.
```

## Scope boundaries

### In scope
- A dedicated, configurable **Spoken Transform hotkey** (hold-to-talk), distinct
  from the dictation and meeting hotkeys, with the standard conflict validation.
- Snapshot the frontmost selection on key-down via `SelectionCaptureService`.
- Record while held; transcribe the instruction with the existing Parakeet
  dictation path; **the transcript is the instruction, never pasted as text**.
- Run the existing Transform LLM path with `text = selection`,
  `prompt = spoken instruction`.
- Replace the selection via `SelectionReplacementService`
  (`.pasteIntoCurrentFocus`, matching the GUI Transforms default).
- Reuse the dormant `.command` overlay session kind for capture + progress.
- Write a `transform_history` row (reuse the existing schema; tag the capture
  path as voice).
- Feature flag `AppFeatures.spokenTransformsEnabled`, default **off**, staged
  per ADR-022 §9.
- Content-free telemetry, mirroring `transform_executed` / `transform_failed`.

### Explicitly out of scope (stays parked in the agent-mode plan)
- Any action other than rewriting the selection: pressing keys in other apps,
  submitting forms, launching/automating apps, browser automation.
- Screen capture, OCR, or window/AX *context* beyond the selection itself.
- Multi-step agent loops, tool registries, macros, or task handoff.
- Language-inferred mode switching (deciding "command vs dictation" from the
  words). The mode boundary is the **hotkey**, full stop.
- Inline diff/preview UI (Cmd-Z is the v1 escape hatch, consistent with
  ADR-022). A preview can come later if telemetry shows a need.

## Architecture — reuse map

| Concern | Reuse (shipped today) | New glue needed |
|---|---|---|
| Trigger (hold) | `HotkeyManager` `.holdOnly`; `AppHotkeyCoordinator` auxiliary-hotkey template; `HotkeyTrigger` defaults/validation | A dedicated trigger + settings accessor + a hold gesture for it (the aux template uses keyDown-only `GlobalShortcutManager`; this mode needs `HotkeyManager` hold semantics) |
| Selection snapshot | `SelectionCaptureService.captureSelection()` → text + AX element + `SelectionCaptureTarget` | none |
| Record + transcribe | `DictationService.startRecording` / `stopRecording` (Parakeet) | a thin session that records while held and returns the instruction string, not a paste |
| Instruction → result | `LLMService.transformStream(text:prompt:)` + existing `buildTransformMessages` | none (feed instruction as `prompt`) |
| Apply result | `SelectionReplacementService.pasteIntoCurrentFocus` | none |
| Overlay UI | `DictationOverlayController` non-activating panel; dormant `SessionKind.command` (`commandSelectedText` / `commandPromptText`); `TransformSpikeProgressPanel` chrome | wire `.command` to the new coordinator |
| Orchestration | pattern of `TransformsCoordinator` (capture → run → replace, cancel-then-restart serialization) | a `SpokenTransformCoordinator` that inserts the record+transcribe step between capture and run |
| History | `TransformHistoryRepository` / `transform_history` | none (new capture-path tag value) |

The one genuinely new component is **`SpokenTransformCoordinator`** (app layer,
outside SwiftUI), which sequences: capture selection → start hold recording →
on release, transcribe → run transform with the transcript as prompt → replace.
Everything it calls already exists.

## Design decisions and invariants

**Recommended decisions (owner to confirm the starred ones):**

1. ★ **Mode boundary = a dedicated hotkey, not language inference.** Predictable,
   and plain dictation can never accidentally become a command. (Answers parked
   Open Question #1; matches the original F10a "Fn+Ctrl" design.)
2. **Capture on key-down, before the panel shows,** while the host app is still
   frontmost — the selection exists then and the non-activating panel never
   steals it.
3. ★ **No-selection behavior: cancel with a hint** ("Select text first"). Do
   **not** implicitly Cmd+A (ADR-022 rejected that), and do not silently fall
   through to plain dictation in v1 (keeps the boundary clean). Dictation
   fallback is a possible later refinement.
4. **Reversible by construction.** `.pasteIntoCurrentFocus` + Cmd-Z is the
   escape hatch; the replace phase is non-cancellable once paste begins (reuse
   the Transforms rule so we never half-paste).
5. **The selection is data, the spoken words are the instruction.** Reuse
   ADR-022's system prompt that already separates "instruction" from "text to
   transform"; the prompt-injection surface is identical to today's Transforms,
   not new. (If we later add app/window context, revisit this.)
6. **Privacy unchanged from Transforms.** Selection + instruction go only to the
   user's configured provider — on-device if they chose a local model. No audio,
   transcript, selected text, or instruction in telemetry (ADR-022 §8 posture).
7. **Failure buckets are structural only:** no selection, accessibility not
   authorized, no speech detected, no LLM provider configured, target changed,
   provider error, cancelled.

## Phased delivery

- **Phase 0 — Spike (1 sitting).** Hard-wire the dedicated hotkey → capture →
  record → transcribe → `transformStream(text:prompt:)` → paste, behind the
  flag, no settings UI. Validate the end-to-end feel and focus preservation in
  TextEdit, Notes, Slack, Mail, a Safari textarea, and VS Code/Cursor. Reuse the
  paste-target reliability matrix the parked plan already calls for.
- **Phase 1 — MVP behind the flag.** `SpokenTransformCoordinator`, the dedicated
  trigger + Settings accessor + conflict validation, the `.command` overlay
  wired (captured selection + live instruction transcript + progress),
  `transform_history` write, content-free telemetry, the structural failure
  buckets and their overlay copy. Default off.
- **Phase 2 — Productize.** Settings surface (enable + rebind), onboarding/
  discoverability copy, the telemetry allowlist cross-repo change, docs
  (spec F-section + ADR-022 amendment / ADR-026), staged flag flip to Beta.
- **Later (not in this plan).** Optional dictation fallback on empty selection;
  optional inline diff/preview; "save this spoken instruction as a reusable
  Transform" (fuzzy-match the instruction against saved prompts).

## CLI / agent-native parity

Parity already exists: `macparakeet-cli llm transform --prompt "<instruction>" -`
runs a free-text instruction over stdin text through the same `LLMService`
path. The GUI Spoken Transform is simply the voice front-end onto that proven
Core primitive, so an agent can already reproduce the transform headlessly. No
new CLI surface is required for v1; if we later add a "save spoken instruction
as Transform" affordance, it maps onto the existing `transforms create`.

## Testing strategy

- **Core (deterministic, no GUI):** extend the `TransformExecutor` test pattern
  with a spoken-instruction case — fake capture backend, a fake/mlocked
  transcription that returns the instruction string, `MockTransformLLMService`,
  fake replacement backend. Assert: instruction string is passed as `prompt`;
  empty selection short-circuits before transcription/LLM/paste; empty/`""`
  instruction is handled; structural failure buckets map correctly.
- **Coordinator:** capture → record → transcribe → run → replace ordering;
  cancel mid-record (Escape) aborts cleanly with clipboard/selection intact;
  re-trigger uses cancel-then-restart serialization.
- **Hotkey:** dedicated trigger registers, validates conflicts against
  dictation/meeting/Transform bindings, and Escape-cancels.
- **Focus/selection:** non-activating panel keeps the host frontmost; selection
  survives panel appearance (the existing `SelectionCaptureService` tests cover
  the capture half).
- Run `swift test` before declaring complete (project rule).

## Telemetry

New content-free events mirroring Transforms: `spoken_transform_executed`
(provider, model, latency bucket, capture path, replacement path),
`spoken_transform_failed` (structural error type), and an operation rollup.
**Reminder:** any new `TelemetryEventName` is a two-repo change — the website
`ALLOWED_EVENTS` allowlist must add the same names or the Worker drops the whole
batch. Fold into the Phase 2 allowlist change.

## Open questions for the owner

1. **Hotkey default.** Revive F10a's `Fn+Ctrl`, or pick a fresh chord? (Must
   survive the conflict matrix against dictation/meeting/Transform bindings.)
2. **Provider posture for v1.** Allow any configured provider (local or cloud,
   same as Transforms), or restrict the first release to a recommended model for
   instruction-following quality? Recommend: same as Transforms — no new gate.
3. **Empty-selection behavior.** Confirm "cancel with hint" for v1 vs. the
   dictation-fallback refinement.
4. **Naming.** "Spoken Transforms" (ties to the shipped Transforms feature and
   signals it's an extension, not an agent) vs. reviving the "Command Mode"
   name (carries removed-feature and scope-creep baggage). Recommend the former.

## Risks

- **Quality of free-form instructions.** A dictated instruction is messier than
  a hand-tuned saved prompt; small/local models may follow it poorly. Mitigation:
  same provider choice as Transforms; surface a clear failure rather than a bad
  silent rewrite; "save as Transform" later lets power users promote a good
  instruction to a tuned prompt.
- **Selection capture flakiness in some apps** (already a known Transforms
  reality). Mitigation: reuse the AX-first + clipboard-fallback service and its
  app reliability matrix; fail structurally ("couldn't read a selection") rather
  than guessing.
- **Mode confusion** ("did I just dictate or command?"). Mitigation: distinct
  hotkey + visually distinct overlay (`.command` kind shows the captured
  selection), never language inference.
- **Scope creep toward "agent mode."** Mitigation: this plan's hard boundary is
  text-in/text-out on a selection; anything else stays in the parked plan.
