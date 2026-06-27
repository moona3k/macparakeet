# On-Device Local LLM — Phase 0 Eval Design

Status: **PROPOSED** (research + eval design; no code)
Date: 2026-06-27
Companion to: [`2026-06-27-on-device-local-llm.md`](./2026-06-27-on-device-local-llm.md) §8 Phase 0
Issues: #439 (integrated local cleanup), relates #265, #550, #460, #563, #408

> The parent plan commits to a Phase 0 spike + evaluation gate. This doc is the
> execution detail for the **evaluation** half: what "good" means for on-device
> transcript cleanup, and how to measure it before any inference code ships. For
> an open-ended editing task there is no single ground truth, so defining the
> measurement *is* the hard part of Phase 0.
>
> Primary focus: **cleanup**. Summary and grounded-QA are covered second, with an
> evidence-backed argument that for those tasks the long-context *architecture*
> matters more than the model.

---

## 1. The reframe: cleanup is a constrained, near-subtractive edit

A good cleanup output is essentially the source transcript with filler,
disfluencies, false starts, and repetitions removed, punctuation/casing repaired
(Parakeet already emits punctuation+caps, so this is *repair*, not from-scratch
restoration), light grammar applied, and readable formatting added. The research
literature on transcript cleanup treats the ideal output as close to a *monotonic
subsequence* of the source — "additional deletion or rewriting constitutes a
structural error" (DRES 2025; MultiTurnCleanup 2023).

Hard constraints:

