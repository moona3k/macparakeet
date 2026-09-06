# Per-Prompt LLM Inference Settings — Implementation Plan

> Status: **PR OPEN** — implemented and locally verified on 2026-09-03;
> conditional reasoning effort added on 2026-09-05.

Governing draft spec:
[`spec/14-per-prompt-inference-settings.md`](../../spec/14-per-prompt-inference-settings.md)

Target branch base verified on 2026-09-03: `origin/main` at `02677ba7`

Execution environment: implementation and verification completed on an Apple
Silicon Mac with Xcode 26.6.

## Goal

Let a custom `Prompt.Category.result` carry typed inference settings, snapshot
those settings when a run is queued, filter them against the selected
provider/model, and persist the settings that were actually sent with the
result.

The implementation must preserve the exact request behavior of every existing
prompt whose settings are absent. It must not create a generic request-body
escape hatch or affect chat, Transforms, knowledge cards, the AI formatter, or
speech recognition.

## Verified Current State

- `Prompt` and `PromptResult` are GRDB `Codable` records. `Prompt` has no
  inference field; `PromptResult` snapshots prompt text, extra instructions,
  and user notes only.
- `DatabaseManager.makeMigrator()` ends at
  `v0.30-meeting-capture-report`. Built-in prompt reconciliation uses explicit
  SQL updates, so a new prompt column must remain untouched for existing
  built-ins.
- `PromptResultsViewModel.PendingGeneration` is the in-memory queue receipt.
  Manual and auto-run calls create it from a `Prompt`; retry rebuilds a
  temporary `Prompt`; regenerate rebuilds one from the stored `PromptResult`.
- Prompt-result generation always sends `ChatCompletionOptions.default`, whose
  current temperature is `0.7`.
- `LLMClientProtocol` and every adapter stream `String` tokens only. The app
  cannot currently receive terminal provider/model/usage or effective-option
  metadata from a stream. This is also the blocker already recorded in the LLM
  runs ledger plan.
- `OpenAICompatibleLLMHTTPAdapter` supports `temperature`, output-token budget,
  and response format. It already omits temperature and switches to
  `max_completion_tokens` for OpenAI reasoning models.
- Native `OllamaLLMHTTPAdapter` currently ignores `ChatCompletionOptions`,
  always sends `think: false`, and only sends `num_ctx: 8192` in `options`.
- Native Anthropic supports an allow-listed temperature and `max_tokens`; new
  or unknown Claude models intentionally omit temperature.
- `LocalCLILLMClient` ignores completion options. The developer-gated MLX path
  uses only temperature and maximum tokens.
- Context truncation is character-budget based and currently reserves no
  explicit output-token budget.
- `prompts list/show --json` encode `Prompt` directly. There is no result-prompt
  import/export bundle today; import/export in this area belongs to
  `quick-prompts`, not `prompts`.

## Context Zone

### In scope

- Custom result-prompt create/edit settings.
- Typed validation and default normalization.
- Queue, retry, regenerate, CLI-run, repository, and migration behavior.
- Provider/model capability filtering and an honest effective-settings receipt.
- A compact selected-prompt summary and non-blocking compatibility message.
- Public documentation changes caused by additive CLI JSON fields.

### Must not change

- A prompt with no settings must produce the same request as it does before
  this feature, including the current `0.7` prompt-result temperature and
  native Ollama's current `think: false` behavior.
- Built-in prompts remain read-only and store no shipped settings in v1.
- Editing a prompt after enqueue must not alter a queued or failed run.
- Regenerate uses current transcript/notes but the result's stored inference
  receipt, matching the proposal's snapshot rule.
- Unsupported values are omitted, never translated into another parameter.
- `responseFormat` remains operation-owned.
- No prompt, transcript, response, API key, or request body enters telemetry or
  `llm_runs`.
- Existing summaries are never rewritten or deleted by migration.

### Out of scope

