# Qwen3-8B Integration Checklist (Execution Order)

Status: In Progress
Owner: Core app team
Updated: 2026-02-13

## Objective

Ship production-ready local LLM integration for refinement + command mode using Qwen3-8B with robust fallback behavior.

## PR Slice Plan

1. **Foundation seam**
- Add `LLMServiceProtocol`, request/response models, and error taxonomy.
- Add no-op/mock implementation for tests.
- Wire dependency injection in call sites.

2. **Fallback-safe wiring**
- Integrate deterministic-first -> LLM-second flow for formal/email/code.
- Implement timeout + empty-output guards.
- Ensure fallback returns deterministic-safe output.

3. **Qwen runtime integration**
- Add `MLXQwenService` implementation for `mlx-swift-lm`.
- Implement lazy load + idle unload lifecycle.
- Add model availability and load-state handling.

4. **Command mode integration**
- Route selected text + spoken command through shared LLM seam.
- Preserve current selection-replace UX behavior and error paths.

5. **Transcript chat baseline**
- Add transcript context assembly utilities (bounded chunking/truncation).
- Ship CLI chat request pathway (`macparakeet-cli llm chat`) while GUI remains pending.

6. **Benchmark + hardening**
- Run benchmark protocol in `docs/planning/2026-02-qwen3-8b-benchmark-plan.md`.
- Tune prompt templates and timeout budgets.
- Fix memory/lifecycle edge cases discovered in test runs.

## Progress Snapshot (2026-02-13)

1. Completed: foundation seam + fallback-safe wiring (`TextRefinementService`, deterministic fallback, tests).
2. Completed: Qwen runtime integration with lazy load and idle unload in `MLXLLMService`.
3. Completed: dictation/transcription context modes (`raw`, `clean`, `formal`, `email`, `code`) wired through app + CLI.
4. Completed: transcript chat CLI baseline via `macparakeet-cli llm chat` with bounded context assembly utility.
5. Remaining: command mode GUI flow (selection capture and in-place replace UX).
6. Remaining: benchmark run execution/tuning pass on target hardware matrix.

## Tests Required per Slice

1. Unit: prompt and fallback behavior.
2. Unit: service lifecycle (load, warm invoke, unload).
3. Integration: dictation AI mode path with mock LLM.
4. Integration: command mode transform path with mock LLM.
5. Regression: deterministic mode unchanged.

## Exit Criteria

1. `swift test` green.
2. AI modes produce valid transformed output with Qwen3-8B.
3. LLM failure path is graceful and non-blocking.
4. No Python/runtime-daemon dependency added.

## Deferred (Explicitly Out of Scope)

1. Multi-model runtime routing.
2. Automatic model switching by hardware class.
3. Long-context retrieval pipeline beyond bounded transcript chunking.
