# Generation settings: compatibility and UX review

Reviewed 2026-09-08 against main `75d75e5ab313e9a5a9693d1e2b171ba90b9d328d`. Review only; no production code or user settings changed. Evidence is source inspection, existing test inspection and current official provider documentation; no paid API requests or new runtime tests were run.

## Verdict

The optional override model and runtime capability resolver are useful foundations. The editor does not currently communicate the actual support or defaults of the effective provider/model. Treat this as a compatibility and clarity fix before the release, rather than adding more generic fields.

A robust interface cannot promise all present and future models support the same knobs. It should distinguish supported, unsupported and unknown capabilities, inherit safe defaults, and accurately report what will be sent.

## Findings

1. **The form has no effective provider/model context.** `GenerationSettingsEditor` in `Sources/MacParakeet/Views/Transcription/PromptLibraryView.swift:1408` receives draft values, a model string and generic errors. It renders every sampling control and Thinking for every provider. The draft validates generic ranges, not the selected model's limits or cross-parameter restrictions.
2. **Visible controls exceed integration support.** `PromptInferenceCapabilityResolver.supportedFields` in `Sources/MacParakeetCore/Models/PromptInferenceSettings.swift` filters thinking/effort for direct OpenAI, Anthropic and Gemini. Custom OpenAI-compatible endpoints get a broad support set and encode thinking through `chat_template_kwargs`; this is not universal reasoning support. Ollama supports a thinking switch in this integration but effort is filtered. Selecting a control is not evidence it will reach the model.
3. **Defaults have multiple meanings.** `ChatCompletionOptions.default` in `Sources/MacParakeetCore/Models/LLMTypes.swift:186` supplies temperature 0.7. Anthropic defaults max_tokens to 4096 in its adapter; the resolver gives Ollama legacy behavior with thinking disabled and omitted sampling. Empty fields therefore do not uniformly mean provider default. The form exposes ranges, not effective values or their source. The configured default Gemini model is gemini-3.5-flash, which inherits the app's 0.7 sampling baseline on ordinary prompt generation.
4. **Model rules are uneven.** The OpenAI policy conservatively omits sampling for GPT-5-and-later non-chat names; it does not represent mode-dependent exceptions. The Anthropic legacy allow-list protects newer direct models from unsupported sampling. That protection does not automatically apply to the same model behind OpenRouter or an arbitrary OpenAI-compatible endpoint. Provider routing and endpoint implementation matter as well as the model name.
5. **Compatibility feedback uses the wrong model when an override exists.** `PromptResultsViewModel.selectedPromptInferenceCompatibilityMessage` loads the global config without applying the selected prompt's model override. `LLMService.generatePromptResultDetailed` applies the override before resolving options. The warning and actual request can disagree. The prompt editor itself does not display this compatibility feedback.
6. **Numeric bounds are application-wide bounds, not model guarantees.** Temperature 0–2 is inaccurate for sampling-capable Anthropic models, whose sent temperature is checked at 0–1 downstream. The universal output-token limit does not describe individual model ceilings. On OpenAI reasoning models, the existing adapter uses max_completion_tokens, which budgets reasoning as well as visible output; the UI label should explain that where relevant.
7. **Model override is unnecessarily opaque.** Settings already offers a model list and custom-ID escape hatch; prompt editing only provides a free-text ID. Provider changes can leave an incompatible saved model override. Re-evaluate compatibility whenever the provider, endpoint, model or reasoning selection changes, without silently replacing saved intent.

## Current official guidance

