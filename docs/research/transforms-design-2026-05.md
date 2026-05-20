# Transforms — Design Exploration

> Status: **HISTORICAL DESIGN INPUT**. Superseded by ADR-022 and the productized Transforms implementation on `main`; kept as the design rationale that led to the shipped surface.
> Updated: 2026-05-16
> Related: `wisprflow-parity-2026-05.md` (audit that triggered this), `plans/active/2026-05-voice-command-agent-mode.md` (the voice-driven sibling), `docs/agent-mode-vision.md` (north-star framing)

Implementation update: Phase 1 and Phase 2 are now complete on `main`.
`Polish`, `Distill`, and `Decide` ship as built-in Transform prompt rows;
the Transforms tab, hotkey registry, CLI surface, and local Transform history
are implemented. Future work is richer editing/review affordances and the
voice-driven command layer.

## Thesis

**Transforms — system-wide hotkey-driven LLM rewrites on selected text — is the right next major surface for MacParakeet.** It's commonly framed as a writing-assistant feature (WisprFlow's `Polish` and `Prompt Engineer` on Opt+1/Opt+2), but for us it's better understood as the **hotkey-driven half of Command Mode**: the same selection-capture → LLM-rewrite → in-place-replace primitive that voice Command Mode will need, with a much simpler trigger.

Building Transforms first lays the foundation. The voice variant ("select text, hold Fn, say 'make this more formal'") becomes a swap on the trigger layer once the primitive is solid.

## Why this is more conservative than it looks

Reading the audit, it's tempting to characterize this as scope creep — MacParakeet drifting from "voice app" into "writing assistant." Two reasons that framing is wrong:

1. **The roadmap already says this.** `plans/active/2026-05-voice-command-agent-mode.md` lists "selected-text rewrite" as candidate capability #1. `docs/agent-mode-vision.md` names "rewrite selected text" as an Agent Mode primitive. We are not adding a new product direction; we are picking the shortest path to a primitive we've already committed to.

2. **The pieces are mostly built.**

   | Piece | Status |
   |---|---|
   | LLM provider stack (`LLMService.transform`, `transformStream`, `transformDetailed`) | Built; used by GUI Transforms and CLI surfaces |
   | Prompt model with `.transform` category | Built; built-ins now ship as `Polish`, `Distill`, and `Decide` |
   | Global hotkey infrastructure (`GlobalShortcutManager` for chord-triggered actions; `HotkeyManager` for gesture-based; `HotkeyRecorderView` for binding UI) | Built; `TransformsHotkeyRegistry` dispatches bound Transform shortcuts |
   | Dictation has both `rawTranscript` and `cleanTranscript` stored separately | Built; ready for Undo AI edit too |
   | Accessibility permission already requested (for paste simulation) | Built |
   | Paste-back via simulated Cmd+V | Built; used by dictation insertion |
   | CLI surface that proves the prompt-driven rewrite shape works | Built (`macparakeet-cli llm transform`) |

   The originally new pieces were narrow: AX-based selection capture, the
   Transforms management UI, and the bind-N-hotkeys-to-N-transforms mux. ADR-022
   implements that spine on `main`.

## What we're building

A user-facing surface where:

1. The user binds a hotkey (e.g., Opt+1) to a Transform.
2. A Transform is `{name, hotkey, prompt, optional running label}` — backed by the existing `Prompt` model with `category = .transform`.
3. With text selected in any macOS app, pressing the hotkey:
   - Captures the selected text (AX-first; clipboard-hijack fallback)
   - Runs it through the bound prompt via the user's configured LLM provider
   - Replaces the selection in place with the result
4. Ships with three built-in transforms: `Polish` (Opt+1), `Distill` (Opt+2), and `Decide` (Opt+3). Users can edit them, clear their hotkeys, or create their own.
5. Fails loudly and recoverably when something goes wrong (no selection, no provider configured, AX denied, LLM timeout).

Explicit non-goals for v1:

