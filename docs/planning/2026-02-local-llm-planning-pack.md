# Local LLM Planning Pack (Qwen3-8B)

> Status: **HISTORICAL** - The on-device Qwen3-8B / MLX-Swift plan documented here was removed 2026-02-23. Current LLM support uses external providers or local CLI instead.

Last updated: 2026-02-13
Scope: Production planning for local LLM integration in MacParakeet.

## Included Artifacts

1. Decision record: `spec/adr/008-local-llm-runtime-and-model.md`
2. Integration spec: `spec/11-llm-integration.md`
3. Benchmark protocol: `docs/planning/2026-02-qwen3-8b-benchmark-plan.md`
4. Execution checklist: `plans/active/2026-02-qwen3-8b-implementation-checklist.md`
5. Risk register: `docs/planning/llm-runtime-risk-register.md`
6. 4B vs 8B benchmark report: `docs/planning/2026-02-qwen-4b-vs-8b-benchmark-report.md`

## What This Enables

1. A single, locked baseline for implementation (`mlx-swift-lm` + Qwen3-8B).
2. Ordered PR slices for shipping without architecture churn.
3. Repeatable quality/performance evaluation with practical metrics.
4. Explicit risk ownership and mitigation before implementation pressure rises.

## Notes

- This pack aligns with local-only constraints and existing ADRs.
- Benchmark metrics are intentionally informational, not hard release gates.
- If upstream runtime conditions materially change, re-run the runtime revalidation checklist:
  - `docs/runtime-revalidation-checklist.md`
