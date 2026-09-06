# Per-Prompt LLM Inference Settings

> Status: **IMPLEMENTED CANDIDATE / PR #956** — integration repairs await
> maintainer validation. Default semantics and the conditional reasoning-effort
> extension are recorded in
> [`plans/active/2026-09-03-per-prompt-inference-settings.md`](../plans/active/2026-09-03-per-prompt-inference-settings.md).

Target: MacParakeet

Scope: Prompt Library result prompts (`Prompt.Category.result`)

## Outcome

A custom Prompt Library prompt can carry its own generation settings. Manual,
queued, auto-run, retry, and regenerate flows use the settings captured for
that run. Existing prompts retain their request-parameter defaults.

The first implementation supports:

- `temperature`
- `topP`
- `topK`
- `maxTokens`
- `thinkingMode`: default, enabled, or disabled
- `reasoningEffort`: default, low, medium, high, or extra high; only effective
  when thinking is enabled

This is deliberately a typed feature, not an arbitrary JSON request editor.

## Why this change is needed

`ChatCompletionOptions` already carries `temperature` and `maxTokens`, and the
HTTP adapters already apply model-specific rules such as using
`max_completion_tokens` for OpenAI reasoning models. Prompt-result generation,
however, always passes `.default`, while `Prompt` has no persisted inference
settings. A user therefore cannot tune one summarization prompt without
changing code or affecting unrelated LLM operations.

Local models make this particularly visible. A long meeting summary may need a
larger output budget and deterministic sampling, while a thinking-capable
endpoint may need reasoning explicitly disabled or bounded to avoid spending
the context and token budget unnecessarily.

## Product behavior

### Prompt Library

The create and edit forms gain a collapsed **Generation settings** section.
Every field starts at **Default**. This means inheriting MacParakeet's current
prompt-result and adapter behavior, not forcing the upstream provider to omit
the parameter. The user may set only the values needed by that prompt.

Controls:

| Setting | UI | Accepted value |
| --- | --- | --- |
| Temperature | Optional number | `0...2` |
| Top P | Optional number | `0...1` |
| Top K | Optional integer | `0...1000`; `0` means disabled where supported |
| Maximum output tokens | Optional integer | `1...131072` |
| Thinking | Picker | Default / Enabled / Disabled |
| Reasoning effort | Conditional picker | Default / Low / Medium / High / Extra high; shown only when Thinking is Enabled |

The section includes **Reset to defaults**, which clears every value.
Neutral validation happens during JSON decoding, repository writes, and
execution resolution, as well as in the GUI draft. Invalid numeric values
throw `PromptInferenceSettings.ValidationError`; they are not clamped or
silently discarded even when a provider would omit that field. Blank means
unset; blank is not converted into zero. Native Anthropic additionally requires
effective temperature in `0...1`; the compatibility message explains this
constraint and generation fails before dispatch when it is violated.

Built-in prompts remain read-only and keep all settings unset in the first
release. A later product decision may add shipped settings without changing
the storage contract.

Settings are configured in the result-prompt GUI only. The CLI preserves and
displays saved settings and applies them through `prompts run`; `prompts add`
and `prompts set` have no inference-setting flags. Transform configuration and
execution are outside this feature; repository writes reject nondefault
settings on Transform prompts.

### Generation popover

Selecting a prompt shows a compact, read-only summary when it has custom
settings, for example `Temp 0.2 · Top K 20 · Max 4096 · Thinking off`. Editing
remains in Prompt Library so the popover does not become a second settings UI.

If the selected provider cannot use one or more configured settings, show a
non-blocking compatibility note before generation. Unsupported settings are
omitted from the request; they are never reinterpreted as different settings.

### Queue and regeneration semantics

- Enqueue snapshots the prompt text, extra instructions, user notes, and
  inference settings together. Editing the prompt afterward does not alter an
  already queued run.
- Auto-run uses each prompt's own settings.
- Retry reuses the failed queue item's captured settings.
- Regenerate uses the settings snapshot stored on the existing `PromptResult`,
  while continuing to use the current meeting notes as it does today.
- A newly generated result stores the effective settings that were actually
  sent after provider/model compatibility filtering.
- Only effective settings are persisted on each result. Requested settings live
  on the mutable prompt and in the in-memory queue/retry snapshot; unsupported
  fields appear in GUI compatibility text, not per-result or CLI omission
  metadata.
- Provider/model configuration is resolved when execution begins, not captured
  at enqueue. Retry/regenerate do not promise identical provider/model replay.

## Domain model

Add a shared Core model rather than putting provider wire keys on `Prompt`:

```swift
public struct PromptInferenceSettings: Codable, Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxTokens: Int?
    public var thinkingMode: ThinkingMode
    public var reasoningEffort: ReasoningEffort?
}

public enum ThinkingMode: String, Codable, Sendable {
    case providerDefault
    case enabled
    case disabled
}

public enum ReasoningEffort: String, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh
}
```

