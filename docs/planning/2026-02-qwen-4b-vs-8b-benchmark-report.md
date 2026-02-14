# Qwen 4B vs 8B Benchmark Report (Local + External Alignment)

Last updated: 2026-02-13
Owner: Core

## Scope

- Local models tested:
  - `mlx-community/Qwen3-4B-4bit`
  - `mlx-community/Qwen3-8B-4bit`
- Runtime: release `macparakeet-cli` via MLX-Swift-LM
- Machine:
  - Apple M4 Pro
  - 48 GB RAM
  - macOS 26.2 (25C56)
- Test goals:
  - Measure practical latency and memory in app-relevant workloads.
  - Score strict quality behavior (format/factual/constraint compliance).
  - Compare with official/public benchmarks.

## Reproducibility

- Perf harness: `scripts/dev/benchmark_qwen_models.sh`
- Quality harness: `scripts/dev/quality_eval_qwen.sh`
- Main perf raw file:
  - `output/benchmarks/qwen-model-benchmark-20260213-232540.tsv`
- Main perf summary:
  - `output/benchmarks/qwen-model-benchmark-20260213-232540-summary.tsv`
- Main quality file:
  - `output/benchmarks/qwen-quality-eval-20260213-233719.tsv`

## Local Perf Results

### Aggregate (40 runs total, 20/model)

| Model | Avg CLI gen time | Avg wall time | Avg peak memory |
|---|---:|---:|---:|
| Qwen3-4B-4bit | 2.932s | 5.995s | 2.90 GB |
| Qwen3-8B-4bit | 5.207s | 8.405s | 5.03 GB |

### By scenario (avg CLI generation time)

| Scenario | 4B | 8B | 8B slowdown |
|---|---:|---:|---:|
| refine-short | 1.078s | 2.168s | 2.01x |
| refine-long | 3.358s | 6.324s | 1.88x |
| command | 4.576s | 7.204s | 1.57x |
| transcript-qa | 2.718s | 5.130s | 1.89x |

### Cold vs warm note

- In this CLI harness, each invocation is a separate process, so "warm" here is mostly OS/cache warmth, not true in-process warm state.
- Observed cold vs warm differences were small in this setup.

## Strict Quality Results

Quality suite used 8 deterministic checks per model:
- factual extraction (decision triples)
- hallucination resistance (exact unknown-date response)
- wrapper/chatter suppression in formal refine
- strict JSON compliance
- hard word-count constraint
- structured bullet/owner output
- terse response constraint
- fact preservation in transform

### Pass rates

| Model | Passed | Total | Pass rate |
|---|---:|---:|---:|
| Qwen3-4B-4bit | 5 | 8 | 62.5% |
| Qwen3-8B-4bit | 6 | 8 | 75.0% |

### Notable failures

- 4B hallucination on unknown-date test:
  - Returned "Thursday end of day" as if calendar date.
- 4B and 8B failed exact 12-word constraint (both produced 9-word output).
- 4B and 8B injected wrapper formatting in formal-refine (`Subject:`, salutations, or similar).

Implication:
- 8B is materially better on strict factual compliance.
- Both models need prompt/runtime guardrails for exact formatting constraints.

## External Benchmark Alignment

### Official Qwen3 technical report (base models)

Source: Qwen3 technical report table snapshots (`Qwen3-4B` vs `Qwen3-8B` base).

- MMLU-Pro:
  - 4B: 50.58
  - 8B: 56.73
- SuperGPQA:
  - 4B: 28.43
  - 8B: 31.64
- GPQA:
  - 4B: 36.87
  - 8B: 44.44

Interpretation:
- Official benchmarks show 8B > 4B on reasoning/knowledge-heavy tasks.
- This matches local quality results (8B higher strict pass rate) at the expected latency/memory cost.

### Official Qwen3-4B-Instruct-2507 update

Source: `Qwen/Qwen3-4B-Instruct-2507` model card benchmark table.

Examples (4B non-thinking -> 4B-Instruct-2507):
- MMLU-Pro: 58.0 -> 69.6
- GPQA: 41.7 -> 62.0
- AIME25: 19.1 -> 47.4
- LiveBench: 48.4 -> 63.0
- Arena-Hard v2: 9.5 -> 43.4

Interpretation:
- Official numbers suggest major upside from newer `-2507` variants.
- Current local benchmark tested older `mlx-community/*-4bit` baselines, so next pass should include `-2507` model IDs for an apples-to-apples update decision.

## Benchmark Methodology Upgrades (Paper-Informed)

The following are directly motivated by published eval work:

1. Multi-metric evaluation over single-score ranking.
   - Inspired by HELM: evaluate accuracy + robustness + efficiency + safety dimensions.
2. Human-calibrated open-ended quality checks.
   - Inspired by MT-Bench/Chatbot Arena: automated judging is useful but should be calibrated to human preference.
3. Length/style bias controls in auto-eval.
   - Inspired by Length-Controlled AlpacaEval.
4. Anti-gaming tests.
   - Inspired by "Cheating Automatic LLM Benchmarks": include null/adversarial probes to detect benchmark overfitting.
5. Reproducibility hygiene.
   - Inspired by "Lessons from the Trenches": fixed prompts, fixed seeds where possible, pinned runtime/model versions, and tracked raw artifacts.

## Honest Assessment

- If priority is responsiveness and memory headroom: 4B remains attractive.
- If priority is instruction reliability/factual control in transforms and transcript QA: 8B is clearly safer.
- Current prompts are not hardened enough for strict formatting and "no-wrapper" behavior in either model.
- Biggest near-term opportunity is not just 4B vs 8B; it is evaluating newer `-2507` variants under the same harness.

## Final Recommendations

1. Keep 8B as quality-first default for command mode and transcript QA.
2. Keep 4B as a fallback/low-memory profile for fast refinement.
3. Run the exact same harness on `Qwen3-4B-Instruct-2507` and `Qwen3-8B-Instruct-2507` (MLX variants) before locking long-term defaults.
4. Add a hardening pass to prompts/post-processing:
   - enforce no-wrapper output mode
   - enforce exact format outputs (JSON/word-count) with validator + retry
   - add hallucination guard prompts for "unknown/not present" extraction

## Sources

- Qwen3 technical report (arXiv): https://arxiv.org/abs/2505.09388
- Qwen3 technical report (HTML mirror with tables): https://ar5iv.org/html/2505.09388
- Qwen3-4B-Instruct-2507 model card: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507
- HELM paper: https://arxiv.org/abs/2211.09110
- MT-Bench / Chatbot Arena paper: https://arxiv.org/abs/2306.05685
- Length-Controlled AlpacaEval: https://arxiv.org/abs/2404.04475
- Cheating Automatic LLM Benchmarks: https://arxiv.org/abs/2410.07137
- Lessons from the Trenches on reproducible evaluation: https://arxiv.org/abs/2405.14782
