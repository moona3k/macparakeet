# Per-Prompt LLM Inference Settings

> Status: **IMPLEMENTED / PR OPEN** — the default-semantics
> decision and conditional reasoning-effort extension are accepted in
> [`plans/active/2026-09-03-per-prompt-inference-settings.md`](../plans/active/2026-09-03-per-prompt-inference-settings.md).
>
> **2026-09-05 amendment:** Settings now apply uniformly to built-in and custom
> result/Transform prompts and are owned by the active immutable prompt version,
> alongside prompt content and an optional model override. The provider remains
> global. Historical result snapshots remain unchanged.

Target: MacParakeet

Scope: Prompt Library result and Transform prompts

## Outcome

A Prompt Library prompt can carry its own generation settings. Manual,
queued, auto-run, retry, and regenerate flows use the settings captured for
that run. Existing prompts continue to behave exactly as they do today.

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
Validation happens before save and shows a field-level error. Blank means
unset; blank is not converted into zero.

Built-in provenance does not restrict these controls. Built-in and user-created
prompts use the same validation, version creation, reset, and execution paths.
Clearing every override means inherit MacParakeet defaults.

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

The first implementation added:

```swift
public var inferenceSettings: PromptInferenceSettings?
```

to `Prompt`. The versioning amendment moves that property to the resolved
active `PromptVersion`; the public resolved `Prompt` value may continue exposing
it so callers do not perform database joins. Add:

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

The later prompt-version migration copies `prompts.inferenceSettings` into each
prompt's version 1. `prompt_versions.inferenceSettings` then becomes the sole
long-term writable source. The old prompt-row column may survive a bounded
compatibility window but is not a permanent cache or dual-write target.

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
| Native Anthropic | `temperature` or `top_p`, and `max_tokens` when model-compatible; Top P takes precedence over explicit or inherited temperature; omit `top_k` and thinking |
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

Do not inject `/no_think` into prompt text. Thinking is a request/template
setting and must be represented as such.

Provider adaptation returns both the serialized request and an effective
settings value. The latter is what `PromptResult.inferenceSettingsSnapshot`
stores. This prevents a result from claiming that a setting was used when the
adapter omitted it.

For native Anthropic, setting Top P suppresses temperature, including the
inherited `0.7` default. If both are configured, Top P wins and temperature is
reported as unsupported for that combination. The effective snapshot contains
only Top P, so regeneration preserves this choice. With Top P unset, historical
temperature behavior is unchanged.

## Service and view-model flow

1. `PromptsViewModel` validates and persists the optional settings with the
   custom prompt.
2. `PromptResultsViewModel.enqueueGeneration` copies them into
   `PendingGeneration`.
3. `LLMServiceProtocol.generatePromptResult*` accepts explicit
   `ChatCompletionOptions` and passes them to `LLMClientProtocol`; other LLM
   features keep their current options.
4. The selected adapter normalizes settings for the active provider/model and
   serializes the request.
5. Completion returns the effective settings alongside terminal metadata so
   `PromptResult` can snapshot them. Streaming must expose a terminal envelope
   rather than losing this metadata after yielding text. Ollama retains its
   existing lenient EOF policy: after non-empty output, an EOF without
   `done:true` emits a receipt using the last observed chunk. Missing stop
   reason or missing usage components remain unknown; no-content streams still fail. An
   explicit provider error always fails the stream, including after partial
   output; it never produces a successful terminal receipt.

Legacy `LLMServiceProtocol` conformers can keep the default detailed methods
for nil/default settings. A normalized non-default override is rejected before
legacy dispatch unless the conformer implements the settings-aware method;
defaults must never silently ignore an explicit override. Legacy terminal
provider/model identifiers remain unknown instead of being invented.

Native OpenAI streaming requests opt into the terminal usage chunk; compatible
third-party endpoints keep their existing request shape. A missing total is
derived only when both input and output counts are available and their sum
is representable. Overflow leaves the total unknown without discarding either
component or failing generation. In-process
runtimes without an actual finish reason leave it unknown, and Local CLI
receipts omit inference settings because the command does not apply them.

Prompt-result input budgeting reserves the effective output limit in both
streaming and non-streaming paths, including Anthropic's inherited 4096-token
limit. A reservation leaving no input room fails before dispatch and emits the
same failure telemetry in both paths.

That final point is load-bearing: do not guess effective settings in the view
model, because provider/model filtering belongs in the adapter layer.

## Backward compatibility and safety

- Existing database rows decode with `nil` settings.
- Existing prompt-result behavior is byte-for-byte unchanged when settings are
  unset, including the current `.default` temperature.
- Provider-specific keys are allow-listed; arbitrary nested JSON is out of
  scope.
- Settings affect Prompt Library result generation only. They do not alter
  transcription, knowledge cards, chat, transforms, or formatter defaults.
- Prompt exports/imports, CLI prompt commands, and built-in reconciliation must
  preserve settings they do not edit.
- No prompt, transcript, output, API key, or request body is added to telemetry
  or `llm_runs`.
- Context-window truncation remains independent from `maxTokens`; the service
  must reserve the chosen output budget when calculating input capacity if the
  provider exposes a combined context limit.

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

### Ollama prompt-result context budget

Native Ollama prompt results use the same 8,192-token context window configured
by the HTTP adapter (`num_ctx`) in both streaming and non-streaming paths. Input
assembly uses the existing 3.5-character-per-token estimate and reserves the
effective requested output allowance first. An output allowance that fills the
window is rejected before dispatch. This is a character estimate, not tokenizer
accounting; other providers retain their existing budgets. See the
[Ollama parameter reference](https://docs.ollama.com/modelfile#valid-parameters-and-values).
