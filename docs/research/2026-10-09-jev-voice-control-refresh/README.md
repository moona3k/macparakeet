# Voice Control and Jev: refresh, 2026-10-09

Follows the [2026-09-19 research folder](../2026-09-19-jev-voice-control/README.md)
and the [2026-09-25 deep review](../2026-09-25-voice-control-jev-deep-review.md).
Voice Control is still a DEBUG experiment behind `--enable-voice-control`.

## Read in this order

1. [Evaluation](evaluation.md): what was measured against live Jev and what
   shipped because of it.
2. [Code review](code-review.md): 28 findings, each reproduced by a probe test
   or read from code. Line numbers refer to `edc5df07a`.
3. [Ecosystem](ecosystem.md): about 300 new Jev repos since 2026-09-15 and the
   patterns worth borrowing.
4. [Landscape](landscape.md): vendor and open-source computer use on macOS,
   UX patterns, benchmarks.

## What changed in code

| Area | Change | Evidence |
|---|---|---|
| Jev wire | Ordered options, byte-identical requests, each control described once with `null` criteria, Chromium text twins dropped | Evaluation findings 1–2 |
| Jev decisions | `scope` head ends a confident single action without a second call; split targets become numbered picks; `finished` gated at 0.6 with a literal criterion; punctuation variants of a value share support | Findings 3–4, `JevRequestShapeTests` |
| Jev errors | Stop pauses instead of "Jev is unavailable"; key rejected and token limit named; 8 s attempt timeout; connection warmed at key-down | Live error probes, tests |
| Routing | Mid-sentence `type`, app-name containment, suffix stripping, noun keyword floor fixed; newest command of an amended goal routes locally; scroll picks the focused or largest area | Code review H3, H4, M8, M9, M15 |
| Conversation | One utterance classifier: a command during a clarification starts a new task; a finished task is never revised; a dry run's question opens no conversation | Code review H5, H6; live dry runs |
| UX | The panel names the effect, shows what was heard and a state label, lists pick choices as clickable numbered rows; an overlay outlines the target, holds an outline during confirmation and badges pick choices | Code review M11, landscape ideas 1–2 |
| Adapter | Clocks and counters are not transition evidence; opening a site polls for the retitle instead of sleeping 1.8 s; hands-free clicks do not discard speech | Code review L1, M5, H7 |

## Still open, ranked

1. Live qualification on a quiet desktop: microphone to verified effect, p50 and
   p95 latency, wrong-target rate, overlay placement on multiple displays.
2. Observation cost: three full walks per spoken command and the unbatched
   candidate pass (code review M4, M6, M7). Reuse the invocation snapshot or start
   the runner's observation at key-up.
3. "Already tried on this screen" as Jev state, and loop detection over (action,
   screen signature) (ecosystem ideas 2–3).
4. Stable fingerprint target ids instead of walk positions.
5. A Jev `route` head in place of the remaining substring routes, measured on the
   replay corpus with `scripts/dev/voice_control_jev_eval.py`.
6. Expose observe, act and verify to the user's own agent (CLI or MCP), per the
   ADR-027 north star, instead of growing a planner in core.
