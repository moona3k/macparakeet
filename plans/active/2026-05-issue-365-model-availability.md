# Issue 365 Model Availability Plan

> Status: PR READY
> Started: 2026-05-26
> Issue: https://github.com/moona3k/macparakeet/issues/365
> Scope: AI provider model lists in Settings, transcript chat, and prompt results.

## Problem

Issue #365 reports that the prompt-window model selector shows MacParakeet's
hardcoded Ollama recommendations instead of the user's installed Ollama models.
The same design flaw existed beyond Ollama: Settings had partial live discovery,
but transcript chat and prompt results rebuilt their model menus from static
fallbacks only.

The clean fix is to make model availability provider-aware and shared across
runtime model selectors. Static lists should be fallback defaults, not the
primary source when a provider exposes a model-list API.

## Provider Matrix

| Provider | Model availability source | App behavior |
|---|---|---|
| Anthropic | `GET /v1/models` with `x-api-key` and `anthropic-version` | Discover when a saved key is available; fallback to curated Claude list. |
| OpenAI | `GET /v1/models` with bearer auth | Discover when a saved key is available; fallback to curated OpenAI list. |
| OpenAI-Compatible | `GET <baseURL>/models` | Discover after the user supplies an endpoint; fallback to custom model entry. |
| Gemini | Native `GET https://generativelanguage.googleapis.com/v1beta/models?key=...` for listing; OpenAI-compatible endpoint remains for chat | Discover Gemini `generateContent` models; fallback includes `gemini-3.5-flash`. |
| OpenRouter | `GET https://openrouter.ai/api/v1/models` | Discover when a saved key is available; fallback to curated OpenRouter slugs. |
| Ollama | Native `GET /api/tags`, with `/v1/models` fallback | Discover installed local models; fallback only when Ollama cannot be reached. |
| LM Studio | OpenAI-compatible `GET /v1/models` | Discover server-visible local models; fallback to custom model entry. |
| Local CLI | No provider model endpoint | Show the configured CLI display name only. |

References:

- OpenAI Models API: https://developers.openai.com/api/reference/resources/models/methods/list
- Anthropic Models API: https://docs.anthropic.com/en/api/models-list
- Gemini Models API: https://ai.google.dev/api/models#v1beta.models.list
- Gemini OpenAI compatibility: https://ai.google.dev/gemini-api/docs/openai
- OpenRouter Models API: https://openrouter.ai/docs/api/api-reference/models/get-models
- Ollama Tags API: https://docs.ollama.com/api/tags
- LM Studio OpenAI-compatible models: https://lmstudio.ai/docs/developer/openai-compat/models

## External OSS Pattern Check

Reviewed comparable open-source AI apps to check whether this should stay a
small provider-capability fix or become a broader model-registry/cache layer.

- LibreChat centralizes model discovery in one endpoint helper, uses Ollama's
  native `/api/tags` path first, then falls back to OpenAI-compatible `/models`
  when Ollama tags fail. It also uses a short cache because it is a multi-user
  web app. Reference:
  https://github.com/danny-avila/LibreChat/blob/main/packages/api/src/endpoints/models.ts
- Open WebUI exposes one `/api/models` aggregation endpoint, supports explicit
  configured model IDs before direct OpenAI-compatible fetching, and lets callers
  request refresh. Reference:
  https://github.com/open-webui/open-webui/blob/main/src/lib/apis/index.ts
- Cline refreshes OpenRouter models through one controller path and its picker
  still accepts a custom typed model ID when the list does not contain it.
  Reference:
  https://github.com/cline/cline/blob/main/apps/vscode/webview-ui/src/components/settings/OpenRouterModelPicker.tsx

Takeaway for MacParakeet: adopt a provider descriptor for stable provider facts,
native provider listing where needed, and current/custom model preservation. Do
not add a model metadata registry, search index, persistent cache, or polling
loop for this issue; those are useful in heavier web/IDE apps but unnecessary
for this small macOS settings/runtime selector path.

## Implementation

1. Add `LLMProviderDescriptor` in Core so display names, default URLs, auth
   requirements, model-list endpoint kinds, and fallback models live with each
   provider.
2. Expand Settings discovery from Ollama/LM Studio to every provider that has a
   documented model-list endpoint.
3. Keep provider suggestions as fallbacks only, and preserve the currently saved
   model in runtime selectors even if the latest provider list omits it.
4. Inject `LLMClientProtocol` into `PromptResultsViewModel` and
   `TranscriptChatViewModel` so the visible selectors refresh from the saved
   provider config.
5. Update `LLMClient.listModels` for Gemini to use Google's native model list
   endpoint and decode the native `models` response shape.
6. Keep `LLMModelAvailability` as the small picker-list shaping helper only:
   normalize provider results, fall back to descriptor models, and preserve the
   currently saved model.

## Acceptance Criteria

1. A saved Ollama config shows installed Ollama models in the prompt result
   selector after refresh, not the hardcoded fallback list.
2. Transcript chat and prompt result selectors use the same provider discovery
   policy.
3. OpenAI, Anthropic, Gemini, OpenRouter, OpenAI-compatible, LM Studio, and
   Ollama can all use provider model discovery when configured.
4. Local CLI remains display-only and does not expose a fake model list.
5. Static provider suggestions remain available when discovery cannot run yet
   or fails.
6. Existing saved custom/fine-tuned model IDs remain selectable.

## Verification

- `swift test --filter 'LLMProviderDescriptorTests|LLMClientTests|LLMSettingsViewModelTests|PromptResultsViewModelTests|TranscriptChatViewModelTests|LLMConfigCommandTests'`
  - 263 selected XCTest tests passed.
- `swift test`
  - 3003 XCTest tests passed, 9 hardware tests skipped, 0 failures.
  - 16 Swift Testing tests passed.
