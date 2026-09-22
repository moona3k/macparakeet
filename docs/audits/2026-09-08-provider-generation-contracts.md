# Provider generation contracts

Research date: 2026-09-08. Scope: the existing Chat Completions / Messages
integrations and the six generation fields already persisted by
`PromptInferenceSettings`. This is evidence for
[the approved model-aware settings plan](../plans/2026-09-08-model-aware-generation-settings.md);
it does not authorize a provider-capability service, a new reasoning feature,
or live requests.

## Reading the contracts

- **Supported** means the provider documents that the field is accepted for the
  selected model and endpoint.
- **Discouraged** means the provider says the field is accepted but recommends
  omission. It must remain distinct from unsupported.
- **Unknown** means an OpenAI-compatible server or a gateway model has not
  published support metadata. Do not claim a universal value, ceiling or
  thinking mapping in that case.

## Current PR boundary

This PR retains the existing adapter request shapes and application baselines.
When a baseline remains in a payload, the UI must call it an **app default**,
not an inherited provider default. The one requested automatic-behavior change
is ordinary Gemini 3 prompt generation: it must omit the legacy temperature
0.7. Explicit saved settings and historical result receipts retain their
meaning.

The evidence below also identifies future provider integrations. Those are
not acceptance requirements here: no new OpenRouter capability metadata,
server templates, LM Studio top-p/top-k wire support, native reasoning
mapping, or custom-endpoint discovery is introduced by this PR.

## Anthropic Messages

