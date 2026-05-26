# Issue 365 Model Availability Plan

> Status: ACTIVE
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

## Implementation

1. Add a shared `LLMModelAvailability` helper in the view-model target.
2. Expand Settings discovery from Ollama/LM Studio to every provider that has a
   documented model-list endpoint.
3. Keep provider suggestions as fallbacks only, and preserve the currently saved
   model in runtime selectors even if the latest provider list omits it.
4. Inject `LLMClientProtocol` into `PromptResultsViewModel` and
   `TranscriptChatViewModel` so the visible selectors refresh from the saved
   provider config.
5. Update `LLMClient.listModels` for Gemini to use Google's native model list
   endpoint and decode the native `models` response shape.

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

- Targeted tests for LLM client model-list URLs and view-model model-selector
  refresh behavior.
- Full `swift test` before merge.