- Voice-driven trigger. Out of scope. The hotkey path is explicit (user has visibly highlighted the text they want transformed), which is the right shape for a first cut. Voice-driven rewrites of selected text are tracked in `plans/active/2026-05-voice-command-agent-mode.md` and stay there; the architecture below is general enough to be reused if/when we ship that, but we make no commitment in this design.
- Live streaming tokens into the target text field. Too fragile across app variants. Show progress in a small overlay; paste the full result when streaming completes.
- Rule-toggle composition (WisprFlow's `Make more concise` / `Reword for clarity` togglable rules that re-render a diff preview live). Polished detail; not v1.
- Diff preview pane in settings. Same — polish, not v1.
- Per-app transform routing (Polish behaves differently in Gmail vs Slack). Defer.
- Inline acceptance UI ("accept change?" preview before paste). The "Cmd+Z to undo" macOS default is the v1 escape hatch.

## Trigger

A Transform is invoked by **pressing its bound hotkey** (e.g., `Opt+1`) while text is selected in any macOS app. That's the only trigger path in v1.

The user-facing model is deliberately explicit: the user has *visibly* highlighted the text they want transformed, then presses a key. No mode disambiguation, no listening for spoken intent, no implicit context grabbing. The whole feature reads as "this hotkey does that to that highlighted text" — which is what makes it easy to learn and trust.

Other trigger surfaces (right-click context menu, floating action button, menu bar dropdown) are explicitly out of scope. Right-click requires AX-injecting into the host app's native menu (not viable on macOS); floating action buttons require heavy window-management work; a menu bar dropdown solves discoverability but not speed, which is what the management page's hotkey badges and the in-app explainer are for.

## Architecture sketch

Five components. Three are new; two are extensions of existing code.

### 1. `SelectionCaptureService` (new, in `MacParakeetCore/Services/System/`)

```swift
public enum SelectionCaptureResult {
    case ax(text: String, element: AXUIElement)   // can write back via AX
    case clipboard(text: String, savedClipboard: NSPasteboardItemSnapshot?)  // must paste-back via Cmd+V
    case empty                                     // selection was empty
    case failed(SelectionCaptureError)
}

public actor SelectionCaptureService {
    public func captureSelection(
        timeout: Duration = .milliseconds(250)
    ) async -> SelectionCaptureResult
}
```

Strategy:

1. Query the system-wide focused UI element via `AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute`.
2. Read `kAXSelectedTextAttribute` from the focused element. If non-empty, return `.ax`.
3. If AX path fails or returns empty, fall back to clipboard hijack:
   - Snapshot current clipboard contents (multiple types, not just string).
   - Simulate `Cmd+C`.
   - Poll the clipboard for a change with the 250ms timeout (changeCount delta is the right signal).
   - If the clipboard changed, return `.clipboard` with the saved snapshot.
   - If it didn't change, return `.empty`.

Trap to avoid: don't restore the clipboard immediately after reading. The paste-back path (component 5) needs the result text on the clipboard. Restore only after paste-back completes or fails.

### 2. `SelectionReplacementService` (new, in `MacParakeetCore/Services/System/`)

```swift
public actor SelectionReplacementService {
    public func replace(
        with newText: String,
        in context: SelectionCaptureResult,
        cancellation: AnyCancellable?
    ) async throws
}
```

Strategy by context:

- `.ax`: try `AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute, newText)`. If it succeeds and the read-back matches, done.
- AX-write failure or `.clipboard` context: put `newText` on the clipboard, simulate `Cmd+V`, wait for the paste to complete (a few hundred ms), restore the original clipboard snapshot.
- On any failure, attempt clipboard restore and propagate.

The clipboard backup/restore dance is well-known to be racy; cribbing from Raycast / Espanso's approach is the right move. The 250ms read timeout and ~500ms write timeout match conventional values.

### 3. `TransformExecutor` (new, in `MacParakeetCore/Services/Transforms/`)

```swift
public actor TransformExecutor {
    public func execute(
        transform: Prompt,                    // category == .transform
        captured: SelectionCaptureResult,
        progress: @Sendable (TransformProgress) -> Void
    ) async throws -> TransformResult
}

public enum TransformProgress: Sendable {
    case capturing
    case llmStarted
    case llmStreaming(String)   // accumulated text
    case llmCompleted(String)
    case pasting
    case done
    case failed(Error)
}
```

Wraps the capture → LLM call → replace pipeline as one async task. Owns cancellation: pressing Esc, triggering another transform, or the user clicking the overlay's cancel button cancels the in-flight task. Reports progress for the UI overlay.

Calls into existing `LLMService.transformStream(...)` for the LLM stage.

### 4. Hotkey routing (extension of existing `GlobalShortcutManager`)

The existing `GlobalShortcutManager` already handles "single key chord triggers an action." It currently has a single `onTrigger` closure. We need N of them — one per Transform binding.

Options:

- **A — multiple `GlobalShortcutManager` instances.** One per active Transform. Simple. May fight each other if they share an event tap; needs validation.
- **B — new `TransformsHotkeyRegistry`** that owns a single event tap and maps key combos to Transform IDs. Cleaner; one event tap, one dispatch table. Recommended.

Either way, the existing `HotkeyRecorderView` should be reusable for the per-Transform binding UI (it already renders modifier badges and detects key combos).

Collision rules:
- Transforms hotkeys MUST include a modifier (matches WisprFlow's behavior — the screenshot literally validates this with "Shortcut must include modifier key…").
- Transforms hotkeys must not collide with the user's dictation hotkey or the meeting-toggle hotkey. Surface a clear inline error in the binding UI.
- Don't collide with the well-known macOS Opt+letter combos that produce alt-characters (Opt+e, Opt+u, etc. are dead keys). Restrict the default Opt+1..Opt+9 range and let users override.

### 5. Transforms management UI (new, in `Sources/MacParakeet/Views/Transforms/`)

A new top-level sidebar item — sibling of Vocabulary, Library, Settings.

Layout (sketched, not pixel-final):

```
+----------------------------------------------------+
|  Transforms                              [+ New]   |
|  -----------------------------------------------   |
|  ⓘ Need an LLM provider configured. [Configure]    |  (only when no provider)
|                                                    |
|  Polish              ⌥1   [Edit]                 |
|  Distill             ⌥2   [Edit]                 |
|  Decide              ⌥3   [Edit]                 |
|  My custom one       ⌥4   [Edit]                 |
|                                                    |
|  + Create new                                      |
+----------------------------------------------------+
```

Edit pane: Name field, Hotkey recorder, Prompt body editor, optional running label, and reset controls for built-ins. Per-Transform model selection is deferred; v1 uses the configured global LLM provider.

Discoverability: show the bound hotkey badge inline with each Transform row (WisprFlow's pattern is good here). Surface a brief Transforms tour on first launch after an LLM provider gets configured.

## Visual feedback while a Transform runs

Two paths considered:

1. **Inline streaming** into the target text field. Pro: feels magical. Con: every text field handles "rapid-fire inserts via paste" differently — many apps batch undo, some flicker, some fight with autocomplete. Skip for v1.
2. **Small floating pill** anchored near the trigger context (cursor area, or screen-edge fallback). Shows the verb form of the Transform's name + a custom animated loader. Disappears on completion. **Pick this.** WisprFlow's reference: a small dark pill reading *"Polishing…"* with a spinning loader on the right.

### Copy

Pill text is the Transform's name in its gerund/verb form:

| Transform | Pill copy |
|---|---|
| Polish | *Polishing…* |
| Distill | *Distilling…* |
| Decide | *Deciding…* |
| Summarize (custom) | *Summarizing…* |
| (any user-defined Transform without a verb form) | *Transforming…* (fallback) |

Each Transform definition gets an optional `runningLabel: String?` field. If unset, we use *"{Name}ing…"* as a heuristic, falling back to *"Transforming…"* for awkward names. Users can edit `runningLabel` in the Transform's edit pane.

### Animated loader — new visuals, please

We want a **custom loader animation** for this surface, not a stock spinner and not a copy of the dictation/meeting indicators. Transforms is a new surface and deserves its own motion vocabulary that says "thinking" and "refining" rather than "listening" or "recording."

Design constraints:
- Small (fits inside a ~28pt-tall pill)
- 60fps-smooth, ideally GPU-friendly (Canvas or TimelineView in SwiftUI)
- Coherent with our brand: warm coral, sacred-geometry / organic feel, not techy/digital
- Looks "endless" without a hard loop seam — the user might watch it for 2 seconds or 8 seconds depending on LLM latency

Three concrete directions worth prototyping (pick one for v1, the others stay in a research note):

1. **Coral particle orbit.** A handful of small coral dots orbit a center point on a slowly precessing axis. Each dot has a faint trailing fade. Feels alive and "thinking," not mechanical. Reads at any duration.
2. **Morphing rosette.** A miniature version of the meeting-pill rosette continuously morphs between regular polygons (hexagon → heptagon → octagon → back). Ties into our existing geometric language but doesn't read as "recording." Slow tempo (~1.5s per morph cycle) to feel deliberate.
3. **Bezier scribe.** A single coral curve traces a continuous loop — drawing forward, then erasing from the tail at the same rate, so the curve appears to be "writing" itself indefinitely. Cursive feel. Best fit for the "polishing your words" mental model.

My lean: **#3 (Bezier scribe)** for v1. It's the most on-theme for a writing/refinement surface, the least likely to be confused with the dictation overlay's waveform or the meeting pill's rosette, and the easiest to communicate as "MacParakeet has its own animation language."

Implementation note: the loader is a self-contained SwiftUI view (`TransformLoader.swift` under `Sources/MacParakeet/Views/Transforms/`). It exposes a single `isActive: Bool` binding so the same view can be reused in the management UI's preview pane (showing the loader idle at the corner of each Transform card on hover, as a discovery hint).

## No-selection and error UX

The "no selection when the hotkey fired" case is the most common failure mode and the most teachable moment. WisprFlow handles it with a friendly educational toast rather than an error — *"Hey, select text first! First, highlight the text you want to transform, then press opt + 1"* (one screenshot also showed *"Select text to apply a transform — Highlight any text, then press opt + 2"*). The pasteboard-pill icon and warm copy turn the failure into onboarding. We should match that tone.

| Situation | UX |
|---|---|
| Hotkey fired with no selection (AX returns empty, clipboard fallback also returns empty) | Friendly toast near the trigger: *"Hey, select text first! Highlight the text you want to transform, then press {hotkey} again."* — uses the actual bound hotkey in the copy, not a generic placeholder. |
| No LLM provider configured | Toast: *"Transforms need an LLM provider"* with a `[Configure]` action that opens Settings. |
| LLM error (network, rate limit, timeout) | Toast: *"Transform failed — clipboard restored."* Restore the original clipboard snapshot. |
| AX-write failure mid-replace | Auto-fallback to clipboard paste path. Only surface an error if both paths fail. |

In all cases: if the original clipboard was preserved, restore it. Users who triggered a transform should not lose their copied-but-uncommitted state.

### Decision: no implicit Cmd+A on empty selection

WisprFlow appears to do an implicit `Cmd+A` (select-all-in-focused-field) when the hotkey fires with no current selection, then transforms the resulting all-text. We are **not** mirroring this. On empty selection, show only the educational toast.

Reasoning:
- Dangerous in long-text contexts (a whole Notes document, a code editor file, a Cursor pane). The user presses Opt+1 expecting a small adjustment and instead the entire document gets sent to an LLM and replaced. Even Cmd+Z to restore feels scary at that scale.
- AX `Cmd+A` semantics vary by app — some apps select the entire document, some select only the visible line. Inconsistent behavior across apps is worse than always-explicit.
- The educational toast already does the teaching job. Friction from "press Opt+1 → see toast → highlight → press Opt+1" is a one-time cost; surprise document replacement is recoverable but trust-eroding.

The behavior is therefore: hotkey fires with empty selection → friendly educational toast surfaces, nothing else happens, no clipboard or AX state touched.

## Phasing

Tight phasing keeps scope small and lets us validate the AX path before investing in UI.

**Phase 1 — Spine end-to-end (~1 sprint).** Goal: hardcoded Opt+1 → Polish working against the user's currently-configured LLM provider, no UI. **Completed.**

- Implement `SelectionCaptureService` with AX-first + clipboard fallback.
- Implement `SelectionReplacementService` with AX-write + paste-back fallback.
- Implement `TransformExecutor` calling `LLMService.transformStream`.
- Wire a single hardcoded transform on Opt+1 using a baked-in Polish prompt.
- Manual smoke test across: Notes, Mail, Slack desktop, Discord, Chrome, Safari address bar, Cursor, Xcode editor, Terminal. Each app gets a row in a spreadsheet of "AX worked / clipboard fallback / both failed."
- Decision gate: ship to nightly users on `main`. If the app coverage is bad (e.g., fails on Slack and Mail), step back and rethink before building UI.

**Phase 2 — Productize (~1 sprint).** Goal: shippable feature behind a feature flag. **Completed; enabled on `main`.**

- Wire `Prompt.category == .transform` to the executor via the new registry.
- Build the Transforms management UI (sidebar tab + edit pane).
- Ship three built-in transforms (`Polish`, `Distill`, `Decide`).
- Failure toasts and the floating progress pill.
- Onboarding nudge when LLM provider is unset.
- Feature flag in `AppFeatures` (`transformsEnabled`): introduced release-off during rollout, now `true` on `main` after telemetry allowlisting.

**Phase 3 — Polish (~½ sprint).** Goal: improve the shipped surface with richer editing and review affordances.

- Rule-toggle composition for `Polish` (the WisprFlow micro-pattern).
- Diff preview in the Transforms edit pane.
- Per-Transform usage telemetry (opt-out, no content captured — follow the existing telemetry shape).

## Risk and unknowns

| Risk | Mitigation |
|---|---|
| AX `kAXSelectedTextAttribute` is inconsistent across apps (web fields, Electron, Xcode editor) | Always have the clipboard fallback. Treat AX as the fast path, not the only path. Phase 1's smoke matrix tells us how often we'll fall back. |
| Clipboard backup/restore dance is racy with user activity | Snapshot before triggering Cmd+C; restore after Cmd+V completes; if the user copies during the transform, we accept some clipboard loss (logged warning). Document this trade-off. |
| Hotkey collisions with macOS / app shortcuts | Validate at bind time. Default to Opt+1..Opt+9 (mostly safe). Provide collision diagnostics in the binding UI. |
| Latency from LLM round-trip makes the feature feel slow | Phase 2 shows a progress pill so the user knows work is happening. Phase 3+: explore streaming-into-paste-buffer (high risk, deferred). |
| Cost / privacy of cloud LLM round-trips on every transform | Reuse the user's explicit LLM provider configuration. Local providers (LM Studio, Ollama, Local CLI) remain the privacy-preserving path; cloud providers are opt-in. |
| Feature ships before app coverage is proven | Phase 1 has an explicit decision gate before any UI work begins. |
| Existing dictation hotkey conflicts during transform run | Suppress dictation triggers while a transform is in-flight (one transform at a time; cancel-then-restart if the user re-triggers). |

## What needs locking (open questions for the owner)

1. **Sidebar IA**: new top-level `Transforms` item, or nested under a larger surface (e.g., a new `Prompts` parent that contains both transform-prompts and meeting-result-prompts)? My lean: top-level for v1, refactor later if it crowds the sidebar.
2. **Built-in default count**: resolved by ADR-022 as three: Polish, Distill, and Decide.
3. **Model selection per Transform**: deferred; v1 uses the user's global LLM provider.
4. **Telemetry scope**: count of transform-triggers per built-in name (opt-out), or no telemetry on this surface at all? My lean: per-name counts only, no prompts, no content — consistent with ADR-012 and the telemetry allowlist process.
5. **Free vs paid gating**: WisprFlow gates Transforms behind Pro. We're free/GPL. Stays free; users bring their own local or cloud LLM provider.

## Connection to Undo AI edit

The same conversation that prioritized Transforms accepted Undo AI edit as a small follow-up. The work is independent of this design — `Dictation` already stores `rawTranscript` and `cleanTranscript` separately, so it's a context-menu affordance in `DictationHistoryView.swift` that swaps the displayed and exported text back to `rawTranscript`. A separate ~1-day task that doesn't need an ADR.

## Implementation Status

This design fed ADR-022 and `plans/completed/2026-05-transforms-phase-2-productize.md`.
The concrete implementation artifacts are complete:

1. **Spike** — shipped through PR #278 and follow-up polish.
2. **ADR** — `spec/adr/022-transforms-system-wide-rewrite.md`, now accepted/implemented.
3. **Product plan** — archived at `plans/completed/2026-05-transforms-phase-2-productize.md`.

Remaining Transform work should start from the current shipped surface, not this
historical open-work list: rule toggles, diff preview, per-Transform model
selection, and voice-triggered command mode are all follow-up scope.