- Arbitrary provider JSON.
- Global/provider-wide presets.
- Settings for Ask/chat, Transforms, formatter, cards, title generation, or STT.
- A new result-prompt bundle import/export feature.
- Recording prompt-result calls into `llm_runs`; the terminal envelope should
  make that possible later, but this feature does not add those ledger rows.
- Changing the public/default status of the developer-gated MLX runtime.

## Decision Gate 0 — Correct the Default Semantics (Accepted)

The draft labels blank numeric values and `thinkingMode.providerDefault` as
“Provider default”. That cannot preserve current behavior with the proposed
optional model:

- Prompt results currently pass application default `temperature = 0.7`.
- Native Ollama currently sends `think: false` explicitly.
- Normalizing an all-default struct to `nil` removes any way to distinguish
  “inherit MacParakeet's historical behavior” from “omit this key and let the
  provider decide”.

Accepted v1 decision:

1. Call the blank state **MacParakeet default** (or simply **Default**) in UI.
2. Define `nil` per-prompt settings as “inherit the operation's current
   `ChatCompletionOptions.default` and adapter defaults”.
3. Define an unset numeric field inside a custom settings object the same way:
   it inherits the current operation value; it does not force omission.
4. Define `thinkingMode.providerDefault` as “keep current adapter behavior”.
   For native Ollama this remains `think: false`; for an OpenAI-compatible
   endpoint it means no `chat_template_kwargs` key.
5. If true raw-provider-default control is required, revise the domain model to
   represent three states per field (`inheritApplication`, `providerDefault`,
   `value`) before implementation. Do not overload `nil`.

The recommended decision keeps the promised zero-regression path and avoids a
larger persistence/UI model. Update the source proposal wording before the
feature PR is declared ready.

## Proposed Design

### Domain and validation

Add `PromptInferenceSettings.swift` in `MacParakeetCore/Models` with:

- `PromptInferenceSettings`: optional numeric fields plus `ThinkingMode`.
- A throwing validation/normalization API used by both GUI and CLI-facing
  construction paths.
- `isDefault` and `normalized` (`nil` for the all-default value).
- Field-specific validation failures so `PromptsViewModel` can map them to UI
  controls without parsing strings.

Use the proposal's limits: temperature `0...2`, top-p `0...1`, top-k
`0...1000`, and maximum tokens `1...131072`. Validate
non-finite floating-point values explicitly; `NaN` and infinity must fail.

Extend `Prompt` with `inferenceSettings` and `PromptResult` with
`inferenceSettingsSnapshot`. Keep the database column names explicit in each
record's `Columns` enum.

Extend `ChatCompletionOptions` with transport-neutral `topP`, `topK`,
`thinkingMode`, and optional `reasoningEffort`. Keep an explicit merge function
that overlays prompt
settings on `.default`; do not spread fallback rules across call sites.

### Capability resolution

Create one pure provider/model resolver in Core. Its input is
`LLMProviderConfig`, the operation baseline, and the optional prompt settings;
its output contains:

- the filtered options to serialize;
- normalized effective `PromptInferenceSettings`;
- a stable set of **explicitly configured** unsupported setting identifiers
  for UI copy/tests.

Both request builders and compatibility UI must consume this resolver. The UI
must never maintain a second provider support table.

Initial capability policy:

- OpenAI native: temperature/top-p only when model policy allows them; output
  budget through existing token-key selection; omit top-k and thinking.
- Anthropic native: max-tokens is always supported; temperature/top-p depend
  on the current model's sampling policy. The implemented adapter gives top-p
  precedence: when it is set, omit temperature, including inherited temperature.
  Omit top-k and thinking.
- Ollama native: temperature/top-p/top-k/num-predict in `options`, plus
  top-level `think` when explicitly enabled/disabled; retain `num_ctx`.