`PromptInferenceSettings` owns range validation and exposes `isDefault`. Its
default value has all numeric fields `nil` and `thinkingMode ==
.providerDefault`; `reasoningEffort` is also `nil`. Normalization clears a
reasoning effort unless thinking is explicitly enabled, preventing a hidden or
stale effort from reaching a request.

Extend `ChatCompletionOptions` with the same transport-neutral fields. Keep
`responseFormat` separate: it is controlled by an operation such as knowledge
card generation, not by a user prompt.

Add:

```swift
public var inferenceSettings: PromptInferenceSettings?
```

to `Prompt`, and:

```swift
public var inferenceSettingsSnapshot: PromptInferenceSettings?
```

to `PromptResult` and `PendingGeneration`. Normalize `nil` and an all-default
value to `nil` before persistence.

## Persistence

Register a new, never-rewritten migration after the current `v0.30` migration:

```text
v0.31-prompt-inference-settings
```

It adds nullable JSON columns:

```sql
ALTER TABLE prompts ADD COLUMN inferenceSettings TEXT;
ALTER TABLE summaries ADD COLUMN inferenceSettingsSnapshot TEXT;
```

JSON is appropriate here because the fields are optional, are loaded with the
owning row, do not need SQL filtering, and must evolve without one migration per
provider capability. GRDB's existing Codable strategy should encode/decode the
typed struct. A malformed stored value is a visible load error; it must not be
silently replaced with defaults.

No settings belong in `llm_runs`. That table remains the metadata-only ledger;
the reproducibility snapshot belongs with the full prompt result in
`summaries`.

Update `spec/01-data-model.md`, `spec/12-processing-layer.md`, and
`spec/11-llm-integration.md` in the implementation change. If the provider
mapping is considered an architectural contract, add an ADR or amend ADR-013.

## Provider adaptation

Adapters receive transport-neutral `ChatCompletionOptions` and serialize only
supported fields. Existing model policies remain authoritative and may omit a
configured value when a model rejects it.

| Provider path | Mapping |
| --- | --- |
| Custom OpenAI-compatible, including llama.cpp | `temperature`, `top_p`, `top_k`, `max_tokens`; thinking and optional effort map to `chat_template_kwargs.enable_thinking` and `chat_template_kwargs.reasoning_effort` |
| Native Ollama | `temperature`, `top_p`, `top_k`, `num_predict` inside `options`; thinking maps to top-level `think`; reasoning effort is initially unsupported |
| Native OpenAI | `temperature` and `top_p` when model-compatible; output budget uses the adapter's existing `max_tokens` / `max_completion_tokens` policy; omit `top_k` and thinking |
| Native Anthropic | `temperature` in `0...1` or `top_p` in `0...1`, and `max_tokens` when model-compatible; Top P takes precedence over explicit or inherited temperature; omit `top_k` and thinking |
| Gemini / OpenRouter / LM Studio | Map fields explicitly supported by the existing endpoint contract; omit the rest |
| In-process MLX / local CLI | Apply only fields supported by the runtime/CLI contract; report the rest as unsupported |

For a model served through an OpenAI-compatible llama.cpp endpoint:

```json
{
  "temperature": 0.2,
  "top_p": 0.9,
  "top_k": 20,
  "max_tokens": 4096,
  "chat_template_kwargs": {
    "enable_thinking": false
  }
}
```

When thinking is enabled and an effort is configured, the custom
OpenAI-compatible mapping is:

```json
"chat_template_kwargs": {
  "enable_thinking": true,
  "reasoning_effort": "medium"
}
```

The accepted levels are endpoint- and model-template-dependent. MacParakeet
offers the common typed superset and reports the field as supported for custom
OpenAI-compatible endpoints without claiming that every endpoint implements
every value.

The neutral numeric limits are application bounds, not a guarantee that every
model accepts every output-token limit. Per-model token maxima and custom
endpoint constraints are not available from a universal capability catalog;
provider rejections remain visible errors rather than guessed limits.

Do not inject `/no_think` into prompt text. Thinking is a request/template
setting and must be represented as such.

Provider adaptation returns both the serialized request and an effective
settings value. The latter is what `PromptResult.inferenceSettingsSnapshot`
stores. This prevents a result from claiming that a setting was used when the
adapter omitted it.

For native Anthropic, setting Top P suppresses temperature, including the
inherited `0.7` default. If both are configured, Top P wins and the compatibility
message reports temperature as not applied for that provider/model and setting
combination, rather than claiming the model cannot support temperature. The
effective snapshot contains only Top P, so regeneration preserves this choice.
With Top P unset, historical temperature behavior is unchanged.

## Service and view-model flow

1. `PromptsViewModel` validates drafts; repositories independently validate
   settings and persist them only on supported prompt categories.
