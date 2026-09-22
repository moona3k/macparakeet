# Model-aware generation settings

Status: implemented; focused verification passed. [PR #991](https://github.com/moona3k/macparakeet/pull/991) records final CI, review and merge evidence. Base: main `75d75e5ab313e9a5a9693d1e2b171ba90b9d328d`. Integrated concurrent gateway-policy main `6e421dbbab09bdaaa9c37d7097fb0f4d023919e7` before completing implementation. Review evidence: [generation-settings audit](../audits/2026-09-08-generation-settings-review.md).

## Problem and intended behavior

The prompt editor currently exposes every sampling/thinking control without knowing the effective provider and model. Generic validation accepts some values that fail at dispatch, other settings are filtered without edit-time explanation, and compatibility warnings ignore prompt model overrides. Blank fields conceal whether defaults come from the app or provider.

The editor must show the effective provider/model, distinguish inherited settings from explicit overrides, and distinguish verified controls from explicit, unverified custom-endpoint settings. UI validation, compatibility feedback and dispatch must use the existing capability resolver consistently.

## Scope and invariants

- One focused PR. Extend existing resolver/adapters/managers; no new settings framework, speculative model catalog, database migration, or global numeric settings layer.
- Keep Transforms UI self-contained and unchanged. Shared execution fixes may apply where existing shared logic is used.
- Preserve stored fields, technical category names, existing CLI flags/JSON shapes and historical generation receipts. Opening/saving an untouched editor must not materialize inherited numbers as explicit overrides.
- No user database or credential mutation during automated QA; use fixtures and mocked transports. No paid generation probes. Model-list discovery uses only the existing configured-provider integration, as Settings already does.
- Provider default means omitting the optional parameter; if the app supplies a value, identify it as an app default. Never display an unknown provider default or output ceiling as an exact known number.
- Native reasoning features not implemented by an adapter stay unavailable. Do not add native reasoning integrations in this PR or map effort levels to invented universal token budgets.

## Implementation contract

1. Resolve saved provider/endpoint plus prompt model override before deriving capabilities, validation or compatibility feedback. Fix the existing result-screen warning to use that same effective model. Reevaluate draft presentation when its model changes and refresh provider configuration when the editor opens.
2. Extend `PromptInferenceCapabilityResolver` with minimal reusable presentation information: supported fields, known restrictions/ranges, inherited effective values and explanations. Keep actual request mapping in adapters. Represent unknown/custom endpoint capabilities honestly without deleting existing manually configured settings or pretending arbitrary OpenAI-compatible servers have identical features.
3. Replace the raw default model field with **Use AI settings** plus the actual provider/model. Reuse the existing Settings model-list/custom-ID pattern and loading services. Preserve custom IDs if discovery is unavailable; loading errors do not invalidate manual entry. Bound asynchronous work and prevent stale model-list responses from replacing a newer provider's options.
4. Keep Generation settings collapsed by default with an inheritance/override summary. Expanded controls use **Automatic** versus **Custom** where appropriate; inherited values are secondary read-only information. Supported controls are editable; existing custom-endpoint controls remain editable with an unverified, sent-as-requested explanation. Preserve saved unavailable fields in an explained inactive section with explicit removal. Clearly explain incompatible combinations before saving (including Anthropic Top P taking precedence over Temperature).
5. Label known values and bounds accurately. Response limits can include reasoning tokens for applicable OpenAI models. Supported-but-discouraged Gemini sampling is different from unsupported sampling. No exact model limit is invented when unavailable.
6. Correct Gemini 3 inherited sampling: ordinary inherited prompt-generation requests must not inject the app's legacy temperature 0.7. An explicit saved override remains explicit; historical receipts are not rewritten. Audit receipt-based regeneration so previously recorded settings retain their meaning.
7. Reuse the same validation/capability authority in CLI execution; document changed default behavior and leave public schemas/flags intact. Update governing UI and CLI contracts deliberately. This review does not authorize new CLI commands or a separate provider-capability discovery service.

## Acceptance evidence

- Known direct-provider unsupported fields stay out of actual payloads; custom-compatible support remains available with truthful uncertainty.
- Gemini 3 automatic sampling is omitted; explicit overrides and recorded historical values remain explicit.
- Provider/model-specific validation prevents known invalid values and explains combination precedence before save.
- Blank/open/save/reset preserve inheritance; editing one field does not freeze other defaults.
- Saved unsupported overrides survive model/provider changes and can be removed intentionally.
- Model overrides drive both presentation and result-screen compatibility feedback.
- Model-list errors, unavailable configuration and stale asynchronous responses have defined conservative UI behavior.
- GUI/CLI requests and effective-setting receipts agree; persisted format remains compatible.
- Focused resolver, adapter, view-model and CLI regression tests; independent correctness/maintainability review and PR checks. Full suite at most once locally; prefer the CI full-suite gate to avoid duplicating expensive simulations.
- Release app builds and normal dev restart after merge, then user visual QA. Never force quit or discard unsaved user work.

## Shipping

Branch from origin/main, commit plan/spec/implementation together, open a real PR, resolve actionable review findings, and merge only the exact reviewed passing head. User authorized implementation, PR and merge. No public app release publication in this task.

## Implementation verification

- Normal-dependency focused `swift test` run: 469 XCTest cases passed, zero
  failures. Coverage includes resolver and HTTP payloads, prompt and result
  view models, model-selection intent, and public CLI prompt commands.
- Independent Grok/Cursor Core and UI reviews reached LGTM after fixing custom
  model selection from an empty override, override-only warning visibility,
  action styling, and repeated unverified-endpoint help.
- No storage/CLI schema changes, paid provider probes or user-data mutations.
  Full-suite CI and the release app build remain the final shipping gates.
