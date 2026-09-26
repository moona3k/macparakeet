# Practical local passage retrieval for Ask

Date: 2026-09-26. Research baseline: `c056a9402e6d1fabbc5620c4c28a1983e89127ba`.
This note separates observed repository behavior from the recommended follow-up.
It does not certify model quality or authorize enabling Ask.

## Recommendation

Replace Ask's all-words substring filter with tokenized, any-term candidate
retrieval ranked by BM25, retaining the selected-source and revision checks.
Rank within each source, then preserve the existing round-robin distribution
across sources. Add explicit continuation metadata to `read` and evaluate
retrieval separately from answer generation. This is a useful lexical baseline,
not semantic search and not a complete answer-quality solution.

The immediate defect does not require a new model: `launch date` excludes the
late passage “the launch moved to October 24” because `date` is absent. An OR
candidate query admits that passage. Ranking then decides whether it survives
the result budget. Do not hardcode launch vocabulary, privilege the last page,
or infer that the most recent mention must be a final decision.

## What the repository already provides

- [`AskSourceService`](../../Sources/MacParakeetCore/Services/Ask/AskSourceService.swift)
  validates selected UUIDs and canonical revisions before returning passages.
  At the baseline it matches every whitespace-delimited query substring,
  takes matches in transcript order, and interleaves sources. It derives the
  effective passages directly; it does not query the persistent FTS index.
- [`SegmentRepository`](../../Sources/MacParakeetCore/Database/SegmentRepository.swift)
  already uses SQLite FTS5 and `bm25` for Library/CLI segment search, with
  substring fallback for certain scripts. Its public query does not provide
  Ask's source-ID whitelist or frozen-revision contract. Reusing it without
  adaptation would conflate two different access boundaries.
- [`Database/README`](../../Sources/MacParakeetCore/Database/README.md)
  defines segments and their FTS index as rebuildable derived data, not the
  transcript authority. Citation indices depend on versioned segment derivation.
- No text-embedding runtime or semantic passage index was found in first-party
  `Sources` or `Package.swift`. Existing speaker embeddings represent voice
  identity; they are not text vectors that can answer semantic queries.
- The synthetic [CLI qualification fixture](../../scripts/dev/ask_workspace_qualification.py)
  includes an early October 10/Ada decision and a later October 24/Bea reversal
  after a long irrelevant discussion. That is one regression scenario, not a
  representative retrieval benchmark.

## Established approaches and their tradeoffs

| Approach | What it contributes | Limit for this task |
| --- | --- | --- |
| Tokenized OR plus BM25 | Admits partial word overlap and orders candidates by lexical relevance. | Does not understand arbitrary synonyms or which decision supersedes another. |
| Dense retrieval | Embeds query and passages to find related meaning despite different words. | Adds model distribution, embedding lifecycle, resource cost, and evaluation work. |
| Hybrid plus rank fusion | Combines complementary lexical and dense candidate lists. | Helps only when at least one retriever finds the evidence. |
| Reranking | Scores a shortlisted passage against the question before choosing context. | Cannot recover evidence omitted from the shortlist; adds inference latency. |
| Explicit pagination | Makes further evidence available through clear continuation fields. | Still requires the agent to choose to continue; ranking remains necessary. |