- Custom OpenAI-compatible: temperature/top-p/top-k/max-tokens plus
  `chat_template_kwargs.enable_thinking` and optional nested
  `reasoning_effort`. Keep this scoped to the custom
  endpoint path; do not send non-standard keys to OpenAI, Gemini, OpenRouter,
  or LM Studio without an explicit tested capability.
- Gemini, OpenRouter, and LM Studio: start from only the fields already proven
  by their existing endpoint tests, then add provider-specific fields one by
  one. Unknown support means omit and report.
- Local CLI: report every new prompt setting unsupported in v1 rather than
  silently pretending the CLI received it.
- In-process MLX: temperature and max tokens only until its runtime contract is
  deliberately expanded.

The resolver must preserve existing adapter policy such as OpenAI reasoning
model temperature omission and Anthropic's allow-list.

### Honest streaming receipt

Add a detailed streaming API while retaining source-compatible text-streaming
projections for chat, Transforms, and existing callers:

```swift
public enum LLMStreamEvent: Sendable {
    case text(String)
    case completed(LLMStreamTerminal)
}
```

`LLMStreamTerminal` should carry provider, model, usage/stop reason when the
transport exposes them, and the resolved effective inference settings. Each
adapter emits exactly one terminal event after validating its completion
sentinel. EOF/error/cancellation emits no successful terminal event.

The non-streaming path must carry the same receipt on
`ChatCompletionResponse`, then project it as an optional additive field on
`LLMResult`. This lets `prompts run --json` and non-streaming result persistence
use the adapter's receipt instead of recomputing it. Document and snapshot-test
the additive public JSON field.

Add `generatePromptResultDetailedStream(...)` to `LLMServiceProtocol` and keep
`generatePromptResultStream(...)` as a projection for compatibility. The
prompt-results queue consumes the detailed stream, appends `.text`, and refuses
to persist success without `.completed`.

Do not infer effective settings in `PromptResultsViewModel`. The same resolver
used by the adapter stamps the terminal receipt, so stored settings cannot
claim a key that request serialization omitted.

### Persistence and queue receipts

Register `v0.31-prompt-inference-settings` after v0.30:

```sql
ALTER TABLE prompts ADD COLUMN inferenceSettings TEXT;
ALTER TABLE summaries ADD COLUMN inferenceSettingsSnapshot TEXT;
```

Use nullable GRDB-Codable JSON. A malformed non-null value remains a visible
decode/load error. Add migration guards only if the repository's historical
partial-migration tests require them; never edit older migrations.

Add the settings snapshot to `PendingGeneration`. Populate it at enqueue and
copy it directly on retry. For regenerate, construct the pending item from
`PromptResult.inferenceSettingsSnapshot`; do not look up the current prompt.
After completion, persist the terminal's effective settings, not the requested
snapshot.

For `prompts run`, pass the saved prompt settings through both streaming and
non-streaming paths and store the effective receipt when saving a result. If
the chosen path cannot produce an honest receipt, it must not claim one.

### Context budgeting

Thread the chosen output budget into `buildPromptResultMessages`. Convert the
output-token reservation to the same conservative character unit used by the
existing context budget, cap it at the provider budget, and fail clearly when
the requested output leaves no viable input space. Add boundary tests for a
small local/LM Studio context and a large `maxTokens` value.

This remains prompt-result-only. Do not change truncation for other LLM
operations.

### Prompt Library UI

Introduce a small value-type draft for the six fields rather than loosely
coupled strings in `PromptLibraryView`.

- Create/edit sheets get a collapsed `DisclosureGroup("Generation settings")`.
- Numeric fields preserve blank as unset and validate on save.
- Validation is field-addressable; the general error banner remains for
  repository failures.
- “Reset to defaults” clears the draft.
- Built-in rows stay read-only and do not show editable controls.
- The generation popover renders one compact summary below the selected chip
  only when settings are non-default.
- Compatibility copy comes from the Core resolver using the active
  provider/model. It is informative, non-blocking, and contains parameter
  names only—never prompt or transcript content.

