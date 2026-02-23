# LLM Runtime Risk Register (Qwen3-8B + MLX-Swift-LM)

> Status: **HISTORICAL** - LLM support (Qwen3-8B / MLX-Swift) removed 2026-02-23.

Last updated: 2026-02-13

## Risk Matrix

| ID | Risk | Likelihood | Impact | Mitigation | Owner |
|----|------|------------|--------|------------|-------|
| R1 | MLX/MLX-Swift-LM compatibility regression | Medium | High | Pin versions, run local parity + CI checks before upgrades | Core |
| R2 | Memory pressure on 8 GB devices | Medium | High | Lazy load, idle unload, bounded context, fallback on failure | Core |
| R3 | First-use latency feels slow | High | Medium | Explicit loading indicator, prewarm option, prompt sizing discipline | UX/Core |
| R4 | Prompt regressions reduce output quality | Medium | Medium | Prompt snapshot tests + benchmark quality rubric | Core |
| R5 | Silent failure causes user confusion | Low | High | Mandatory fallback + user-safe notice + structured logs | Core |
| R6 | Upstream model revision drift | Medium | Medium | Lock model ID, controlled revalidation cadence | Core |
| R7 | Scope creep (multi-model complexity too early) | Medium | Medium | Enforce ADR-008 single-model baseline for v0.2/v0.3 | Product/Core |
| R8 | Transcript chat context overflow | Medium | Medium | Chunking/truncation policy and explicit context limits | Core |

## Trigger Conditions

Escalate to revalidation if any of the following occur:

1. Two consecutive benchmark cycles show material quality/perf regression.
2. Runtime upgrade causes repeated CI or local instability.
3. User-visible OOM/pressure events on target hardware class.

## Contingency Paths

1. Keep deterministic-only mode fully functional as a safe baseline.
2. Temporarily disable AI modes via feature flag if runtime becomes unstable.
3. Evaluate fallback model tier (4B class) only if 8B baseline becomes untenable on supported hardware.
