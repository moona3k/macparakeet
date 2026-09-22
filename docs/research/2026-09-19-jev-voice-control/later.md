# Later

Ship the silent, native loop first. Nothing below is required to keep unique local tools working.

## Still open on this experiment

- One live native Flights search through to a results list
- Integrated hold-to-talk microphone path, with dictation / Transform regression
- The open-ended request on generic pages is `kind` / `target` / focused `value`; a generic footer link is still not a landing. Region hints (`top-left`) in `target` criteria wait for frames on the wire
- Spoken-tool presses that return Accessibility “unknown” still pause. Completing them needs a compilation origin so plan-driven presses keep pausing
- Join-space for `type` assumes the caret is at the end of the field value

## Next tools

- Numbered **on-screen** overlays (Apple “show numbers”). The panel list already ships
- Named references (`mark as inbox`, then `click inbox`)
- `File > Export` and other menu paths
- Container-scoped scrolling (“a little more”, “to the bottom”)
- One named missing-slot question (“Need a destination”)
- Semantic freshness guards and loop-breaking on (action, screen signature), excluding clocks

## Observability, perception, decision shape, second source

Plan: `plans/active/2026-09-20-voice-control-observability-perception-decision.md`; background review under `docs/research/2026-09-20-typesafe-computer-use/`. Done: every Jev probability in the log, replayable observations, `voice-control replay`, inbox dry run, per-stage timing. Done as well: `AXTreeWalk` as a pure function over an injectable tree with off-screen pressables; on-device screen text (`ScreenTextReading`) as a second source of targets and state, opt-in. Next: region hints in `target` criteria; Flights predicates behind a domain provider; ScreenCaptureKit in place of the deprecated capture call; default-on for screen text once the replay corpus shows its effect on clarify rate.