Because `PromptLibraryView` currently owns edit draft state while
`PromptsViewModel` owns create fields, first move both create/edit settings
drafts and validation into `PromptsViewModel`; keep SwiftUI limited to binding
and presentation.

## Implementation Slices

### Slice 1 — Domain contract and capability matrix

Files likely touched:

- `Sources/MacParakeetCore/Models/PromptInferenceSettings.swift` (new)
- `Sources/MacParakeetCore/Models/Prompt.swift`
- `Sources/MacParakeetCore/Models/PromptResult.swift`
- `Sources/MacParakeetCore/Models/LLMTypes.swift`
- provider capability resolver (new Core file)
- focused model/resolver tests

Deliverable: validated settings and one authoritative requested-to-effective
mapping, with legacy defaults pinned by tests. No persistence or UI yet.

### Slice 2 — Adapter serialization and detailed terminal streams

Files likely touched:

- `LLMClient.swift`, `RoutingLLMClient.swift`, `LLMService.swift`
- `OpenAICompatibleLLMHTTPAdapter.swift`
- `OllamaLLMHTTPAdapter.swift`
- `AnthropicLLMHTTPAdapter.swift`
- `LocalCLILLMClient.swift`, `InProcessLLMClient.swift`
- `LLMTypes.swift` or a dedicated stream-envelope model
- LLM adapter/client/service tests and mocks

Deliverable: requests contain only supported fields; successful streams return
one honest terminal receipt; existing text-streaming APIs behave unchanged.

### Slice 3 — Migration, records, repositories, and reconciliation

Files likely touched:

- `DatabaseManager.swift`
- `Prompt.swift`, `PromptResult.swift`
- `PromptRepositoryTests.swift`, `PromptResultRepositoryTests.swift`
- `DatabaseManagerTests.swift`

Deliverable: empty and upgraded databases expose nullable JSON columns; legacy
rows decode as nil; round trips and malformed JSON behavior are proven;
built-in reconciliation preserves stored inference settings it does not own.

### Slice 4 — Queue, retry, regenerate, and CLI run

Files likely touched:

- `PromptResultsViewModel.swift`
- `PromptsCommand.swift`
- protocol mocks and prompt-result/CLI tests
- `Sources/CLI/CHANGELOG.md`, `integrations/README.md`, and
  `spec/contracts/cli-json-v1.md` if JSON shapes change

Deliverable: enqueue is the requested-settings snapshot boundary; retry and
regenerate obey their distinct rules; GUI and CLI persist the effective
receipt.

### Slice 5 — Prompt Library and generation popover

Files likely touched:

- `PromptsViewModel.swift`
- `PromptLibraryView.swift`
- `TranscriptResultView.swift`
- focused view-model tests and small view helper tests where practical

Deliverable: custom prompt create/edit/reset, field errors, read-only summary,
and compatibility note. No second settings editor in the popover.

### Slice 6 — Governing documentation and final convergence

Update in the same feature PR:

- `spec/01-data-model.md`
- `spec/11-llm-integration.md`
- `spec/12-processing-layer.md`
- ADR-013 with a dated amendment for per-prompt settings, snapshot semantics,
  and the adapter-owned effective receipt
- public CLI docs/changelog for additive JSON fields
- this plan's status after implementation

Do not add a new ADR unless the terminal stream envelope becomes a broader
public architecture decision than the ADR-013 amendment can explain cleanly.

## Focused Test Matrix

### Domain

- Boundary values and one-beyond-boundary failures for all numeric fields.
- Reject `NaN`, positive infinity, and negative infinity.
- Codable round trip, equality, `isDefault`, and normalization.
- Overlay on `.default` proves absent settings preserve current requests.

### Database

- Empty database contains both v0.31 columns.
- A file-backed v0.30 fixture upgrades without modifying existing rows.
- Prompt and result repositories round-trip every field and nil.
- Malformed JSON fails visibly.
- Built-in reconciliation preserves settings and custom prompt rows.