- MUST NOT change meaning or add information not in the source.
- MUST NOT drop substantive content (removing filler is expected and fine).
- MUST NOT alter names, numbers, dates, units, code, URLs, identifiers.
- SHOULD preserve the speaker's voice/register (don't formalize or rewrite).
- SHOULD NOT *execute* a dictated instruction (e.g. "write a PR description"
  stays as text, isn't carried out).

**Consequence for the eval:** the dominant failure mode is not leaving an "um"
behind — it is **over-editing** (hallucination, dropped content, changed
names/numbers, paraphrase). So the eval must be **asymmetric**: hard PASS/FAIL
**gates** on the "don't corrupt" properties, **graded** scores on the "cleaned
well" properties. A single blended 1–5 score is the wrong design — it averages a
corrupted number into a 4/5 and hides the failure that destroys user trust.

---

## 2. What Phase 0 must answer (go / no-go)

- **Q-QUALITY:** On a domain-matched gold set, does an on-device 4B-class model do
  cleanup that (a) passes the fidelity gates at a high rate and (b) is judged at
  least at parity with the current cloud-cleanup baseline and clearly above the
  deterministic no-LLM baseline?
- **Q-MODEL:** Which model + quant wins the cleanup bake-off?
- **Q-PREFILL:** Where does prefill latency cross the UX budget as input grows
  (1K → 64K tokens)? This sets the single-shot vs map-reduce threshold.
- **Q-RAM:** Peak RSS at 16K/64K context, fp16 KV vs `kvBits:4`, with Parakeet +
  diarizer resident (watch the concurrent-ANE SIGBUS path addressed by #614).
- **Q-STRUCT:** Without a grammar engine, what is the structured-output
  parse-success rate at our schema sizes? Is a custom logits processor worth it?
- **Q-LONGCTX:** Confirm long-context degradation on our transcripts to justify
  map-reduce + retrieval over "use a bigger model."

A "go" means: at least one model+quant clears the cleanup quality bar within the
latency/RAM budget on a mid-tier Mac, with a credible long-transcript path.

---

## 3. Metric stack for CLEANUP (primary task)

Cleanup is naturally chunkable (operate per-utterance / per-paragraph window),
which sidesteps the long-context problem and makes a 4B far more plausible here
than for summary/QA. Score it **precision-first**.

### Tier 1 — Deterministic safety gates (100% of outputs, no LLM, reproducible)
These are PASS/FAIL and carry the trust-critical KPIs; report them as **violation
rates**. Almost no prior cleanup tool evaluates at all, so this tier is the
differentiator.

- **Entity / number / date diff (blocking, un-gameable).** Extract from both
  source and output: numbers, dates, currencies, units, %, proper nouns (NER),
  code tokens, URLs, emails, file paths. Any source item missing or altered in
  output → dropped/corrupted; any output item not in source → hallucinated.
  Legitimate cleanup essentially never introduces a new number or named entity,
  so this is high-precision, deterministic, fast, API-free.
- **Bidirectional entailment (AlignScore / SummaC).** `source ⊨ output` failing =
  added/changed content; `output ⊨ source` failing = dropped content; contradiction
  either way = meaning change.
- **Content-word retention floor.** Fraction of source content words (minus a
  filler lexicon) that survive; catches gross content deletion that bidirectional
  NLI can rate as "neutral" (a pure deletion doesn't contradict the source, so
  entailment alone misses it).
- **Edit-distance / LCS ratio vs source.** High edit distance *with* entity
  changes = corruption; high *without* = aggressive-but-maybe-OK → route to judge.
- **Do-no-harm (unnecessary-edit) rate.** Feed already-clean text; measure how
  often the model changes anything. Direct guard against the documented LLM
  over-correction failure mode.

### Tier 2 — Reference-based quality (small gold set)
- **SARI** — decomposes into keep / delete / add; uniquely matched to cleanup
  (rewards deleting fillers + keeping real words, penalizes unjustified additions).
  Best single "edited the right things" number.
- **ERRANT-style edit precision + F0.5** on gold edits — precision weighted 2×
  recall so over-correction is punished harder than a missed filler. Report the
  error-type breakdown. (Methodology import; do **not** report CoNLL/BEA
  leaderboard numbers as if they describe our task — those are written-learner
  English with a large domain gap.)
- **Disfluency-removal token-F1** on a disfluency-annotated slice — the legible
  "removed ums, kept real words" number. Report the **disfluent-class F1 only**,
  never accuracy (a do-nothing model scores ~94% token accuracy because
  disfluencies are ~6% of tokens).
- *Optional:* FER/DER (Fluent/Disfluent Error Rate) — the right primitives because
  plain WER penalizes correct filler removal.

### Tier 3 — LLM-as-judge rubric (holistic, calibrated, secondary)
Catches what Tiers 1–2 miss (paragraphing, list formatting, flow, voice). See §4.

**Aggregation:** `valid = (all Tier-1 gates pass)`; `quality = mean(graded dims)`
over valid items only. **Headline two numbers, reported separately and per
length/difficulty stratum: gate pass-rate AND mean quality among passers — never
blend them.** A model that scores high on SARI/F0.5 but trips the entity/number or
entailment gate fails, full stop.

---

## 4. LLM-as-judge protocol

- **Method:** source-grounded **absolute rubric scoring** (G-Eval form-filling +
  chain-of-thought eval steps) as the workhorse — the source transcript *is* the
  reference, so this is reference-guided, which beats reference-free. **Pairwise +
  swap** is reserved for model-vs-model release gates (local vN vs vN+1, or local
  vs cloud), length-controlled. Pointwise preferences are far more stable than
  pairwise (flip ~9% vs ~35%) and resist distractor-gaming.
- **Judge model:** a strong cloud model from a **different family than the model
  under test** to limit self-preference (add a second-family judge on the
  calibration subset and flagged items). Pin exact model ids; version the rubric +
  prompt. Determinism comes from version-pin + self-consistency (k=3–5 samples;
  mean for graded, majority for gates), not temperature. **Never let the on-device
  4B judge itself** — small judges are noisy and self-biased.

### The cleanup rubric (ready to use)
4-point anchored scale (even, no neutral midpoint, to suppress score clustering).
Gates are binary.

| # | Dimension | Type | Anchors |
|---|---|---|---|
| **G1** | Meaning preservation / no hallucination | **GATE** | FAIL if output adds/removes/alters any claim vs source |
| **G2** | No substantive content dropped | **GATE** | FAIL if any content-bearing span lost (filler removal is expected, not a fail) |
| **G3** | Names/numbers/entities intact | **GATE** | FAIL if any proper noun/number/date/unit/%/code/URL/email changed, dropped, or invented (also machine-checked, §3) |
| A | Disfluency removal completeness | graded | 1 most remain → 4 all removed, nothing fluent lost |
| E | Grammar / punctuation / casing | graded | 1 unreadable → 4 correct, natural boundaries |
| F | Formatting / readability | graded | 1 wall-of-text → 4 well-segmented, easy to read |
| V | Voice preserved / didn't over-edit | graded | 1 rewritten/formalized → 4 minimal edits, register preserved |

Weight A and V higher (the core of "clean but faithful"). Run the deterministic
gates first; the judge grades Tier-3 polish and adjudicates flags.

### Bias mitigations (built in)
Position → both orders (swap), win only if order-consistent. Verbosity/length →
absolute scoring + length-controlled pairwise + rubric rewards conciseness.
Self-preference → cross-family judge. Leniency/clustering → even scale + anchored
few-shot + self-consistency.

### Calibration plan (validate the judge before trusting it)
1. **Humans first.** 2–3 annotators label a ~50-item calibration subset (gates
   binary, graded ordinal). Compute inter-annotator agreement: Cohen's κ (gates),
   Krippendorff's α (graded). Ship the rubric if α > 0.8; tentative 0.667–0.8;
   revise below 0.667. If humans don't agree, the rubric is broken — fix it before
   blaming the judge.
2. **Judge vs human consensus** on the same subset (target κ ≥ 0.6 on graded dims).
3. **Corruption recall — the decision-relevant test.** Inject synthetic
   corruptions (swap a number, drop a sentence, insert a hallucinated clause, alter
   a name) into known-good cleanups; measure the judge's detection TPR/FPR per gate.
   Average agreement hides exactly the failure we care about; this needs the
   ~200-scale data.
4. **Cross-judge + drift.** Second-family judge on borderline items; recalibrate
   whenever the judge model, rubric, or prompt changes.

---

## 5. Gold set recipe (the highest-leverage Phase 0 item)

No large commercial real-dictation→cleaned corpus exists. The set that matches our
true distribution is ours — build it.

- **Cleanup: ~200 items.** Stratify by length: ~60 short dictation (<50 words),
  ~80 medium (50–300), ~60 long/meeting (>300, multi-speaker). Spread across ~5–8
  domains (technical/code, medical, legal, casual, names-heavy, finance/numbers)
  and a few accents.
- **Hard negatives = ~25–30% of every stratum** (highest signal, because
  over-edit is the main risk): already-clean text (expected edit ≈ 0); tricky names
  (foreign, homophone, brand); dense numbers (dates, currency, units, versions, %);
  embedded code/identifiers/URLs/emails/paths; domain jargon a model might
  "correct"; intentional informal phrasing/quotes to keep verbatim.
- **Annotation — minimize human gold.** Do **not** write full gold-cleaned versions
  for all 200 (cleanup has many valid outputs, and the source already serves as the
  judge's reference). Instead annotate **every** item with a **"must-preserve list"**
  (the entities, numbers, key claims that must survive) — fast to mark, powers the
  deterministic gates, defines G1–G3 ground truth. Fully gold-clean only a ~40–50
  item **anchor/calibration subset** (judge few-shot anchors + §4 calibration). Tier
  every item easy/medium/hard and report per tier. Cost ≈ a few annotator-days.
- **Summary: ~80 items** (from medium/long cleanup items). **Grounded QA: ~80
  (source, question, answer) triples**, including unanswerable questions to test
  refusal/grounding.

### Public datasets to bootstrap before the internal set exists
NC-licensed datasets are generally fine for internal eval only — confirm before
shipping or fine-tuning.

| Dataset | Task | License | Use |
|---|---|---|---|
| DisfluencySpeech (amaai-lab) | disfluency cleanup, 4 transcript tiers = built-in before/after | Apache-2.0 | top pick (synthetic, single speaker) |
| LibriSpeech-PC (openslr 145) | punct+cap restoration (normalized↔restored) | CC BY 4.0 | top pick (read audiobooks, cleaner than dictation) |
| Disfl-QA | disfluent↔fluent pairs | CC BY 4.0 | "does cleanup improve QA" |
| JFLEG | fluency GEC, 4 refs, GLEU | CC BY-NC-SA | eval-only, fluency framing |
| QMSum | meeting summary + query QA | MIT | top pick for summary AND QA |
| AMI / ICSI (Edinburgh mirror, not LDC) | meeting transcripts/summary | CC BY 4.0 | real meetings, free |
| Spoken-SQuAD | QA over ASR (~22% WER) passages | CC BY-SA | end-to-end "does cleanup lift QA" |
| MeetingBank | council-meeting summary, long-form | CC BY-NC-SA | internal eval |

Access gotchas: Switchboard + NUCLE are LDC/gated; use the Edinburgh mirrors for
AMI/ICSI. Reusable eval primitive: FER/DER (pariajm disfluency evaluator).

---

## 6. Summary & grounded-QA: the long-context verdict

For the secondary tasks over long transcripts, **architecture dominates model
choice**. The evidence is consistent and recent:

- **Lost in the Middle** (TACL 2024): QA accuracy is U-shaped in evidence position
  and falls with total length, even for long-context models.
- **RULER** (COLM 2024): effective context is far below advertised; scaling model
  size helps and **small models degrade fastest**.
- **NoLiMa** (ICML 2025): for *associative* (non-literal) questions — the realistic
  transcript-QA case — 11/13 leading long-context models drop below 50% of baseline
  at 32K; even GPT-4o falls from 99% to 70%.
- Length degrades reasoning even with perfect retrieval (2510.05381).
- Qwen3-4B-Instruct-2507 advertises a 256K native window (parent plan §5), but
  advertised windows overstate *reliable* comprehension; its published RULER scores
  are synthetic-retrieval numbers — expect materially worse on associative QA.

A 2-hour meeting is ~20–35k tokens — comfortably inside the advertised window, but
squarely in the range where effective comprehension degrades (per the evidence
above). Therefore:

- **Summary:** map-reduce / hierarchical (summarize chunks → summarize summaries).
  Keeps the working window short, where small models are competent. A well-prompted
  4B is plausibly good enough in that regime.
- **Grounded QA:** retrieve-then-answer (RAG over transcript chunks). Evaluate
  retrieval (context precision/recall) separately from answer faithfulness (Ragas).
- **Cleanup:** inherently chunked, so the long-context problem mostly doesn't apply.

This is the evidence behind the parent plan's instinct that a competent 4B is
"good enough" for summary/QA, with the important qualification that the model must
**not** ingest the whole transcript at once. Phase 0 evaluates the model's *local*
(per-chunk) competence separately from the long-context plumbing: if local
competence is adequate, invest in map-reduce + retrieval rather than a bigger model.

Secondary-task metrics: ROUGE/BERTScore for regression tracking only (never as
quality/faithfulness gates); **AlignScore or FENICE** (faithfulness) + calibrated
LLM-judge rubric for summary; answer-correctness (LLM-judge) plus **Ragas
faithfulness and answer-relevancy** for QA. All published correlations are in-domain (news) upper
bounds — calibrate on a small meeting set.

---

## 7. Runtime & performance reality (MLX / Apple Silicon)

Numbers below are triangulated from measured community benchmarks; the prefill
curve is the gap to close on our own hardware.

### Model + quant — Qwen3-4B-Instruct-2507 (exact HF sizes, 2026-06-27)
| Quant | Size | Note |
|---|---|---|
| 4-bit | 2.26 GB | baseline |
| **4-bit DWQ (2510)** | **2.26 GB** | **ship this — same size, distillation-recovered quality** |
| 6-bit | 3.27 GB | cheap quality upgrade if testing demands |
| 8-bit | 4.27 GB | effectively lossless |
| bf16 | 8.04 GB | reference |

Quant quality consensus: 8-bit ≈ lossless, 6-bit imperceptible, **plain 4-bit is
where degradation becomes measurable — and worse at 4B than at 27B**. DWQ buys
~+0.5–0.6 bits-per-weight for free. So at 4B for a quality-first feature: 4-bit
DWQ, 6-bit, or 8-bit — not naive 4-bit. Measure quant quality with KL-divergence
vs bf16, not just perplexity.

### Decode speed (4-bit, bandwidth-bound)
~45 tok/s (M1) → ~85 (M3) → ~118 (M4 Pro) → ~159 (M4 Max). Short dictation cleanup
is sub-second to a few seconds. Decode is not the concern.

### KV-cache RAM (the long-transcript variable) — Qwen3-4B, GQA
| Context | fp16 KV | kvBits=4 |
|---|---|---|
| 4K | 0.56 GiB | 0.14 |
| 16K | 2.25 GiB | 0.56 |
| 64K | 9.00 GiB | 2.25 |

Total peak ≈ 2.6 GB weights+overhead at short context, **+2–9 GB once a long
transcript fills 16–64K** unless KV is quantized. `kvBits:4` quarters it. MLX OOM is
a hard process crash — budget defensively with Parakeet + diarizer resident.

### Prefill / long context — the #1 unknown to measure
Prefill happens fully before the first token and scales ~linearly with input
length; MLX decode also degrades faster than llama.cpp as KV grows at very long
contexts (mlx-lm #763, open). No clean 4B prefill curve exists publicly — **measure
TTFT at 1K/4K/16K/32K/64K on the dev Mac; find where it crosses the UX budget (no
streamed output during prefill). This sets the single-shot vs map-reduce threshold.**

### Structured output — no native grammar in mlx-swift
mlx-swift has no JSON-schema / GBNF / guided decoding (Outlines works only via
Python). A `LogitProcessor` hook exists to build a custom mask, but for Phase 0 use
**prompt-engineered JSON + parse-validate-retry**, keep schemas small, and strip
stray `<tool_call>`/template artifacts (a documented Qwen3-4B-2507 behavior) even in
plain-text cleanup.

### mlx-swift maturity — shippable
Apple-maintained, demoed at WWDC25, macOS 14.0 deployment floor — at or below our
macOS 14.2+ product floor, so compatible; re-validate on real macOS 14.2 given prior
Swift-6 `#isolation` and ANE-SIGBUS landmines.
AsyncStream `generate`, native `tokensPerSecond` + `promptTokensPerSecond`
instrumentation, prompt-cache `savePromptCache`/`loadPromptCache` (reuse a fixed
system-prompt prefix across cleanup calls), quantized KV via
`GenerateParameters(kvBits:)`. Caveat: `RotatingKVCache.toQuantized()` is a
`fatalError()` — can't combine sliding-window + quantized KV; for long transcripts
use `kvBits:4` on a `KVCacheSimple` with your own chunking. Pin to a major version
(`upToNextMajor`); main is a breaking 3.x.

### The five things to actually measure on the dev Mac
1. Prefill (promptTokensPerSecond + wall-clock TTFT) at 1K/4K/16K/32K/64K input.
2. Peak RSS at 16K and 64K, fp16 KV vs `kvBits:4`, with Parakeet + diarizer resident.
3. Prompt-cache win: prefill a fixed instruction prefix once, measure per-call TTFT drop.
4. Quality at 4-bit-DWQ vs 6-bit vs 8-bit on real dictation + meeting cleanup.
5. Structured-output parse-success rate without a grammar; decide if a custom logits
   processor is worth building.

---

## 8. Baselines, candidates, tooling

### Baselines to beat
- **Deterministic no-LLM** (regex filler-strip + existing punctuation): the floor.
  The LLM must clearly beat this or it is not worth the RAM/latency.
- **Current cloud cleanup** (existing AIFormatter path): the parity/ceiling target.
- **Apple Foundation Models** (macOS 26+, ~3B, ~4096-token window): the no-download
  fallback reference (optional, per parent plan).

### Model bake-off (don't lock onto one)
Qwen3-4B-Instruct-2507-DWQ (Instruct, not the thinking variant) · Qwen3.5-4B (MLX) ·
Gemma-4-E4B (Apache) · Gemma-3-4B *(quality reference only — its custom license
disqualifies it as a shippable base per parent plan §5; if the Gemma cleanup style
wins, ship the Apache-licensed Gemma-4-E4B, not Gemma-3)*. Community signal is that
the Gemma 4B line leans terse and faithful (good for cleanup) while Qwen leans
stronger at summarization/structuring; shipping local-dictation tools already offer
per-scope model selection, so plan for
the possibility that cleanup and summary want different models (#408).

### Eval tooling
- **promptfoo** (MIT, Ollama-native): prompt A/B, `select-best` pairwise, YAML CI gates.
- **deepeval** (Apache-2.0, Ollama-native): G-Eval rubric metrics, Summarization +
  AnswerRelevancy.
- **Ragas** (Apache-2.0): faithfulness / answer-relevancy / context-precision for QA.
- **Custom harness** for the Tier-1 deterministic gates (entity/number diff, NLI,
  edit-distance) — the differentiator.
- Avoid for this purpose: lm-eval-harness / lighteval (benchmark-shaped, no rubric
  infra); openai/evals + simple-evals (no local path; latter deprecated).

### Prior-art prompt to seed from
Among open-source dictation tools, FreeFlow (MIT) has a notably thorough cleanup
system prompt — minimum-edit contract, explicit filler enumeration, strict
self-correction handling, and an instruction-preservation guard (plus a
token-overlap reject heuristic). Reusable pipeline guardrails that recur across
real builds: chunk at ≤~500 words, "do not add or substitute words the speaker
didn't say," suppress preamble, preserve speaker/timing tags, skip trivial inputs
(<50 chars).

---

## 9. Go / no-go criteria

GO if, on the domain-matched gold set:
- Best model+quant achieves a gate pass-rate competitive with the cloud baseline
  and clearly above the deterministic floor, AND
- mean quality among passers ≥ cloud-baseline parity on cleanup, AND
- meets the latency budget (short dictation interactive; long-transcript path has a
  workable map-reduce threshold from the prefill curve), AND
- fits RAM on a 16 GB Mac for the default tier (with `kvBits:4` long-context), AND
- structured-output reliability is high enough (or fixable via validate-retry) for
  the v1 scope (cleanup + summary + Ask; tool-calling is Phase 3).

NO-GO / re-scope triggers: gates fail too often even at 8-bit (over-edit/
hallucination intrinsic at 4B) → consider the 30B-A3B tier (parent plan §3 places
this at the **32 GB** RAM tier, ~18.6 GB weights; in practice gate the *fallback*
higher — ~48 GB — to leave headroom for Parakeet + diarizer + long-context KV, since
MLX OOM is a hard crash) or keep cloud default; prefill makes the long-transcript UX
untenable even with map-reduce → restructure or defer long-transcript cleanup.

---

## 10. Open decisions
1. **Judge weighting:** for a trust-first product, make the deterministic
   entity/number gate the hard ship-blocker and treat the LLM judge mainly as the
   grader of "clean but natural" (recommended — deterministic = reproducible +
   un-gameable)?
2. **Gold-set sourcing:** curate ~200 real items from internal dictation/meeting
   transcripts (privacy-safe, local), with ~50 fully hand-cleaned anchors?
3. **Bake-off breadth:** evaluate all four candidate models, or start Qwen-only and
   add Gemma only if Qwen trips the fidelity gates?
4. **Cleanup vs summary model split:** allow different models per task (#408), or
   hold the parent plan's single-model invariant?

---

## 11. Confidence & gaps
- **High confidence:** the gate-vs-graded asymmetry; the deterministic-gate design;
  MLX quant tiers (8-bit lossless / 6-bit sweet spot / 4-bit measurable / DWQ free
  win); mlx-swift's missing constrained decoding and its KV/prompt-cache API; the
  long-context degradation direction (three independent papers agree, small models
  worst); exact HF model sizes (pulled 2026-06-27); judge bias taxonomy +
  calibration methodology.
- **Medium confidence:** model-pick guidance (Gemma-for-cleanup) is from a couple of
  shipping tools plus one comparison, not a rigorous head-to-head — validate on the
  gold set. Faithfulness-metric correlations are news-domain upper bounds; expect
  degradation on meeting speech.
- **Measure-yourself gaps:** the absolute 4B prefill curve at 4K/16K/64K (no clean
  public data — Phase 0's #1 benchmark); Qwen3-4B associative-QA at our
  lengths/domain; whether SARI/ERRANT-F0.5 actually track human "good cleanup" on a
  pilot.
- **Research-tooling limitation:** r/LocalLLaMA / r/LocalLLM primary threads were
  not reachable from the automated research environment (search/fetch/browser all
  blocked by Reddit anti-bot). Community signal here is triangulated from Hacker
  News, Hugging Face model-card discussions, the MLX maintainer's posts, and
  practitioner blogs — strong overlap with that community but not the primary
  subreddit threads. Worth a manual pass before locking the model pick.

---

## Key sources
MLX quant: mlx-lm LEARNED_QUANTS.md; Awni Hannun (8-bit lossless, DWQ); n8programs
and smcleod quant studies. Runtime: mlx-swift-lm kv-cache.md & Evaluate.swift;
mlx-lm SERVER.md; WWDC25 session 298; mlx-lm #763/#980/#1043; mlx-swift-examples
#221. Long context: Lost-in-the-Middle (TACL 2024), RULER (COLM 2024), NoLiMa (ICML
2025), arXiv 2510.05381. Faithfulness: AlignScore (ACL 2023), SummaC (TACL 2022),
QAFactEval (NAACL 2022), FENICE (ACL 2024), FactScore (EMNLP 2023). Judge: MT-Bench,
G-Eval, Prometheus 2, Length-Controlled AlpacaEval, Survey on LLM-as-a-Judge
(2411.15594), Pairwise-or-Pointwise (2504.14716). Cleanup task: DRES (2509.20321),
MultiTurnCleanup (2305.12029), minimal-edit GEC over-correction (2506.13148), SARI,
ERRANT/BEA-2019, JFLEG/GLEU. Prior art: FreeFlow, pariajm disfluency evaluator.
Datasets: DisfluencySpeech, LibriSpeech-PC, QMSum, AMI/ICSI (Edinburgh),
Spoken-SQuAD.
