# Lessons from prior computer-use systems

Local checkouts under `macparakeet/references/` (gitignored) informed this design. None of them were executed as part of Voice Control. Ideas transfer; transports do not. Native Accessibility remains the only adapter.

## The loop that works

Observe → choose → act → verify, with verification as a **postcondition of the operation**, not “the screen changed.” Snapshot ids are per-observation; identity is re-derived (handle, then unique role+label). Chromium webpage controls need `AXManualAccessibility` + `AXEnhancedUserInterface` once per process, then a wait for a populated web area. Arithmetic, dates, counts, URLs, and literal payloads stay local. Fail open: no key, timeout, malformed answer → ask or stop, never guess, never take the first candidate.

Web content is a region of the Accessibility tree, not a separate world. Prefer page controls over browser chrome unless the goal is about tabs. Code owns destinations. Don’t refill a field that already holds the text. Don’t treat a populated field as an applied search.

## Interaction

Closed-set commands may commit early; free-text payloads wait for a final transcript so “search for alan” is not “search for alan turing.” Numbered disambiguation is local. Ask the one missing slot by name. Correction is a distinct route from a new command. Truthful endings are a feature: “already satisfied”, “result unconfirmed”, “stopped at the budget.” Barge-in and user takeover are the same reflex.

## What we took, briefly

| Source | Keep | Leave |
|---|---|---|
| Apple Voice Control, Rango | Say the number; named targets | On-screen overlays (later); browser-extension hints |
| third-hand, jev-use | AX walk, rematch, skip-if-satisfied, Chromium handshake | CDP attach, OCR, OpenRouter planners |
| jev-ultrafast | Consume-once, semantic freshness, strict Choice validation | CDP, generating field values from page text |
| jev-voice-browser | Two-gate speech, local numbered picks | Playwright, Web Speech (cloud), confirm-on-submit |
| macbrow | Slot-completeness, span candidates, “code owns the workflow” | Generated AppleScript, cloud STT, confirm-on-save |
| OpenJarvis | Local-first, capability floor the model cannot lower, AX as text | Playwright, CodeAct |
| Hobby Jarvis demos | Numbered “which one”, show what was heard | Wake words, keyword soup, cloud STT, unconfirmed shutdown |
| blind.sh / VoiceCraft / Skales | Confirm the compiled effect; isolated typing mode; default-No | LLM→script, pixel mouse, eleven-place HUDs |
| Jevbridge, tiptour | Named gate with reasons; exact-id grounding | `visible[0]` fallback; vision as primary grounder |

## Use-case tiers

**Must feel magic:** open an app by name; click a named control; Stop / “the other one” / takeover; search the web or YouTube; open Gmail; type verbatim into the focused field; numbered disambiguation; scroll.

**Flagship, after that:** play a YouTube result; Maps directions; Google Flights through to results; two clauses in one breath.

**Later:** named references, structural text editing, spoken rewrites through Transforms, TTS, cross-app send flows. On-device screen text now ships as an opt-in second observation source; tile-level re-OCR and ScreenCaptureKit remain later.

The everyday catalog is in [everyday-use-cases.md](everyday-use-cases.md). The route catalog is in [routing-catalog.md](routing-catalog.md).