### Providers

- Custom OpenAI-compatible JSON covers all supported keys, explicit thinking,
  and optional reasoning effort without changing prompt text.
- Native Ollama maps options and explicit thinking while retaining `num_ctx`.
- OpenAI reasoning models omit forbidden temperature/top-p as required and use
  the correct output-token key.
- Anthropic allow-listed and unknown-model cases.
- Gemini/OpenRouter/LM Studio do not receive unproven non-standard keys.
- Local CLI and MLX report an accurate unsupported subset.
- With no settings, existing request snapshots remain byte-for-byte equal.
- Stream success has one terminal event; truncated/error/cancelled streams have
  none.

### Workflow

- Manual and every auto-run prompt snapshot settings at enqueue.
- Editing the prompt after enqueue changes neither queued nor failed retry.
- Retry reuses the failed requested snapshot.
- Regenerate uses the prior result's effective snapshot plus current notes.
- Persistence happens only after a terminal receipt and durable replace keeps
  the previous result on failure.
- Output-token reservation changes only prompt-result input truncation.
- CLI run uses/saves effective settings in stream and non-stream modes.

### UI

- Blank fields remain nil; zero stays zero where valid.
- Create/edit validation maps to the correct field and does not persist.
- Reset clears every value.
- Built-ins cannot acquire settings through the UI.
- Compact summary ordering is stable.
- Compatibility note updates when selected prompt/provider/model changes.

## Verification Sequence

Run implementation verification from the Mac worktree that owns the branch.
During implementation, iterate only with focused filters, for example:

```bash
swift test --filter PromptInferenceSettingsTests
swift test --filter LLMHTTPAdapterTests
swift test --filter LLMClientTests
swift test --filter LLMServicePromptTests
swift test --filter DatabaseManagerTests
swift test --filter PromptRepositoryTests
swift test --filter PromptResultRepositoryTests
swift test --filter PromptResultsViewModelTests
swift test --filter PromptsViewModelTests
swift test --filter PromptsCommandTests
```

Then run formatting/lint and the full `swift test` suite exactly once as the
final local gate, per repository guidance. Because this is a substantial
schema/public-surface change, use the documented PR review workflow and
`no-mistakes` gate when implementation is ready.

## Acceptance Checklist

- [x] Decision Gate 0 wording/model is accepted and reflected in the proposal.
- [x] One custom prompt can set temperature, top-k, and max tokens without
      affecting any other prompt.
- [x] Thinking can be disabled on a custom OpenAI-compatible endpoint
      without prompt-text injection.
- [x] A custom OpenAI-compatible endpoint can receive a typed reasoning effort
      only while thinking is enabled.
- [x] Existing unset prompts produce unchanged requests on every provider path.
- [x] Queue, retry, regenerate, auto-run, and CLI run follow the documented
      snapshot semantics.
- [x] Unsupported keys are omitted and reported non-blockingly.
- [x] Stored results contain only settings actually sent.
- [x] v0.31 migration preserves all historical prompt/result data.
- [x] No content or credentials are added to telemetry or `llm_runs`.
- [x] Focused tests, final full suite, lint, and substantial-change review
      converge.

## Main Risks

1. **Silent default regression.** Mitigate with pre-change request snapshots and
   explicit overlay tests before adding new fields.
2. **False effective receipt.** Mitigate by stamping the receipt at the same
   resolver/adapter boundary that serializes the request and requiring a
   successful terminal stream event.
3. **Protocol blast radius.** Add detailed stream APIs as additive projections;
   do not force chat/Transforms UI rewrites into this feature.
4. **Provider drift.** Use conservative allow-lists and treat unknown as
   unsupported.
5. **Context starvation.** Bound output reservation and fail before sending a
   request that leaves no usable input budget.
6. **Public JSON drift.** Treat new `Prompt`/`PromptResult` fields as additive
   CLI contract changes and document/test them.