2. `PromptResultsViewModel.enqueueGeneration` copies them into
   `PendingGeneration`.
3. `LLMServiceProtocol.generatePromptResult*` accepts explicit
   `PromptInferenceSettings`. The throwing resolver overlays and filters them,
   validates effective provider-compatible ranges, and passes the resulting
   `ChatCompletionOptions` to `LLMClientProtocol`. Other LLM features keep their
   current options. Default protocol implementations reject nondefault settings
   instead of silently ignoring them.
4. Adapters repeat numeric validation before serialization for direct client
   callers and serialize the active provider/model's supported request fields.
5. Completion returns the effective settings alongside terminal metadata so
   `PromptResult` can snapshot them. Streaming must expose a terminal envelope
   rather than losing this metadata after yielding text. Ollama retains its
   existing lenient EOF policy: after non-empty output, an EOF without
   `done:true` emits a receipt using the last observed chunk only if no provider
   error was observed. Both stream paths decode error envelopes before content
   responses. Missing stop reason or incomplete usage remains unknown;
   no-content streams still fail. Local MLX stop reason is unknown because its
   runtime does not expose one; local CLI emits no effective-settings receipt.
   Native OpenAI streaming requests `stream_options.include_usage`; compatible
   third-party servers receive no new stream option. Missing usage totals are
   derived only from two reported component counts using checked arithmetic.
   Overflow retains the components and leaves the total unknown.

That final point is load-bearing: do not guess effective settings in the view
model, because provider/model filtering belongs in the adapter layer.

## Backward compatibility and safety

- Existing database rows decode with `nil` settings.
- Unset settings preserve historical request parameters, including the current
  `.default` temperature. Input budgeting reserves Anthropic's inherited 4096
  output tokens on initial runs and regeneration alike; near-limit transcripts
  may therefore be truncated earlier than before this correction.
- Provider-specific keys are allow-listed; arbitrary nested JSON is out of
  scope.
- Settings affect Prompt Library result generation only. They do not alter
  transcription, knowledge cards, chat, transforms, or formatter defaults.
- CLI prompt commands and built-in reconciliation preserve settings they do
  not edit. This feature adds no result-prompt export/import workflow.
- No prompt, transcript, output, API key, or request body is added to telemetry
  or `llm_runs`.
- Context-window truncation remains independent from `maxTokens`; the service
  must reserve the chosen output budget when calculating input capacity if the
  provider exposes a combined context limit.
  Native Ollama input budgeting uses the same 8,192-token window as the
  adapter's `num_ctx`, reserving any explicit output allowance. An allowance
  filling that window fails before dispatch. The character-to-token conversion
  remains a heuristic, not an exact tokenizer.

## Tests

Minimum automated coverage:

1. Model validation, Codable round-trip, default normalization, and equality.
2. Empty and upgraded database migrations; old rows decode as `nil`.
3. `PromptRepository` and `PromptResultRepository` round-trip settings.
4. Built-in reconciliation, CLI edits, and import/export preserve untouched
   settings.
5. Manual and auto-run generation snapshot settings at enqueue time.
6. Retry and regenerate use the captured/result snapshot respectively.
7. OpenAI-compatible request JSON covers every field, including explicit
   thinking and optional reasoning effort.
8. Native Ollama maps sampling fields and `think` correctly.
9. OpenAI reasoning-model tests still omit forbidden temperature and select the
   correct output-token key.
10. Unsupported fields are omitted and surfaced as compatibility information.
11. With settings unset, existing request snapshots remain unchanged.
12. Prompt Library create/edit validation and the generation-popover summary
    have focused view-model or UI tests.

During implementation, run focused LLM adapter, database migration/repository,
and prompt view-model tests. Run the full `swift test` suite once at final
verification, per repository guidance.

## Acceptance criteria

- A user can save `temperature`, `topK`, and `maxTokens` on one custom summary
  prompt without affecting another prompt.
- A user can explicitly disable thinking for an OpenAI-compatible local
  endpoint without modifying the prompt text.
- A user can select a typed reasoning effort while thinking is enabled; it is
  omitted when thinking is default or disabled.
- Manual, queued, auto-run, retry, and regenerate paths honor the documented
  snapshot semantics.
- The generated HTTP body contains only keys supported by the selected
  provider/model.
- Historical prompts and results migrate without data loss or behavior change.
- The result retains an honest snapshot of the effective settings used.
- The feature introduces no arbitrary request-body injection surface and no
  new leakage of transcript or prompt content.

## Suggested implementation slices

1. Domain model, `ChatCompletionOptions`, provider normalization, and adapter
   request tests.
2. Database migration, repository round trips, and canonical spec updates.
3. LLM service streaming terminal metadata and queue/result snapshots.
4. Prompt Library controls, validation, compatibility note, and popover summary.
5. Regression suite and one manual OpenAI-compatible llama.cpp meeting-summary test.
