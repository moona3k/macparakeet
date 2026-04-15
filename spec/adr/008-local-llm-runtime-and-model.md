# ADR-008: Local LLM Runtime and Model Baseline (Qwen3-8B)

> Status: **HISTORICAL** - Superseded. The on-device Qwen3-8B / mlx-swift-lm runtime was removed 2026-02-23. Current LLM support uses external providers or local CLI instead.
> Date: 2026-02-13

## Context

MacParakeet has committed to fully local AI execution (ADR-002) and has already migrated STT to FluidAudio on ANE (ADR-007). The remaining AI roadmap items depend on a local text LLM:

- AI text refinement modes (Formal, Email, Code)
- Command mode text transforms
- Future "chat with transcript"

We need one production baseline that is fast enough, reliable in native Swift, and simple to operate on Apple Silicon without Python daemons.

## Decision

MacParakeet will use:

- **Runtime:** `mlx-swift-lm` (in-process, native Swift)
- **Model:** **Qwen3-8B 4-bit** (`mlx-community/Qwen3-8B-4bit`)
- **Deployment shape:** single-model baseline for all LLM features in v0.2/v0.3

### Locked decisions

1. No Python or external daemon for LLM runtime.
2. No multi-model routing in initial rollout.
3. Deterministic pipeline remains first stage for all text cleanup flows.
4. If LLM call fails/times out, app degrades gracefully (returns deterministic-clean output and surfaces non-blocking UI notice).

## Rationale

1. **Native integration fit:** `mlx-swift-lm` is the strongest direct fit for a Swift macOS app.
2. **Operational simplicity:** single model lowers complexity for prompts, memory behavior, and QA.
3. **Capability coverage:** Qwen3-8B quality is sufficient for cleanup + command transforms + transcript chat baseline.
4. **Architecture coherence:** STT on ANE (FluidAudio) + LLM on GPU (MLX) uses Apple Silicon efficiently.
5. **License/distribution fit:** avoids Python runtime packaging and daemon lifecycle risks.

## Consequences

### Positive

- One coherent local AI stack (Swift + SwiftPM + CoreML/MLX).
- Clear implementation path for pending v0.2/v0.3 LLM features.
- Predictable prompt behavior with a single baseline model.

### Tradeoffs

- Higher memory footprint than 4B-class models.
- Initial model load latency is user-visible on first LLM invocation.
- Upstream MLX/MLX-Swift-LM compatibility regressions remain a real risk and require pinning + validation.

## Guardrails

1. Version pinning and controlled upgrades for `mlx-swift-lm`.
2. CI + local parity check for toolchain/runtime stability.
3. Runtime revalidation cadence in `docs/runtime-revalidation-checklist.md`.
4. Dedicated benchmark protocol (informational, not release-blocking) in `docs/planning/2026-02-qwen3-8b-benchmark-plan.md`.

## Alternatives Considered

### Qwen3-4B

Rejected as baseline because 8B is preferred for output quality and future transcript-chat utility. 4B remains a fallback option only if memory pressure proves unacceptable on target devices.

### llama.cpp / Ollama runtime

Rejected for baseline due to higher integration/operations complexity in a native Swift app compared with direct MLX-Swift embedding.

### Cloud API LLM

Rejected due to local-only product direction and privacy commitments (ADR-002).

## References

- `docs/research/open-source-models-landscape-2026.md`
- `docs/runtime-revalidation-checklist.md`
- `spec/07-text-processing.md`
- `spec/adr/002-local-only.md`
- `spec/adr/007-fluidaudio-coreml-migration.md`
