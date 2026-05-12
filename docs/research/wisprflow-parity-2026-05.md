# WisprFlow Feature Parity Audit — May 2026

> Status: **ACTIVE**. Snapshot of WisprFlow Pro's current feature surface (May 2026, captured from the macOS app) and how MacParakeet stacks up against each surface today.
>
> Companion doc: `wisprflow-deep-dive.md` (Feb 2026, HISTORICAL) covers the high-level positioning. Design follow-on: `transforms-design-2026-05.md` covers the chosen build-direction for Transforms.

## Decisions (2026-05-11)

After walking through this audit with the owner, three calls were made:

1. **Auto Cleanup gradations — skip.** Keep `processingMode` as the current binary raw/clean deterministic pipeline. AI Formatter stays as a single optional polish layer with one customizable prompt. Don't ship Light/Medium/High named levels.
2. **Undo AI edit — ship.** Surface a per-row affordance in the dictation history that swaps the displayed/exported text from `cleanTranscript` back to `rawTranscript`. Schema already stores both — pure UI work.
3. **Transforms — prioritize.** Build the hotkey-driven version (Opt+N to rewrite selected text in any app) as the next major surface. Treated as foundation work for the already-planned voice-driven Command Mode (see `plans/active/2026-05-voice-command-agent-mode.md` candidate capability #1 and `docs/agent-mode-vision.md` lines 350–351). The hotkey and voice variants share the same underlying primitives — capture selection, run prompt through LLM, replace in place — so the hotkey form is the shortest path to those primitives.

The full design exploration for Transforms lives in `transforms-design-2026-05.md`.

## TL;DR

WisprFlow Pro now organizes its post-dictation cleanup into five sidebar sections: **Dictionary**, **Snippets**, **Style**, **Auto Cleanup**, and **Transforms**. We have rough parity on Dictionary and Snippets (different UI shape, same underlying capability). We have nothing comparable to Style (per-app tone routing) or Transforms (Opt+N hotkeys that LLM-rewrite selected text anywhere). Auto Cleanup is binary in MacParakeet (raw vs clean) where WisprFlow ships four gradations.

| WisprFlow surface | MacParakeet today | Coverage | Strategic fit |
|---|---|---|---|
| Dictionary (word teach + misspelling correction) | Custom Words (`word` + optional `replacement`) | Capability parity, UX-lite | Aligned — already shipped |
| Snippets (trigger → expansion) | Text Snippets in Vocabulary panel | Capability parity, UX-lite | Aligned — already shipped |
| Style (per-app tone: Slack vs Gmail vs Discord) | None | **Zero coverage** | Tension with local-first; LLM-dependent |
| Auto Cleanup (None / Light / Medium / High) | `processingMode` raw/clean + binary AI Formatter | Partial — coarse | Easy to expand; aligned |
| Transforms (Opt+N to rewrite selected text in any app) | CLI `llm transform` only | **Zero GUI coverage** | Net-new surface; expands product scope |

The interesting strategic question is whether we want to follow WisprFlow toward "writing assistant that lives over every text field" or stay "fast local dictation + transcription + meetings." Each gap below is annotated with that lens.

---

## 1. Dictionary

### WisprFlow

Sidebar item `Dictionary`. Three tabs: All / Personal / Shared with team. "Add new" modal exposes two toggles:

- **Correct a misspelling** — when OFF, a single text field "Add a new word" (just teach the recognizer the existence of the word, e.g. proper names, jargon). When ON, two fields appear: `Misspelling → Correct spelling`. So it's one feature with two intents in one modal.
- **Share with team** — surfaces the entry to teammates (team is a Pro/business concept, not relevant solo).

Empty-state copy: *"Flow learns your unique words and names — automatically or manually. Add personal terms, company jargon, client names, or industry-specific lingo."* The "automatically" hint is interesting — WisprFlow learns words from corrections, which we already model via `CustomWord.Source.learned`.

### MacParakeet today

- Model: `Sources/MacParakeetCore/Models/CustomWord.swift` — fields `word`, `replacement: String?`, `source: .manual | .learned`, `isEnabled`.
- Pipeline: step 2 of the deterministic `TextProcessingPipeline` — regex word-boundary replacements, case-insensitive, longest-trigger-first.
- UI: `Sources/MacParakeet/Views/Vocabulary/CustomWordsView.swift` — search, add, delete, enable/disable. Word and replacement displayed side-by-side.
- Storage: `custom_words` table.

### Gap analysis

| Capability | WisprFlow | MacParakeet | Gap |
|---|---|---|---|
| Teach a single word (no replacement) | Yes (toggle off) | Yes (`replacement` is optional) | UX framing only |
| Misspelling → correction | Yes (toggle on) | Yes (`replacement` non-nil) | UX framing only |
| `.learned` from corrections | Yes ("automatically") | Schema supports it, **no producer wired up** | Behavior gap |
| Share with team | Yes | N/A | Out of scope (solo app) |

The capability gap is small. Two meaningful UX nits worth fixing:

1. **Modal framing.** Our add form shows two fields side-by-side; users have to infer that leaving the replacement empty means "just teach the word." A WisprFlow-style toggle (`Correct a misspelling`) makes the intent explicit and matches how users think about it.
2. **`.learned` is dead enum case.** We model auto-learning but don't actually populate `.learned` entries from user corrections. Either wire it up (e.g., when a user edits a freshly-pasted dictation, diff against the raw transcript and offer to save the correction as a learned word) or drop the case to remove dead surface.

### Recommendation

Keep — this is on-spec. Two small follow-ups:

- Add `Correct a misspelling` toggle to the Add Word modal (cosmetic but clarifying).
- Decide whether to ship auto-learning (interesting power-user behavior) or remove the `.learned` enum case (dead-code cleanup). Auto-learning is a real differentiator if we do it locally — WisprFlow ships it but their cloud sees every correction; ours could be 100% on-device.

---

## 2. Snippets

### WisprFlow

Sidebar item `Snippets`. Same All / Personal / Shared layout. Empty-state copy: *"Save anything you type often — your email, an intro, a prompt — and say a word or phrase to immediately replace it in place."* Examples shown: `"my LinkedIn"` → URL, `"rewrite prompt"` → "Rewrite this to be more concise…", `"intro email"` → email body.

Add modal: `Snippet` (trigger) + `Expansion` text field + Share with team toggle.

### MacParakeet today

- Model: `Sources/MacParakeetCore/Models/TextSnippet.swift` — fields `trigger`, `expansion`, `isEnabled`, `useCount`, optional `action: KeyAction?`.
- Pipeline: text-only snippets at step 4; action snippets (trailing trigger + key action like Enter) at step 3.
- UI: `Sources/MacParakeet/Views/Vocabulary/TextSnippetsView.swift` — same management surface as Custom Words.
- Bonus we have that they don't: trailing action snippets (e.g., say "send it" → expand to "Best, Dan" + press Enter). WisprFlow only shows pure text expansion.

### Gap analysis

| Capability | WisprFlow | MacParakeet | Gap |
|---|---|---|---|
| Trigger → text expansion | Yes | Yes | — |
| Trigger → text + keystroke | No (apparently) | Yes (KeyAction) | We're ahead |
| Use-count tracking | Not shown | Yes (`useCount`) | We're ahead, just don't surface it |
| Standalone sidebar page | Yes | Embedded in Vocabulary | UX framing |

### Recommendation

Capability parity (plus a small lead on action snippets). The only real opportunity is presentational: WisprFlow promotes Snippets to a top-level sidebar item with a bold hero card; our Snippets are buried inside Vocabulary alongside Custom Words and processing mode toggles. If we ever do a sidebar overhaul, splitting these into discoverable top-level items would help — users probably don't realize we have snippets at all. Low priority; ship-blocker no.

---

## 3. Style — per-app tone routing

### WisprFlow

Sidebar item `Style`. Four context tabs, each pinned to a set of apps detected from the frontmost app's bundle ID:

| Tab | Apps it covers (logos shown) | Preset cards |
|---|---|---|
| Personal messages | WhatsApp, Telegram, Discord, Instagram, … | Formal / Casual / very casual |
| Work messages | Slack, Teams, LinkedIn, … | Formal / Casual / Excited! |
| Email | Gmail, Spark, Outlook, Mail, … | Formal / Casual / Excited! |
| Other | Linear, ChatGPT, Notes, … | Formal / Casual / Excited! |
| Auto Cleanup (Beta) | All apps | None / Light / Medium / High |

Each preset shows a worked example. "Formal" gets `Hey,` and a period; "very casual" drops capitalization and final punctuation entirely. Caveat banner: *"Style formatting only applies in English. More languages coming soon."*

The mechanism is clear: WisprFlow reads frontmost-app bundle ID, picks the matching tab's preset, and sends both the transcript and the style preset to a cloud LLM. The LLM rewrites accordingly before paste.

### MacParakeet today

Zero coverage. Confirmed by grep — we don't query `NSWorkspace.frontmostApplication` for routing, we have no per-app preference surface, and our `processingMode` is a single global enum.

We do have `Sources/MacParakeetCore/TextProcessing/AIFormatter.swift` with a user-customizable prompt template that runs through whichever LLM provider the user has configured. But it's a single global prompt — no per-app branching.

### Gap analysis

This is the largest capability gap. It's also the one with the most direct tension with our north star.

**Why this is interesting:**
- Real value when it works. The example deltas in the screenshots (formal email vs lowercase Discord DM) are exactly the friction users currently fix by hand.
- The mechanism is straightforward to implement: bundle-ID lookup → preset selection → prompt suffix.

**Why we'd think twice:**
- It only works well with an LLM in the loop. Deterministic pipelines (our current `clean` mode) can't pull off "rewrite this with the energy of an excited Slack message." So shipping this means making LLM cleanup a first-class path, not a side feature.
- Local-first commitment. We can mitigate by routing through Apple Foundation Models or a local Ollama provider when available, and falling back to user-configured cloud providers. ADR-002 allows opt-in cloud LLM, so this is consistent in principle — but defaulting users into LLM-rewriting every dictation crosses a line we haven't crossed before.
- App-list churn. WisprFlow ships a hardcoded list of which apps map to which tab. Maintaining that list (and answering "why isn't $APP in the work-messages tab?") becomes ongoing product work.

### Recommendation

Don't blindly copy. But there's a coherent smaller version we could ship:

1. **Make AIFormatter context-aware.** Pass the frontmost app's bundle ID (and optionally the bundle name and category) into the prompt as a `{{contextApp}}` template variable. Power users get per-app behavior through prompt engineering; we ship none of the UI.
2. **Or ship a single "Tone" preset switcher.** Three or four global presets (`Faithful`, `Polished`, `Casual`, `Excited`) on the Auto Cleanup card — no per-app routing, just a global mood. This is the 80/20.

The full WisprFlow Style page is feature-creepy for our product shape. The bundle-ID-as-prompt-context move is cheap and aligned.

---

## 4. Auto Cleanup gradations

### WisprFlow

Auto Cleanup tab inside Style. Four levels with worked examples (same input "hey joey, we still on for coffee or…"):

- **None** — exact transcript, including mistakes.
- **Light** — fixes filler words and grammar. *"Hey Joey, are we still on for coffee? I think we should leave earlier to make it there in time. There might be traffic. What are you thinking?"*
- **Medium** — clarity and conciseness. Adds semicolons, restructures.
- **High** — rewrites for brevity and polish. *"Hey Joey, are we still on for coffee? Let's leave early to beat traffic. What do you think?"*

Important note: *"Note your original dictation is never lost. Just go to the three dots next to a recent dictation in the Home tab, then click 'Undo AI edit.'"* — original transcript is preserved separately, edit is reversible.

### MacParakeet today

Two independent layers:

- `Dictation.ProcessingMode` = `.raw` or `.clean`. `.raw` = no edits. `.clean` = deterministic 5-step pipeline (filler removal + custom words + snippet expansion + whitespace).
- `AIFormatter` — optional LLM polish layer, controlled by `aiFormatterEnabled: Bool` + `aiFormatterPrompt: String` in `AppRuntimePreferences`. Off by default; one global prompt.

So we have two levers that map roughly to "no edits" / "deterministic clean" / "deterministic + LLM polish" — three states, where WisprFlow has four with clearer naming.

We also already keep the raw transcript in the dictation history, so "Undo AI edit" is structurally feasible — we just don't expose a one-click revert.

### Gap analysis

| Level | WisprFlow | MacParakeet equivalent |
|---|---|---|
| None | Exact STT output | `processingMode = .raw` |
| Light | Filler + grammar | `processingMode = .clean` (no LLM) |
| Medium | Clarity/conciseness | `aiFormatterEnabled = true` with a Medium-shaped prompt |
| High | Brevity/polish rewrite | `aiFormatterEnabled = true` with a High-shaped prompt |
| Undo AI edit | One-click revert | Raw is stored, no UI |

The gap is mostly UI framing plus prompt curation. The hard part is already solved: we store the raw transcript.

### Recommendation

Worth doing, and it's the cleanest WisprFlow surface to borrow. Concrete shape:

1. Collapse the two existing toggles (`processingMode`, `aiFormatterEnabled`) into one **Cleanup Level** picker: `None`, `Light`, `Medium`, `High`. `None` and `Light` stay LLM-free (current behavior). `Medium` and `High` enable the LLM with curated default prompts.
2. Expose **Undo AI edit** on each history row — we already have the raw transcript saved next to the cleaned one.
3. Keep the customizable `aiFormatterPrompt` as an "advanced" override that replaces the High preset when set.

This is on-spec for the existing AIFormatter architecture and meaningfully closes the gap users will notice when comparing tools. ADR-implication: we'd want an ADR or amendment to ADR-004 (deterministic pipeline) to capture that Levels 3–4 deliberately add a non-deterministic LLM stage on top of the deterministic floor.

---

## 5. Transforms — system-wide hotkey rewrites

### WisprFlow

Sidebar item `Transforms` (Beta). The model is: select text in any app, press `Opt+1` (or `Opt+2`, etc.), and the selected text is replaced in place with an LLM rewrite per the bound transform's prompt.

Ships two defaults plus user-defined slots:

- **Opt+1: Polish** — *"Polish rewrites your text to sound clearer, in your voice."* Toggleable rules: Make more concise, Reword for clarity, Reorder for readability, Add structure for readability. Diff view shows strikethroughs (deleted text) and highlights (insertions): `hey so` → `Hey,`, `kinda long` → struck through, `cuz` → `because`. Each rule toggle re-renders the diff live.
- **Opt+2: Prompt Engineer** — *"Takes messy, spoken, unstructured thoughts and converts them into a clean, optimized AI prompt."* Output template includes **Title**, **Role & stance**, **Task**, **Context**, **Inputs available**, **Examples / References**, **Execution checklist**, **Conflict resolution**. Customizable prompt body in the right pane.
- **Create your own** — name + hotkey + prompt body. Empty state hints `Boss Mode` as a placeholder name. Validation: shortcut must include a modifier and a valid key/mouse.

There's also a global `Opt in` toggle for the whole Transforms feature, with copy: *"Toggles the Transforms feature to update your text with a single shortcut. Resets the shortcuts to default when disabled."*

Failure mode shown in one screenshot: *"Couldn't detect text in your text box — please click into your text box and try again."* — confirms they use AX text selection / focused element APIs, and gracefully fail when the AX path isn't viable.

### MacParakeet today

Zero GUI coverage. The pieces exist but are not wired into a system-wide hotkey path:

- `Sources/MacParakeetCore/Services/LLM/LLMService.swift` — has `transform(text:prompt:)`, `transformStream`, `transformDetailed`.
- `Sources/CLI/Commands/LLMTransformCommand.swift` — `macparakeet-cli llm transform` works on stdin/file.
- `Prompt` model has a `.transform` category that's never populated with shipped prompts. The Prompt Library is wired into meeting transcripts only (category `.result`).
- Hotkey infrastructure exists (custom hotkey support, ADR-009), but is currently bound to dictation triggers, not transform-on-selection.

So the LLM-rewrite primitive exists; what's missing is the surface: hotkey routing → AX-driven selection grab → paste-back.

### Gap analysis

This is the biggest net-new capability surface. Stack of pieces needed:

1. **Selection capture.** AX query for focused element + selected text. We do not currently do this. Fallback: copy-via-Cmd+C-simulation, read clipboard, write back. (WisprFlow's error message suggests they use AX-first and gracefully fail.)
2. **Hotkey routing.** Our hotkey system today is single-purpose (dictation trigger). Would need to extend to N transform-hotkeys with collision detection and per-transform binding UI.
3. **Transform definition UI.** Name + shortcut + prompt + rule toggles (the rule toggles are a nice WisprFlow detail — they let users tune a built-in prompt without writing one). We have prompt infrastructure but no "rule toggle" composition.
4. **Diff preview pane.** Showing a live diff of the expected transformation as you toggle rules — this is genuinely well done in their UI and is the kind of polish that signals "this is a real feature."
5. **Paste-back path.** Replace selection in place via AX (or fall back to clipboard-paste). We have paste simulation for dictation; this would reuse most of it.
6. **Built-in defaults.** Shipping a Polish-equivalent and a Prompt-Engineer-equivalent is the on-ramp.

### Recommendation

This is where the strategic decision actually lives. Two coherent answers:

**Path A — stay focused.** Ship nothing here. We are a dictation + transcription + meeting tool. Writing assistance is what Raycast AI, ChatGPT's macOS app, Claude's macOS app, and TextSnipped already do. We compete on "fastest local dictation," not "best inline rewrites." This is the lower-risk path and matches the existing positioning.

**Path B — add Transforms as a third leg.** If we believe dictation users also want post-dictation rewrites (and the conversion of dictation → polished prose → paste is genuinely the same job), then Transforms belongs in MacParakeet. Sequence:

1. Wire `Prompt.category = .transform` to a hotkey-driven path. Reuse the existing Prompt Library UI for the management surface.
2. Implement AX selection-capture with clipboard fallback (the WisprFlow error toast tells us this is the right boundary).
3. Ship two defaults that mirror Polish and Prompt Engineer (we already have similar prompt shapes in our Prompt Library for meetings — porting is mostly copy).
4. Skip the rule-toggle composition in v1 — it's a delightful detail but adds a lot of UI surface. Ship raw editable prompts only.
5. Skip the live diff preview in v1. Hard to implement well, easy to live without.

The hidden cost on Path B is the AX integration; once we ship system-wide selection capture, users will expect everything else (commands like "translate this," "make it bullets," etc.) and our scope expands.

My honest read: **defer.** This is the surface most worth watching but probably not the next thing we ship. If we ever do build voice-driven Command Mode (mentioned in the historical wisprflow-deep-dive doc and partially echoed by Agent Mode vision), Transforms is the natural prerequisite — but speak-to-rewrite-selection is a much higher-leverage version of the same primitive than hotkey-to-rewrite-selection.

---

## Cross-cutting observations

### Local-first vs cloud LLM-dependent

Style, Auto Cleanup Medium/High, and Transforms all assume a fast cloud LLM. WisprFlow defaults users into cloud — they're a $12-15/mo subscription with their own GPT-4-class pipeline behind it.

Our current architecture (per ADR-002 amendment + ADR-011) is local-first with **opt-in** cloud LLM providers. That means every feature that depends on the LLM has to either:
- Degrade gracefully when the user hasn't configured a provider (just show the deterministic level), or
- Push users to configure a provider as part of onboarding the feature.

This isn't a blocker but it shapes every shipping decision. The local-first commitment is a real product asset (privacy, no subscription, offline-capable) — features that erode it should clear a high bar.

### Solo vs team

Every WisprFlow page shows All / Personal / Shared with team tabs. We are a solo app. We have no business case for team features and the existing competitive set above us (Granola for meetings, Notion AI for writing) owns that lane. The Shared tabs are noise for our roadmap; ignore.

### Hotkey discoverability

WisprFlow leans hard on Opt+number bindings, with the hotkey shown inline on every transform card. This is a UI pattern worth studying even if we don't ship Transforms — it works because the hotkey is the primary affordance, not a hidden shortcut. If we ever build a multi-hotkey surface (e.g., separate hotkeys for dictation modes or for transforms), the WisprFlow visual treatment is a good reference.

### What WisprFlow doesn't have that we do

- Local file/video transcription (Drop a file, get a transcript, free).
- YouTube transcription.
- Meeting recording (ScreenCaptureKit + mic dual-stream).
- Live meeting Notes/Transcript/Ask three-tab panel.
- Multi-language local STT via WhisperKit (KO/JA/ZH coverage).
- A real CLI (`macparakeet-cli`) for scripting and downstream agents.
- 100% local default. Free. Open source.

The audit above is "what could we steal from them" — but their feature set is also conspicuously narrower than ours in the dimensions that matter for our positioning.

---

## Prioritized next moves (post-decision)

Ranked after the 2026-05-11 decisions above:

| # | Move | Cost | Fit |
|---|---|---|---|
| 1 | **Transforms (Opt+N → rewrite selection in any app)** — full design in `transforms-design-2026-05.md`. Foundation for already-planned voice Command Mode. | Large | High |
| 2 | **Undo AI edit** — per-row affordance in dictation history to restore `rawTranscript` over `cleanTranscript`. Schema already stores both; pure UI. | Trivial | High |
| 3 | Dictionary modal toggle: `Correct a misspelling` framing. | Trivial | High |
| 4 | Decide on `.learned` source case: wire up auto-learning from corrections, or remove the dead enum case. | Small-Medium (if shipping) | High if shipped |
| 5 | Promote Snippets / Custom Words to top-level sidebar items in the next IA overhaul. | Small (UI only) | Medium |

**Explicitly deferred / declined:**

- Auto Cleanup gradations (None/Light/Medium/High) — declined 2026-05-11. Current binary raw/clean + optional AI Formatter is the chosen shape.
- Full Style page (per-app tabs with presets) — deferred. Tension with local-first; high maintenance overhead. The `{{contextApp}}` template-variable approach captures the 80/20 if we ever want it.
- "Shared with team" surfaces in Dictionary/Snippets — out of scope (solo app).
