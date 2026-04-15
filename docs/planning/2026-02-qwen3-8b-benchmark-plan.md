# Qwen3-8B Benchmark Plan (macOS Local)

> Status: **HISTORICAL** - The on-device Qwen3-8B / MLX-Swift path documented here was removed 2026-02-23. Current LLM support uses external providers or local CLI instead.

Last updated: 2026-02-13
Purpose: Establish repeatable, practical measurements for local Qwen3-8B quality and performance in MacParakeet.

## Scope

This plan validates the production baseline:

- Runtime: `mlx-swift-lm`
- Model: `mlx-community/Qwen3-8B-4bit`
- Use cases: refinement, command transforms, transcript chat readiness

## Principles

1. Benchmarks are **decision support**, not hard release gates.
2. Prioritize user-perceived responsiveness and output quality over synthetic max throughput.
3. Keep runs reproducible and scriptable.

## Test Matrix

| Dimension | Values |
|-----------|--------|
| Hardware class | 8 GB, 16 GB, 32 GB Apple Silicon |
| Thermal state | cold start, warmed session |
| Prompt type | refinement, command transform, transcript QA |
| Input length | short, medium, long |

## Workloads

1. Refinement short: 40-80 words from dictation.
2. Refinement long: 300-600 words.
3. Command transforms: rewrite, summarize, translate, formalize.
4. Transcript QA: 5-10 minute transcript chunk, factual question answering.

## Metrics

1. Time-to-first-token (cold/warm).
2. End-to-end completion time.
3. Tokens/sec during generation.
4. Peak memory footprint and memory pressure events.
5. Output quality rubric (instruction adherence, factuality, formatting correctness).

## Suggested Informational Targets

These are guidance targets for internal quality tracking only:

- No app hang/crash under repeated invocations.
- Warm-path refinement feels interactive to user.
- Output passes manual quality check in >= 90% of sampled prompts.

## Run Procedure

1. Run deterministic baseline (no LLM) for control references.
2. Run Qwen3-8B benchmarks in cold and warm conditions.
3. Record results in a single markdown table per machine.
4. Capture regressions versus last accepted run.

## Output Template

```md
## Machine
- Device:
- macOS:
- Xcode/Swift:

## Results
| Scenario | Cold TTFB | Warm TTFB | E2E | Peak Mem | Quality |
|----------|-----------|-----------|-----|----------|---------|
| refine-short | | | | | |
| refine-long  | | | | | |
| command      | | | | | |
| transcript-qa| | | | | |

## Notes
- Observed regressions:
- User-visible issues:
- Keep / tune / investigate:
```

## Decision Outcomes

After each benchmark cycle, classify:

1. `keep baseline` - no action.
2. `tune prompts/runtime` - minor optimization work.
3. `trigger runtime revalidation` - deeper alternative evaluation.
