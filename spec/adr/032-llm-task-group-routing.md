# ADR-032: LLM Task-Group Routing and Specialist Recipes

> Status: **ACCEPTED** (direction; not implemented)
> Date: 2026-09-14
> Related: [ADR-011](011-llm-cloud-and-local-providers.md) (providers and
> shared client), [ADR-004](004-deterministic-pipeline.md) (deterministic
> cleanup stays first), [ADR-022](022-transforms-system-wide-rewrite.md),
> [spec/11-llm-integration.md](../11-llm-integration.md)
> Issues: #408 (canonical split), #930 (cleanup vs summary models),
> #265 / #939 (specialist cleanup), #1003 (translation specialist)

## Context

MacParakeet is a hybrid of latency-sensitive dictation and long-context
meeting intelligence. Those jobs want opposite LLM properties:

| Job | Surfaces today | Wants |
|-----|----------------|-------|
| Cleanup | AI Formatter (dictation and short file/meeting format) | Fast, faithful, small context |
| Analysis | Summary, Ask, custom prompts, knowledge cards | Capable, long context |
| Transforms | Selected-text rewrites | Latency like dictation, generality like analysis |

[#408](https://github.com/moona3k/macparakeet/issues/408) asked to separate
dictation/transform AI from meeting AI on model size, latency, and cost.
The latency half shipped as independent formatter **enablement** toggles
("Use for dictation", "Use for transcripts") plus a transcription input
cap. Settings still stores **one** default `LLMProviderConfig`.
`StoredLLMExecutionContextResolver` is task-blind. Prompt and Transform
`modelOverride` values, and `--model` on commands that use the saved
Settings route, overlay that route and are not removed by this ADR.
Inline CLI commands that pass a full provider context are independent
configs; they do not require the saved Settings route.

[#930](https://github.com/moona3k/macparakeet/issues/930) is a cleanup-tuned
chat model that is a poor summarizer. [#265](https://github.com/moona3k/macparakeet/issues/265)
and [#939](https://github.com/moona3k/macparakeet/issues/939) ask for
specialist normalizers (Sotto, Superwhisper S1-mini) with control over
what is sent and returned. [#1003](https://github.com/moona3k/macparakeet/issues/1003)
asks for Hy-MT2 as local meeting **translation**, which is a different job
(spec F31, not implemented).

The wrong generalizations are (1) a model picker on every AI feature and
(2) treating every Hugging Face checkpoint as another name in the default
Claude/Ollama list.

## Decision

If MacParakeet adds per-task model selection, it follows this ADR. This
does not schedule the work and does not change current runtime behavior.

**Product model:** define a few tasks, then a selector on each task.
Inherit the default, pick a general LLM route, or — where the task
allows a recipe — pick a specialist recipe. Same Settings control; two
contracts underneath.

### 1. Granularity is tasks, not features

Do not add a Settings model picker per LLM feature. Map features onto a
small set of inherited groups:

| Group | Features | Default |
|-------|----------|---------|
| `cleanup` | Formatter for dictation and file/URL/meeting transcription | Inherit the default AI route |
| `analysis` | Prompt results / summaries, transcript chat, live Ask, knowledge cards | Inherit the default AI route |
| `transform` | System-wide Transforms | Inherit the default AI route; no required Settings row |
| `translate` | Transcript translation (spec F31) | Only if that product ships; not a current Settings row |

Summary and Ask share `analysis`. Dictation format and file format share
`cleanup`; they already have independent on/off toggles. Transforms
inherit the default **route** until a concrete need appears for a
task-group override; existing per-prompt and per-Transform
`modelOverride` (same provider, different model name) stays. A meeting
can hit more than one task: formatter rewrite is `cleanup` (the Dictation
& cleanup row, not Meetings & library); summarize/Ask is `analysis`; a
future translation pass is `translate`. Do not rewrite the canonical
stored transcript in place.

### 2. One default, sparse full-route overrides

Keep today's Default AI block (provider, credentials, model). Add at most
two collapsed override rows for the jobs that exist today:
**Dictation & cleanup** (`cleanup`) and **Meetings & library**
(`analysis`). Meeting formatter still uses the cleanup row. Each row is
"Use default" or a complete general-LLM route. A specialist recipe (see
§5) is offered only on eligible tasks: `cleanup` now, `translate` only if
F31 ships. The analysis row does not offer a recipe.

A general-LLM override is a full `LLMProviderConfig` (and Local CLI
config when that provider is selected), not a model-name string.
Same-provider cheaper models (Haiku vs Sonnet) are the easy case. The
cost/privacy case in #408 is local cleanup plus cloud meetings; a
model-only override cannot point dictation at Ollama while meetings stay
on Anthropic.

Unset override means inherit default. Saving an override must not mutate
the default route.

### 3. Grow the resolver, not a second client

Call sites stay on `LLMService`. The service maps the operation to a
task group. `StoredLLMExecutionContextResolver` (protocol
`LLMExecutionContextResolving`) resolves `override ?? default` and
returns one `LLMExecutionContext`. Existing prompt/Transform
`modelOverride` still applies on that general-LLM context after the
route is chosen. `RoutingLLMClient` and provider adapters stay unchanged
for general LLM routes.

Do not add a second `LLMService`, a parallel client, or per-ViewModel
provider configuration.

Resolve the route once at operation start. `llm_runs` already records
`provider` and `model`; keep that snapshot. A settings change must not
rewrite an in-flight call.

CLI uses the same policy (`summarize` / chat → `analysis`, formatter →
`cleanup`, transform → `transform`). Existing `--model` on
stored-config commands remains an invocation overlay, not a saved
task-group policy. Inline CLI commands that pass a full provider
context stay independent configs.

### 4. Enablement stays independent of routing

"Use for dictation" and "Use for transcripts" remain on/off gates. They
do not select models. Each surface has its own formatter prompt; both
still share the cleanup task-group route. Users who only needed to keep
LLM off the dictation hot path are already served.

### 5. Specialists are recipes bound to a task

A **general LLM** speaks the existing chat protocol. ADR-011 routing is
enough: pick provider + model for that task.

A **specialist** (S1-mini, Hy-MT2, a future normalizer) has its own
prompt, sampling, length cap, and output contract. It is a **recipe** for
one task, not a row in the default model list. The selector can show it
next to Claude/Ollama; the call path must not send the generic formatter
prompt or JSON schema.

A recipe declares:

- **Job:** `cleanup` or `translate` (not `analysis`)
- **Transport:** the cleanup/translate route (Ollama/LM Studio) or a
  pinned local download
- **Request:** system message or none, user template, sampling, input cap
- **Response:** plain text vs JSON field, whether empty is success,
  reject truncated output

Ship zero or more **built-in** recipes after they beat the current path
on real MacParakeet text (S1-mini is a cleanup candidate; Hy-MT2 is a
translate candidate only if F31 exists). Power users may duplicate a
recipe, point it at their server, and edit the template. That is the
customization asked in #265: control what is sent and what counts as
output, without a plugin marketplace or an arbitrary Hugging Face ID in
the default picker.

The first proven specialist is one typed adapter behind that task
(`TranscriptFormatter` for cleanup). Extract shared download/pin/fallback
machinery when a second specialist needs it. Do not add llama.cpp for one
checkpoint. Do not auto-download.

S1-mini stays English dictation cleanup: deterministic Clean still runs
first; failures fall back to Clean; meetings, files, summaries, Ask,
Transforms, and app formatter profiles do not use it. Those surfaces keep
the general cleanup, analysis, or transform route (inherit or that
task's general override), not an implicit second specialist. Identify it as
**S1-mini by Superwhisper** where the model is chosen and in Third-Party
Notices. See [#939](https://github.com/moona3k/macparakeet/issues/939).

Hy-MT2 is machine translation, not cleanup. It must not occupy the
cleanup or analysis slot.

### 6. First-party Local MLX stays one general model

The on-device local LLM plan's single-model invariant applies to the
**shipped first-party general** model. Built-in specialist recipes are
separate, optional, and task-bound. BYO users may still point task
groups at different general providers or models.

## Current behavior (unchanged until implemented)

- One saved default provider config via `LLMConfigStore`.
- Task-blind `StoredLLMExecutionContextResolver`.
- Per-prompt and per-Transform `modelOverride`, plus `--model` on
  stored-config CLI commands, overlay that saved route without replacing
  it. Inline CLI commands that pass a full provider context are
  independent configs.
- Per-surface formatter enablement and the transcription length cap.
- No specialist recipes and no translation product.

Treat those as the implemented contract. This ADR is the design to
follow when that contract grows.

## Consequences

Positive:

- Cleanup can be cheap/local/fast while meeting AI stays capable.
- Settings stay per-task selectors instead of a feature matrix.
- Specialists stay customizable as recipes without forking `LLMService`.
- Transport, generic prompts, and call sites do not fork for ordinary
  BYO models.

Tradeoffs:

- Cross-provider overrides mean two credentials and two connection
  tests. Accept that cost for the users who need it; default remains one
  route.
- Transform inherits default, so a cleanup-tuned default still affects
  Transforms until someone overrides or changes the default.
- A recipe is more than a model id. Wrong prompt/protocol will look like
  "it works" and still drop meaning; evaluate before shipping a built-in.

## Alternatives considered

### Per-feature model pickers

Rejected. Five Settings rows for jobs that collapse to two groups.
#408 and #930 are cleanup vs analysis, not formatter vs chat vs summary.

### Model-name override on the same provider

Rejected as the only override shape. It cannot express local cleanup plus
cloud meetings. Same-provider different models remain allowed as a
full-route override that happens to reuse provider and key.

### Specialists as names in the default model list

Rejected. S1-mini and Hy-MT2 do not speak the generic formatter/summary
contract. Putting them in the analysis slot reproduces #930.

### Plugin marketplace / arbitrary Hugging Face IDs

Rejected. Customization is duplicating a task-bound recipe, not loading
unreviewed checkpoints into every AI surface.

### Named profile manager in v1

Deferred. A list of named credentials with task-group pointers is a
reasonable later Settings shape. V1 is one default plus sparse per-task
selectors. Do not block the split on a profile UI.

### Hold a permanent single-route invariant for BYO users

Rejected as the answer to #408. The enablement toggles already cover
"skip dictation LLM." Users who want AI on both surfaces with different
cost or specialization still have no route.

## References

- `spec/11-llm-integration.md` — current provider/client contract
- `plans/active/2026-06-27-on-device-local-llm.md` — first-party single
  general model
- [#939](https://github.com/moona3k/macparakeet/issues/939) — S1-mini
  as a cleanup recipe candidate