| Field | Current primary-source contract | Product implication |
| --- | --- | --- |
| `max_tokens` | A Messages request has a total output ceiling. For manual extended thinking, thinking tokens count toward it; `budget_tokens` must normally be at least 1,024 and less than `max_tokens`. [Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking#budget-rules-and-tuning) | Keep one explicit output-token control. Do not show a generic 131,072 maximum as a known Claude model limit. The current adapter's 4,096 fallback is an **app default**, not a documented provider default. |
| `temperature`, `top_p`, `top_k` | Anthropic documents all three as deprecated and says a non-default value returns HTTP 400 on **Claude Opus 4.7 and later** and Claude Mythos Preview. [Model deprecations](https://platform.claude.com/docs/en/about-claude/model-deprecations#api-parameter-deprecations) | These are not merely ignored for those models: hide them and omit them. For legacy models, preserve the existing temperature/top-p adapter behavior; do not add `top_k` until the direct adapter maps and tests it. If both legacy temperature and top-p are present, retain the existing documented app precedence of top-p rather than sending a conflicting pair. |
| Thinking / effort | Manual `thinking: {type: "enabled", budget_tokens: ...}` is rejected on Claude 4.7+; newer models use `thinking: {type: "adaptive"}` with `output_config.effort`. The documented migration explicitly changes both request shapes. [Extended-thinking migration](https://platform.claude.com/docs/en/build-with-claude/extended-thinking#migrating-to-adaptive-thinking) | The current generic enabled/disabled picker cannot honestly drive Claude native reasoning. Keep it unavailable for the direct Anthropic adapter in this change. Do not turn effort labels into a budget formula. |

### Concrete Anthropic safeguard

The current resolver uses a frozen legacy allowlist that ends at Claude 4.6;
its configured fallback catalog separately includes `claude-opus-4-8`. The
allowlist already correctly keeps that fallback from inheriting the app's
`temperature: 0.7`. Preserve that conservative default when updating model
names: new or unknown direct models must omit sampling unless their contract
is explicitly verified, rather than being added to a broad family rule.

Required fixture assertion: for `claude-opus-4-8`, both automatic settings
and a saved temperature/top-p/top-k override must produce a Messages JSON body
without those keys; the explicit override is retained as inactive editor state,
not silently deleted. A legacy model fixture should still prove the supported
temperature or top-p request path.

## Direct OpenAI Chat Completions

The current GPT-5.2 guidance says `temperature` and `top_p` work only
with `reasoning_effort: "none"`; other reasoning efforts, and older GPT-5
requests, reject them. [GPT-5.2 parameter compatibility](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.2)

The current direct OpenAI adapter does not encode `reasoning_effort`.
Therefore its existing conservative policy—omit sampling for GPT-5 reasoning
and o-series models—is correct for this PR. It must not expose a direct
OpenAI thinking/effort picker merely because the public API has one. A later
adapter addition can make the model/effort-conditioned sampling combination
available with dedicated tests.

Required fixture assertions:

- a GPT-5.2 request with automatic settings omits `temperature` and
  `top_p`, while retaining the appropriate output-token key;
- a legacy sampling-capable OpenAI model can still receive an explicit
  temperature/top-p value;
- no request claims an OpenAI `reasoning_effort` until the adapter actually
  serializes it.

## Google Gemini OpenAI-compatible endpoint

Gemini 3 guidance strongly recommends omitting sampling controls and using the
backend default temperature of 1.0; Google warns that lower explicit values
can cause looping or degraded performance. That is **discouraged**, not a
generic unsupported claim. [Gemini 3 guide](https://ai.google.dev/gemini-api/docs/gemini-3)

The Models API publishes model-specific `temperature`, `maxTemperature`,
`topP`, `topK`, `outputTokenLimit`, and `thinking` values. A blank
`topK` means the model does not permit top-k. [Gemini Models API](https://ai.google.dev/api/models)
This is useful future evidence, not a request to add a capability-discovery
service or static model catalog in this PR.

The API has model-specific thinking controls, but the current Gemini adapter
does not encode them. Keep thinking/effort unavailable here; do not represent
an app-side boolean as native Gemini thinking.

Required fixture assertions:

- an ordinary Gemini 3 prompt with automatic settings has no sampling fields
  in the wire payload or effective receipt;
- an explicitly saved temperature override remains explicit and is sent as
  such, with a discouraged-use explanation rather than silently removed;
- a historical receipt containing temperature 0.7 regenerates with 0.7, so
  the behavior change does not rewrite history.

## Ollama native Chat API

Ollama's native chat endpoint accepts `options` and a model-dependent
`think` value: supported models may accept a Boolean or
`"low"`/`"medium"`/`"high"` string. [Chat API](https://docs.ollama.com/api/chat)
and [thinking capability](https://docs.ollama.com/capabilities/thinking).
Its Modelfile also defines `temperature`, `top_p`, `top_k`, and
`num_predict`, but those are model/runtime defaults rather than universal
provider values. [Modelfile parameters](https://docs.ollama.com/modelfile)

The current adapter sends numeric sampling in `options`, maps maximum
output to `num_predict`, and sends only Boolean `think`. The current PR
keeps that behavior and leaves generic reasoning effort unavailable. It does
not add model-level Ollama thinking discovery or alter the documented legacy
thinking-off behavior.

Existing adapter tests already cover the current wire shape: explicit
temperature/top-p/top-k/max-tokens produce `options.temperature`,
`options.top_p`, `options.top_k`, and `options.num_predict`; enabled
thinking produces `think: true`. A model-specific effort integration would
need separate fixtures in a later change.

## OpenRouter Chat Completions

OpenRouter is a gateway, so its capabilities are **per model**, not a property
of the `openrouter` provider enum.

- Its Models API exposes each model's `supported_parameters`, its
  `top_provider.max_completion_tokens`, and model identity. The list may be
  filtered by `supported_parameters`. See [Models guide](https://openrouter.ai/docs/guides/overview/models#models-api-standard)
  and [model response schema](https://openrouter.ai/docs/guides/overview/models#model-object-schema).
- The documented chat endpoint accepts fields including `temperature`,
  `top_p`, `top_k`, `max_tokens`, `max_completion_tokens`,
  `reasoning`, and `reasoning_effort`; acceptance still depends on the
  selected model and route. [Chat Completions reference](https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request).
- Reasoning metadata can name only supported effort values, mark reasoning as
  mandatory, and say whether a model accepts a reasoning token budget. A
  model with mandatory reasoning must not receive an “off” request. [Reasoning
  tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens#discovering-per-model-reasoning-options).

The current static `[temperature, maxTokens]` treatment is a conservative
subset, not an accurate gateway-wide capability statement. This PR preserves
that scope and does not add OpenRouter metadata parsing, capability UI or new
payload mappings. It must not claim that the existing generic thinking mode
maps to routed models.

Future integration evidence, not current acceptance requirements:

1. A model record with only `temperature`, `top_p`, and `max_tokens`
   permits those exact JSON keys and omits `top_k` and `reasoning`.
2. A reasoning record with `mandatory: true` has no disable control and
   never emits an off/none request. A record without a reasoning object does
   not expose an effort control.
3. If `top_provider.max_completion_tokens` is present, validate an explicit
   request against that value; if absent, show no invented ceiling.
4. Per-model automatic behavior could omit optional generation keys. Any
   retained application baseline would first need a deliberately labelled
   migration.

## OpenAI-compatible servers

“OpenAI-compatible” describes an endpoint shape, not a common model contract.
Capabilities must be narrowed to a known server/model, or remain unknown.

### LM Studio

LM Studio documents its **Chat Completions** payload as supporting
`temperature`, `top_p`, `top_k`, and `max_tokens`.
[LM Studio Chat Completions](https://lmstudio.ai/docs/developer/openai-compat/chat-completions)
It also documents a separate REST/Responses reasoning interface; that is not
evidence that its Chat Completions endpoint accepts the app's current
`chat_template_kwargs` shape.

The documentation supports a possible later LM Studio expansion, but it is
not current scope. This PR retains the existing LM Studio mapping; it does
not add top-p/top-k payload support, server capability templates or a claimed
model output ceiling. Native thinking/effort stays unavailable.

### vLLM and arbitrary custom endpoints

vLLM documents `top_k` as a non-OpenAI extension and tells SDK clients to
place it in `extra_body`. Direct HTTP callers may merge its extra parameters
into JSON. More importantly, vLLM applies a model repository's
`generation_config.json` by default, so its sampling defaults can be
model-author-defined; `--generation-config vllm` changes that behavior.
[vLLM OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server/)

For this PR, an unknown custom endpoint retains its existing explicitly saved
controls as editable **Unverified—sent as requested** settings. Do not
silently delete, inactivate or reinterpret them, and do not claim their
values are server defaults. Automatic preserves the existing application
baseline and labels it accurately. Top-k extensions, model templates and
universal omission rules are future work; a dedicated vLLM wire fixture would
belong with that work.

## xAI and DeepSeek custom endpoints

A supplemental Grok/Cursor review checked two hosted OpenAI-compatible APIs.
Their native reasoning shapes differ from the custom adapter's existing
`chat_template_kwargs` mapping:

- xAI documents reasoning effort separately from sampling, with model-specific
  restrictions. Its Chat Completions and Responses interfaces also have different
  token-budget semantics. See [reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning)
  and [API comparison](https://docs.x.ai/developers/model-capabilities/text/comparison).
- DeepSeek documents top-level `thinking` and `reasoning_effort`, uses
  `max_tokens` for Chat Completions, and states that sampling controls have no
  effect in thinking mode. See [Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)
  and [thinking mode](https://api-docs.deepseek.com/guides/thinking_mode/).

Neither is evidence that the app's generic local-template thinking controls
configure that vendor's reasoning. Retain existing manual custom settings as
unverified, explain that an endpoint may reject or ignore them, and never show
vendor-specific thinking defaults or output ceilings as known custom-endpoint
values. Native vendor mappings, additional token-key policies and Responses
integrations remain future work. No paid inference calls were made.

## Resulting small implementation boundary

1. Compute presentation from the already effective provider/model using the
   existing resolver and adapter knowledge. Keep that presentation small; no
   provider catalog or new discovery service.
2. Keep the resolver and adapter as the execution authority. The editor
   prevents known-invalid direct-provider requests, labels retained app
   baselines, and preserves custom endpoint intent.
3. Do not map the generic thinking toggle to Anthropic adaptive thinking,
   OpenRouter reasoning, LM Studio Responses reasoning, or arbitrary
   OpenAI-compatible `chat_template_kwargs`. Those are future, distinct
   request contracts.
4. Add exact-payload absence checks for the Gemini 3 automatic change and
   preserve historical receipt regeneration. Keep existing adapter tests for
   unchanged providers; do not create speculative provider fixtures.

## Sources

- OpenAI: [GPT-5.2 parameter compatibility](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.2).
- Anthropic: [API parameter deprecations](https://platform.claude.com/docs/en/about-claude/model-deprecations#api-parameter-deprecations), [extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking).
- Google: [Gemini 3 guide](https://ai.google.dev/gemini-api/docs/gemini-3), [Models API](https://ai.google.dev/api/models).
- Ollama: [Chat API](https://docs.ollama.com/api/chat), [thinking capability](https://docs.ollama.com/capabilities/thinking), [Modelfile parameters](https://docs.ollama.com/modelfile).
- OpenRouter: [Models API](https://openrouter.ai/docs/guides/overview/models), [chat completion request](https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request), [reasoning tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).
- LM Studio: [OpenAI-compatible chat completions](https://lmstudio.ai/docs/developer/openai-compat/chat-completions).
- vLLM: [OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server/).

All source claims were read on 2026-09-08. No credentials, paid endpoints or
live generation requests were used.
