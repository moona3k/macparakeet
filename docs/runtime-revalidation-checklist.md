# Runtime Revalidation Checklist (macOS Local LLM)

> Status: **HISTORICAL** - The on-device Qwen3-8B / MLX-Swift runtime documented here was removed 2026-02-23. Current LLM support uses external providers or local CLI instead.

Last updated: 2026-02-13

## Goal
Keep local LLM runtime selection evidence-based over time (not one-time).

Current baseline:
- Primary runtime: MLX-Swift / MLX-Swift-LM
- Model class: Qwen3-8B 4-bit
- Platform: Apple Silicon macOS app (native Swift)

## Cadence
- Monthly (light): release/issue scan + blocker check.
- Quarterly (deep): benchmark + integration scorecard.
- Immediate re-run when a critical regression or major upstream release appears.

## Monthly Light Review
1. Check latest releases:
   - `ml-explore/mlx-swift-lm`
   - `ml-explore/mlx-swift`
   - `ggml-org/llama.cpp`
   - `ollama/ollama`
2. Check open blocker-class issues affecting Swift/macOS toolchains.
3. Confirm current pinned versions still build in CI and locally.
4. Record one-line conclusion:
   - `stay on current`
   - `pilot alternative`
   - `schedule migration proposal`

## Quarterly Deep Review (Scorecard)
Evaluate each candidate runtime (MLX-Swift, embedded llama.cpp, daemon options) across:

1. Performance
- First token latency (cold and warm)
- Tokens/sec (steady-state)
- End-to-end user-perceived latency in app flows

2. Resource use
- Working memory footprint
- Memory pressure behavior on 8 GB devices
- Thermal/throttling behavior over sustained use

3. Reliability
- CI/build stability across current Xcode toolchain
- Runtime crash/error rates
- Upgrade regressions over last 2 release cycles

4. Integration complexity
- Native Swift embedding quality
- Packaging and signing complexity
- Distribution risk (App Store / notarization constraints)

5. Operational fit
- Ability to run fully on-device without external daemon
- Observability/debuggability in production app context

## Reconsideration Triggers
Start a migration RFC/ADR update if any candidate shows:
- >= 25% better end-to-end latency on target workloads, or
- materially lower memory pressure on 8 GB Macs, or
- clearly better reliability (fewer blocker regressions), or
- significantly simpler distribution/security posture.

## Decision Heuristic
Default to staying on MLX-Swift unless an alternative is better on at least two high-priority dimensions:
- user-perceived latency,
- reliability/upgrade safety,
- integration/distribution complexity.

## Current Practical Stance
- MLX-Swift is a solid production choice for current app constraints.
- A "FluidAudio-like" shift is possible in future for local text LLM runtimes, so periodic revalidation is required.
