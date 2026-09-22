# Voice Control: observable, testable, lean, and better-sighted

**Status:** IMPLEMENTED; measurement follow-ups open. **Date:** 2026-09-20, updated 2026-09-21. **Owner:** MacParakeet core.
**Background:** [source review of a comparable System One computer-use loop](../../docs/research/2026-09-20-typesafe-computer-use/README.md) and the [developer walkthrough](../../docs/research/2026-09-20-typesafe-computer-use/walkthrough.html) of how Jev, the action space and the host loop fit together.
**Governing decisions:** [ADR-033](../../spec/adr/033-explicit-voice-control.md), [contract](../../spec/contracts/voice-control.md). Owner decisions 2026-09-20: all seven walkthrough recommendations accepted, including on-device OCR as a second source of targets and state.

## Doctrine that does not move

Code observes, lists legal events, executes and verifies. Jev chooses among options code built, only when several are enabled. Authority is revocable; effects are consumed once; uncertain effects are never replayed; pay/delete/send confirm; speech, pixels and field values stay on the Mac. Nothing below changes this.

## Four designs

Each is its own PR based on the Voice Control branch (retargeted to `main` once #1104 merges), independently reviewable and measurable on saved snapshots. Order is by leverage: observability makes every later change measurable offline.

| # | Design | Contract it adds | Verifies |
|---|---|---|---|
| A (#1107, merged) | **Every decision is inspectable and replayable.** | `VoiceControlDecisionTrace` (per head: choice, confidence, full distribution; opaque keys only). `VoiceControlPersistedObservation.snapshot()` rebuilds a replayable snapshot (values absent). `voice-control replay` runs router + engine offline. `submit(dryRun:)` reports the compiled action without executing. Per-stage timing in the turn summary. | `VoiceControlObservabilityTests`, `VoiceControlCommandTests`; shareable diagnostics shape unchanged |
| B (#1108, merged) | **Perception is a pure function over an injectable tree.** | `AXTreeWalk.run(roots, source: AXTreeSource, display, window, focused, caps) -> AXWalkResult` with eight documented pruning rules. Expensive attributes read only for kept candidates. `VoiceControlTarget.isOffscreen` for labelled pressables the app hides: exact-name only, never offered to Jev. | `AXTreeWalkTests` (fake trees); focused suites; observe time in the timing line |
| C (#1109, merged) | **The open-ended decision is one small, disjoint question set.** | Heads `kind` / `target` / `value` (focused field only) / `consequence` (advisory) / `direction`; gate `min(kind, target)`; a second `value` request only when filling an unfocused field; prioritised truncation instead of `contextTooLarge`; `SpokenDateParser` with `dated … (in N days)` hints. One `send(_:questions:)`. | Replay corpus: payload bytes, latency, invalid/too-large rate, clarify rate |
| D (#1110, merged) | **The Mac is observed through two sources.** | `ScreenTextReading` / `VisionScreenTextReader` (on-device Vision over the frontmost window, unchanged-frame skip, own windows excluded, concurrent with the walk under its own 1.2 s budget) merged with AX by box overlap + text match via `ScreenTextMerge`; `role: "text"` targets with pixel-click fallback and `unknown`-unless-transition receipts; window text into the snapshot `summary`; secure-frame and secure-word redaction; glyph-only blocks dropped; ADR-033 observation amendment; per-user opt-in (`voiceControl.screenText.v1`). | Terminal/Spotify fixture yields targets AX lacks; Flights results fixture shows prices/dates in `summary`; no image persisted; shareable diagnostics unchanged |

## Invariants to test in every PR

- No audio, screenshot, field value, credential or remote body in any trace or fixture.
- Copy diagnostics output keeps its shape (labels and instruction still stripped).
- `swift test --filter 'VoiceControl|DictationFlowCoordinator|TransformRunSerializer'` green; full suite once before each PR is marked ready.

## Measured (2026-09-20, dev build with all four)

- Observe: Chrome 158 controls / 844 ms complete; Notes 87 / 620 ms; Finder list view 41 (AX only) / 2.1 s capped. Fixed on the way: nameless-container de-duplication pruning web subtrees; the panel's own text becoming screen-text targets; a Gmail row with a comma classifying as a city picker (#1111).
- Request shape (12 observations × 4 goals, live Jev): `contextTooLarge` 8 → 0, heads max 26 → 5, max payload 47 KB → 33 KB, latency flat (~297 ms median).

## Also merged

- #1111: a picker needs `Where else?` overlay chrome, not a comma (took the known-target corpus from 15 to 20 of 24).
- #1112: nine-cell region hints in `target` criteria and on the wire.

## Open

- Finder-class dense list views still exceed the 2 s Accessibility budget; measure with the `walk:` line after batched reads, then tune caps or prune list bodies.
- Decision-quality corpus: 24 known-target goals scored 9 → 15 → 20 (old → #1109 → +#1111); re-run on fresh sessions with region hints.
- Flights predicates (`isCitySuggestion`, `isCalendarDay`, `Where else?`) behind a domain provider before a second site.
- Router if-chain → `VoiceControlLocalTools` table.
- ScreenCaptureKit in place of the deprecated `CGWindowListCreateImage`; tile-level re-OCR.
- Live Flights through to results; hold-to-talk microphone path.

## Recorded follow-ups

Off-screen presses: exact-name local commands only, receipts postcondition-only, not offered to Tier-3 Jev initially. OCR wire volume: same consent as AX labels, measured on the replay corpus before default-on.