SQLite documents tokenizers, explicit OR matching, and built-in BM25. Merely
passing natural-language words to FTS is insufficient: whitespace in its query
syntax implies AND. Construct a bounded literal-term query rather than exposing
the model's string as FTS operators. Unicode tokenization supports case folding
and diacritic handling; Porter stemming is English-specific, so applying it to
all transcripts would need language-aware evaluation. Lower SQLite BM25 scores
rank first. [SQLite FTS5](https://www.sqlite.org/fts5.html)

The standard retrieve-then-rerank pattern first obtains a larger candidate set
with lexical or dense search, then scores query-passage pairs with a more
expensive model. Sentence Transformers describes both bi-encoder retrieval and
cross-encoder reranking. This supports separating candidate recall from final
ranking instead of asking the chat model to discover everything through repeated
keyword guesses. [Sentence Transformers](https://sbert.net/examples/sentence_transformer/applications/retrieve_rerank/README.html)

For a later hybrid implementation, reciprocal rank fusion combines positions
from separate result lists instead of treating BM25 and vector similarity as
directly comparable scores. Azure's documented pipeline fuses results before
semantic reranking. This is architectural precedent, not a proposal to send
MacParakeet transcripts to Azure. [Microsoft RRF documentation](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking)

BEIR evaluated heterogeneous retrieval tasks and found BM25 a strong baseline,
with reranking and late-interaction approaches performing well at higher
computational cost. Its results argue for measuring domain-specific gains rather
than assuming dense retrieval is universally better. They do not establish the
best model for meeting transcripts. [BEIR paper](https://arxiv.org/abs/2104.08663)

## TypeSafe/Jev assessment

The live [documentation index](https://docs.typesafe.ai/llms.txt),
[reranking cookbook](https://docs.typesafe.ai/cookbooks/rerank_typesafe),
[model page](https://docs.typesafe.ai/models), and
[API contract](https://docs.typesafe.ai/api) were reviewed. The Markdown URLs for
the latter pages failed in the browser tool; their normal pages were readable.

The cookbook uses BM25 to produce a 30-passage shortlist, then a typed `Noul`
judgment per query-candidate pair. It explicitly distinguishes candidate coverage
from reranking: omitted evidence cannot be promoted. Its legal-corpus results
are a worked example, not a threshold or accuracy claim for our recordings.
A future Ask judgment should test whether a passage supplies evidence relevant
to the actual question, with criteria distinguishing direct support from merely
sharing a topic. Preserve original text and citation identity; the judgment
selects evidence rather than manufacturing it.

The reviewed model/API docs describe a hosted endpoint and do not document
downloadable local Jev weights or a local runtime. That is a bounded finding,
not proof no private deployment exists. The repository's
[`JevDecisionClient`](../../Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift)
calls `api.typesafe.ai` and requires Voice Control-specific cloud-context
consent. That consent must not silently authorize sending Ask transcript
passages to another service. No Jev inference was used for this research and
none is required for the proposed deterministic lexical baseline. If semantic
reranking is added later, prefer Jev for the bounded judgment only after its
deployment and Ask-specific consent requirements are settled and tested.

## Bounded first implementation

1. Load and validate current canonical passages for the selected scope, preserving
   edited text and speaker corrections. Retrieve from all eligible passages,
   including late ones, before limiting results.
2. Normalize/tokenize the query; construct literal any-term retrieval with
   deterministic tie breaks. Apply a documented strategy for punctuation-only
   queries and scripts without whitespace. Do not silently strip arbitrary
   domain words or claim stemming/synonym support that is not implemented.
3. Use an ephemeral local FTS index over that checked scope, or an equivalent
   tested lexical ranker. An ephemeral index avoids a new persistent migration
   and keeps stale derived rows out of the answer path. Measure its build/search
   cost on long transcripts; 32 selected sources does not bound their size.
   Add revision-keyed caching only if those measurements justify it.
4. Rank per source and interleave, preserving the current comparison behavior.
   Keep result and byte budgets. Expose truthful match-mode/coverage metadata;
   `hasMore=false` means no more matches for this query, not no missing evidence.
5. Return `read` metadata such as start, total passages, and next start alongside
   passages. Continuation must reflect what was actually returned after byte
   budgeting; do not skip omitted passages. Update the tool descriptions,
   Swift bridge instructions, contract, and focused tests together.

## Must-not-change invariants

- Ask remains disabled by default. This retrieval improvement is not native GUI,
  live-model, packaging, or release qualification.
- No new network calls, implicit cloud processor, or model downloads.
- Only selected source IDs and matching canonical revisions can supply evidence.
- Keep the existing passage/citation identity, corrections, stale-source failure,
  and terminal revalidation. Do not change segmentation just to improve a score.
- Keep existing answer/provider permissions, cancellation and execution budgets,
  and persistence semantics. A real citation is not proof of semantic support.
- No changes to public Library search behavior are required for this Ask fix.

## Evaluation and next decision

Use deterministic retrieval tests that assert the necessary passage enters the
bounded result set, not a fixture-specific rank of one. Include partial overlap,
late reversal, rare names, punctuation/diacritics, repeated distractors, source
balance/exclusion, stale revisions, corrected text, and pagination boundaries.
Add a no-shared-word paraphrase case documenting the lexical baseline's limit.

Run end-to-end model qualification separately on the same recordings and
questions. Record candidate recall at the tool limit, rank of required evidence,
answer correctness, citation support, source coverage, honest abstention, tool
loops, latency, and budget exhaustion. Preserve traces in an isolated synthetic
test store; production transcript logging should not be introduced for this.
Do not count scripted-provider success as model reasoning evidence.

If remaining misses have no lexical overlap, evaluate a local text-embedding
retriever and hybrid fusion. If candidates contain the answer but rank poorly,
evaluate reranking. If the model sees the answer and confuses meeting dates with
decision dates, that is synthesis/grounding work. These failure classes require
different fixes; a larger model or Pi provider migration alone is not a verified
solution to all three.

## Implemented first increment and architecture review

The follow-up implements the scoped disposable FTS approach, preserving the
canonical passage identity and source round-robin order. Search and read both
expose actionable continuation; search offsets address the interleaved result
sequence, while read offsets address canonical passage indices. Both serialize
whole-passage prefixes to the existing tool/run byte budgets, allocating markers
only for accepted evidence. Search identifies `unicode61_bm25` or `mixed_lexical`
matching so substring fallback is not mislabeled as BM25.

The user requested GPT-6 Astra as an architecture oracle through Codex. The
review ran with `codex exec --model gpt-6-astra --sandbox read-only`; session
`01a0defd-eb65-7be3-ac8b-24e2e660d249`. Its recommendation was to proceed with
this lexical increment, preserve the canonical snapshot boundary, add actionable
search pagination, preserve non-Latin combining marks, bound materialization,
and separate retrieval evaluation from model answer qualification. Those
recommendations informed this implementation. Its proposed latency/RSS targets
were advisory, not measured guarantees or feature-enablement criteria.

Stored transcript, timing, speaker, and correction payload sizes are checked
before decoding (64 MiB aggregate). Canonical passage text plus speaker labels
are limited to 32 MiB and 50,000 passages across the selected scope. Oversize
input fails visibly rather than indexing a prefix. These limits bound admitted
retrieval data, not total process RSS: canonical decoding/segmentation and hashing
still use existing synchronous code. Cancellation is checked through loading,
index insertion, fallback scanning, and source ranking boundaries; interruption
inside an individual decoder, sort, or SQLite statement is not promised.

### Measured retrieval cost

On Apple M4 Pro, 48 GiB RAM, Debug SwiftPM build, in-memory synthetic recordings,
32 selected sources, five fresh retrieval calls per query/tier:

| Canonical passages | Query | Observed wall time per call |
| --- | --- | --- |
| 10,000 | Sparse `telescope` | 0.103–0.109 s |
| 10,000 | Common `launch` | 0.169–0.176 s |
| 10,000 | Mixed `日期 launch` | 0.163–0.174 s |
| 50,000 | Sparse `telescope` | 0.458–0.464 s |
| 50,000 | Common `launch` | 0.815–0.820 s |
| 50,000 | Mixed `日期 launch` | 0.747–0.758 s |

These timings include canonical reads/derivation/revision hashing, fresh index
construction (ordinary queries), ranking, and source interleaving. They exclude
fixture creation, initial snapshots, tool JSON serialization, and model calls.
The passages are short synthetic text, not the maximum 32 MiB payload. This is
not a low-end hardware, disk-backed database, peak-RSS, or worst-case cancellation
qualification. The result does not justify adding a persistent index or cache
in this patch.

Reproduce deliberately (excluded from normal tests):

```sh
MACPARAKEET_ASK_BENCHMARK=1 swift test --filter AskRetrievalBenchmarkTests
```

Focused tests cover the reported partial-query/late-decision misses, lexical
ranking against distractors, literal operators, case/diacritics, unspaced scripts,
mixed-script Latin token boundaries, source exclusion, revision changes,
pre-decode input-size rejection, cancellation at entry, and page/marker behavior.
Scripted CLI qualification uses `launch date change` and tests transport,
persistence, follow-up, source changes, stale citations, and interruption.
Neither those tests nor the benchmark certify model synthesis or semantic recall.

### Real-model diagnostic boundary

Local LM Studio runs used `qwen/qwen3-4b-2507` and `google/gemma-4-e4b`, with the
same isolated synthetic recordings as the CLI qualification script. Initial
runs of each still failed to complete the main workflow (Qwen 36.19 s; Gemma
49.55 s). A second run through a temporary loopback capture proxy exposed the
requests, tool results, and responses without adding production logging.

In the captured Qwen run, it searched `launch date` on the later source with
`limit: 1`, receiving the opening hit and `nextStart: 1`. It then called **read**
at passage 1 rather than continuing **search** at result offset 1, later emitted
an invalid zero read limit, and failed action validation. Retrieval continuation
exists, but that model did not use its documented meaning correctly.

In the captured Gemma run, `launch date change owner` at limit 8 delivered the
late October 24/Bea passage. The initial answer correctly stated the change from
October 10/Ada to October 24/Bea, with citations to both supporting sources.
This proves that this particular query retrieved the required evidence and this
particular answer used it correctly. It does not establish repeatable model
reliability, arbitrary semantic recall, or native app qualification. No feature
flag is enabled by this work.