- [OpenAI GPT-5.2 parameter compatibility](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.2): temperature/top_p support depends on reasoning effort. This demonstrates why a provider-wide boolean or a model-name prefix alone is insufficient.
- [Claude thinking compatibility](https://platform.claude.com/docs/en/build-with-claude/thinking): newer listed models reject non-default sampling values; older models have additional restrictions while thinking. Effort and thinking support vary by model.
- [Gemini 3.x parameter guidance](https://ai.google.dev/gemini-api/docs/whats-new-gemini-3.5): Google recommends omitting sampling overrides and using supported thinking levels. This is a recommendation, not proof that every custom temperature request fails.
- [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai): reasoning can be represented through the compatibility API, but accepted levels depend on the Gemini model. The current app adapter does not implement those controls.
- [OpenRouter model metadata](https://openrouter.ai/docs/guides/overview/models): supported_parameters and default_parameters can supply useful provider metadata. They are not a universal discovery mechanism for arbitrary endpoints or a guarantee about every routing choice. [Routing parameter requirements](https://openrouter.ai/docs/guides/routing/provider-selection) also matter.

## Recommended UX

Keep Generation settings collapsed by default. Its collapsed summary should say **Uses AI settings** or **3 overrides**, rather than an unexplained Custom marker alone.

When expanded:

- **Model:** default to **Use AI settings**, followed by the actual provider and model. Offer **Choose another model…** using the existing model-list/custom-ID pattern. Do not require typing a model ID for the common case.
- **Reasoning:** show **Automatic** and only the modes/levels implemented and supported for the effective model. Do not offer Disabled when the model requires reasoning; do not invent a mapping from High to token budgets across providers. If the integration cannot control reasoning, say it is model-managed rather than showing a working-looking switch.
- **Response limit:** offer **Automatic** or **Custom**, with a validated numeric control and known model limit. Explain when the budget includes reasoning. Do not present an unknown limit as a precise guaranteed maximum.
- **Sampling:** keep Temperature, Top P and Top K in a secondary advanced section, only where supported. Explain conflicts before save. For Gemini 3, keep the recommended automatic state prominent; supported-but-discouraged differs from unsupported.
- **Inheritance:** show effective values as secondary read-only text where known, such as **Inherited from AI settings**, **App default: 4096**, or **Model default**. Never invent an exact default if the provider has not supplied it. Opening/saving the editor must not turn inherited values into explicit overrides.
- **Reset:** use **Use defaults** to clear explicit overrides. Keep unavailable existing values visible with a concise explanation and a remove action, so switching providers does not invisibly destroy them.
- **Unknown/custom endpoints:** preserve manual configuration for power users but mark capabilities unverified. Do not assume every OpenAI-shaped endpoint accepts top_k or chat_template_kwargs. Omit optional knobs by default and provide actionable errors for rejected explicit overrides; no silent retry that changes the requested behavior.

Example presentation (illustrative, not a claim about current global settings):

    Generation settings                 Uses AI settings
    Model             Use AI settings
                      Google Gemini · gemini-3.5-flash
    Reasoning         Automatic
    Response limit    Automatic
    Sampling          Model defaults (recommended)
                      Customize…

Numeric inheritance is not a request for another new global settings layer. Settings currently manages provider/model/connection configuration, not a parallel numeric generation-settings form. Reuse its model selection behavior and keep the existing prompt-level override ownership.

## Simple implementation boundary

Extend the existing capability resolver with the small amount of metadata the editor needs: support state, permitted values/ranges, known effective defaults and a short reason. Use the same resolved effective provider/model in UI validation and request serialization. Keep provider-specific wire mapping in the existing adapters. Do not build a plugin framework, giant speculative model catalog, or automatic paid probing system.

The CLI should consume the same capability/validation contract and distinguish requested from effective settings. Preserve existing stored overrides and historical generation receipts; do not rewrite them while changing the editor. A provider-default baseline change for new generations is a behavior change that deserves explicit tests and documentation.

For the release, prioritize truthful UI support, the model-override warning mismatch, and known request/default compatibility. Native reasoning controls that are not currently implemented can remain unavailable with clear explanation; adding every provider's advanced features is separate work.

## Verification needed for implementation

- Unsupported fields omitted for direct providers and handled explicitly for compatible/router endpoints.
- Valid combinations across legacy sampling models, modern reasoning models, and thinking modes.
- Gemini automatic requests do not inject an unintended sampling override.
- Editor-open/save preserves nil inheritance; customization and reset change only the intended overrides.
- Compatibility preview applies prompt model overrides and updates after provider/model changes.
- Existing incompatible settings survive provider switching and remain discoverable/removable.
- Actual request serialization and effective receipts match the UI, including CLI paths.
- Unknown endpoint/model behavior is conservative and explicit; existing offline/manual model entry continues working.

Existing resolver and HTTP adapter tests cover several legacy safeguards, but they do not establish all-model compatibility or correctness of this proposed UI.
