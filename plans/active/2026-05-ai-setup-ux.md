# AI Setup UX Plan

> Status: **ACTIVE PLAN**
> Drafted: 2026-05-02
> Updated: 2026-05-26 -- baked-in LLM research and AI setup friendliness pass
> ADR: `spec/adr/011-llm-cloud-and-local-providers.md`
> Related history: `spec/adr/008-local-llm-runtime-and-model.md`
> Scope: AI setup for summaries, transcript chat, prompt actions, and meeting Ask. Speech-to-text is unchanged.

## 1. Decision

Keep the stable product on the ADR-011 model: MacParakeet does not bundle a local LLM runtime or model in the app. Users can bring a local AI app, an API key, or a command-line AI tool.

The 2026-05-26 baked-in LLM research pass keeps that decision intact for app-bundled weights/runtimes. The only credible "baked in" exception is a future Apple Foundation Models provider, because the OS owns the model and runtime. That exception still needs an ADR-011 amendment before implementation, and it should be explicit user setup rather than a silent default.

The product work is to make that setup feel first-class and low-friction:

1. LM Studio is the recommended local path.
2. Ollama is the secondary local path.
3. API-key providers remain available for users who prefer cloud AI.
4. Local CLI stays available for advanced users and agent workflows.
5. Feature surfaces do not show provider plumbing once AI is configured.

This gives users a clean path to local summaries and chat without reopening the bundled-MLX decision that was already tried and removed.

The user-facing stance is:

> Install MacParakeet and capture works immediately. Turn on AI only when you
> want summaries, chat, prompt actions, or meeting Ask.

The product gap is not that MacParakeet has a uniquely bad architecture. Most
open-source Granola alternatives also require a separate LLM choice after app
install. The gap is that MacParakeet should explain this choice more plainly
and make the common local paths feel native.

Reference: `docs/research/apple-foundation-models.md`.

## 2. Research Baseline

Char/Hyprnote's public local-LLM path is provider-based, not a simple bundled-LLM experience. Their docs guide users through LM Studio or Ollama, and their app UI exposes provider setup rather than hiding all model/runtime complexity.

Useful lessons:

1. Put default local URLs and model refresh behind the UI.
2. Detect running local apps instead of asking users to type endpoints.
3. Filter or recommend models that are likely to work for the task.
4. Keep a health check close to setup.
5. Avoid making the main product onboarding depend on AI setup.

MacParakeet should take the convenience lessons, but not copy the docs-heavy setup. The app should do more of the guiding directly in Settings.

References:

- Char quick start: https://char.com/docs/getting-started/quick-start/
- Char local LLM setup: https://char.com/docs/faq/local-llm-setup/
- Char local models: https://char.com/docs/developers/local-models/
- Hyprnote/Char repository: https://github.com/fastrepl/anarlog

### Baked-In LLM Review (2026-05-26)

The reviewed options split into two very different categories:

1. **OS-managed local LLM:** Apple Foundation Models on macOS 26+.
2. **App-managed local LLM:** MLX Swift LM, llama.cpp/GGUF, Cactus, or a bundled local server.

Decision:

1. Do not bundle MLX, llama.cpp, Cactus, Ollama, LM Studio, or model weights in stable MacParakeet.
2. Treat Apple Foundation Models as a future optional provider candidate, not as part of the current setup UX slice.
3. If accepted, ship Apple Foundation Models first for short prompts: AI formatter, Transforms, and recent-window Live Ask.
4. Do not use it as the default full-transcript summary engine. Apple's on-device model has a 4096-token context window, so real meeting transcripts often exceed it.
5. Do not auto-fallback from Apple Foundation Models to cloud. ADR-011 currently rejects automatic fallback, and privacy expectations are clearest when the user explicitly chooses the provider.

The implementation plan for a future coding agent is in `docs/research/apple-foundation-models.md`.

### Competitive Setup Pattern (2026-05-26)

The open-source field mostly separates capture from LLM setup:

| Project | LLM setup shape | Product lesson |
|---|---|---|
| [Char / Hyprnote / Anarlog](https://github.com/fastrepl/anarlog) | Bring-your-own provider: LM Studio, Ollama, OpenAI, Anthropic, Gemini, OpenRouter, OpenAI-compatible. [Char docs](https://char.com/docs/faq/local-llm-setup) walk users through running LM Studio or Ollama. | Provider-based local AI is normal; the app should carry more of the guidance than docs do. |
| [Steno](https://github.com/ruzin/stenoai) | Bundles helper binaries and uses an in-app setup wizard to download/select local Ollama models, with optional cloud/custom providers. | This proves zero-config-ish local LLM is possible, but it accepts model download, model picker, runtime lifecycle, and support burden. |
| [Muesli](https://github.com/pHequals7/muesli) | Optional summary setup during onboarding: OpenAI, OpenRouter, ChatGPT OAuth, or local Ollama. | Existing subscription sign-in can be a friendlier path than asking every user for an API key. |
| [OpenOats](https://github.com/yazinsai/OpenOats) | Ollama for fully local suggestions/embeddings; OpenRouter/Voyage/OpenAI-compatible for cloud mode. | Be explicit about what text leaves the Mac in each mode. |
| [Minutes](https://github.com/silverstein/minutes) | Agent CLI, Ollama, Mistral, or OpenAI-compatible summarization; MCP/CLI/files are the main value. | Own the artifact and automation layer; let users bring the intelligence engine. |
| [Meetily](https://github.com/Zackriya-Solutions/meetily) | Recommends Ollama locally; also supports Claude, Groq, OpenRouter, and OpenAI-compatible endpoints. | Local-provider-first is a common OSS compromise. |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | Enhancement providers include Ollama, OpenAI, Gemini, Anthropic, OpenRouter, Mistral, Groq, Cerebras, custom OpenAI-compatible endpoints, and Local CLI in source. | Keep AI enhancement setup separate from STT setup; show connected status, provider key links, and Keychain-backed API keys. |
| Open WebUI / Jan / LobeChat | Popular open-source AI apps use provider cards, local-server readiness, model discovery, manual model-ID fallback, and metadata-driven provider templates. | Copy the connection mechanics and failure clarity, not their admin-console/provider-catalog complexity. |
| [ownscribe](https://github.com/paberr/ownscribe) | CLI downloads a built-in Phi-4-mini model on first run, with Ollama/LM Studio/OpenAI-compatible alternatives. | Built-in model download can work for CLI tools, but it still makes the product own model management. |
| [Pensieve](https://github.com/lukasbach/pensieve) | Local STT is bundled; summaries use user-connected Ollama or OpenAI. | Many tools own capture/STT but avoid owning LLM inference. |

Decision for MacParakeet: do not hide the optional LLM setup behind jargon, and
do not turn the app into a model manager just to remove one setup step.

There is no single gold-standard reference to copy wholesale. The best combined
pattern is:

1. Show the saved readiness state first.
2. Ask the user to choose one setup lane.
3. Render only that lane's provider-specific fields.
4. Keep `Save and Test`, model refresh, custom model ID fallback, and clear
   local/cloud privacy copy next to the selected lane.
5. Keep OpenAI-compatible endpoints and command-line tools available, but not
   in the default visual path.

## 3. Product Principles

AI is optional. Dictation, transcription, and meeting recording must stay usable with no AI provider configured.

AI being off is not an error state. The app should never imply capture is
unfinished or degraded because the user has not turned on summaries/chat.

The first-run contract:

1. Recording, transcription, notes, and export work before AI setup.
2. AI setup is optional and can happen later.
3. The setup verb is `Turn on AI`, not `Configure LLM provider`.
4. Provider details appear only inside setup paths and Advanced settings.
5. Active capture surfaces do not interrupt the user with AI setup prompts.

Settings is the source of truth. Transcript chat, summaries, and meeting Ask may show a small setup prompt when AI is missing, but they should not become provider dashboards.

Use audience-friendly language first:

| Technical term | User-facing copy |
|---|---|
| LLM | AI |
| Provider | AI option |
| LM Studio/Ollama endpoint | Local AI app |
| API endpoint/base URL | Advanced connection settings |
| OpenAI-compatible | Advanced API connection |
| Local CLI | Command-line AI tool |

Preferred status labels:

| Internal state | User-facing label |
|---|---|
| Configured and usable | Ready |
| No saved config | Set up needed |
| Last real attempt failed | Can't connect |

Do not show "Cloud provider configured" as a main feature-surface status. If AI is ready, the feature should just work.

## 4. Feature-Surface Behavior

Feature surfaces include transcript summaries, transcript chat, prompt actions, and meeting Ask.

Do not show AI setup prompts in the live recording control path. During capture,
the user's job is to record and take notes. Setup prompts belong in Settings,
post-meeting summary/chat empty states, or explicit AI actions.

### Ready

When a saved AI configuration exists and the last real attempt did not fail, show the normal feature UI. No setup card, no provider status badge, no repeated explanation.

### Set Up Needed

When no AI configuration exists, show a compact empty state in the relevant feature surface:

Title: `Turn on AI for summaries and chat`

Body: `MacParakeet can use a local AI app, your API key, or a command-line AI tool. Transcription still works without this.`

Primary action: `Set up AI`

The action opens Settings directly to the AI section.

### Can't Connect

When the last actual summary/chat/Ask attempt failed because the saved AI option could not be reached, show a compact error state:

Title: `AI can't connect`

Body: `Check that your selected AI option is running, then try again.`

Actions:

1. `Try Again`
2. `Open AI Settings`

This state should be based on real user activity, not speculative background probing.

## 5. Settings > AI Information Architecture

The AI settings surface should answer one question first: "Can MacParakeet use AI for summaries and chat right now?"

The UI must not be a provider catalog. The default shape is a two-step
configuration flow:

1. Show the saved state: `AI is off`, `AI is connected`, or
   `AI needs attention`.
2. If setup/change is active, show a compact path chooser.
3. After the user picks a path, show only that path's fields.
4. Put `Save and Test`, `Test`, model refresh, and cancel near the required
   fields, before optional token and advanced endpoint details.
5. Hide disabled formatter controls while setup is still in draft state.
6. Keep the existing provider details, endpoint fields, and model IDs as
   implementation plumbing inside the selected path.

This keeps the common empty and ready states short while preserving the full
BYO provider surface.

### Top Status

Card title: `AI for summaries and chat`

Possible states:

| State | Copy |
|---|---|
| Ready | `Ready: using <AI option name>.` |
| Set up needed | `Recording and transcription work now. Turn on AI for summaries, chat, and prompt actions.` |
| Can't connect | `MacParakeet could not reach <AI option name> the last time it tried.` |

Primary actions:

1. No saved setup: show setup choices directly.
2. Ready: `Test`, `Change Setup`.
3. Can't connect: `Test Again`, `Fix Setup`.

Disconnecting AI should remain possible but quiet: expose it as a subtle action
inside the setup/edit flow, not as a prominent destructive button in the ready
state.

If a user is experimenting with an unsaved provider and that draft test fails,
the top status should continue to reflect the saved provider as ready. Draft
errors belong next to the setup fields, not in the saved readiness banner.
If a setup draft is open, the outer card badge should say `Unsaved` instead of
claiming the saved provider is simply `Ready`.

### Setup Path Chooser

When setup is active, show these lanes:

1. `Local AI app` -- LM Studio or Ollama. Recommended. Best privacy, but the
   external app and model must already be installed/running.
2. `API key` -- Claude, OpenAI, Gemini, or OpenRouter. Best for users who
   already have an AI API key.
3. `Command-line tool` -- Codex, Claude Code, or custom command. Advanced
   agent workflow.
4. `Custom API endpoint` -- hidden under `More options`, for OpenAI-compatible
   local servers, gateways, or hosted APIs.

Only one selected path renders details at a time.

### Setup Path 1: Use A Local AI App

This is the recommended path, with LM Studio first.

Card title: `Use a local AI app`

Body: `Run AI on this Mac with a local app. Transcript text stays on this Mac.`

#### LM Studio - Recommended

LM Studio should be shown first and labeled `Recommended`.

Detection:

1. Probe `http://localhost:1234/v1/models`.
2. If models are returned, show `LM Studio detected`.
3. If no model is loaded or the server is not running, show clear next steps.

Primary happy path:

1. User starts LM Studio's local server.
2. MacParakeet detects models.
3. User clicks `Use LM Studio`.
4. MacParakeet saves `LLMProviderID.lmstudio`, the default base URL, and the selected model.
5. MacParakeet runs a connection test.

Setup guidance:

1. `Install LM Studio`
2. `Download a recommended model`
3. `Start the local server`
4. `Refresh`

Do not require the user to type `http://localhost:1234/v1` unless they open Advanced.

#### Ollama - Secondary

Ollama should be available below LM Studio, not ahead of it.

Detection:

1. Probe `http://localhost:11434/api/tags` or `http://localhost:11434/v1/models`.
2. If models are returned, show `Ollama detected`.
3. If no model is available, show setup commands.

Primary happy path:

1. User starts Ollama and pulls a model.
2. MacParakeet detects models.
3. User clicks `Use Ollama`.
4. MacParakeet saves `LLMProviderID.ollama`, the default base URL, and the selected model.
5. MacParakeet runs a connection test.

Setup commands:

```bash
brew install ollama
ollama pull qwen3.5:4b
ollama serve
```

The UI should also allow users who installed the Ollama desktop app to simply start it and click `Refresh`.

### Setup Path 2: Use An API Key

Card title: `Use an API key`

Body: `Use Claude, OpenAI, Gemini, OpenRouter, or another API service. Transcription stays local. Transcript text is sent only when you run an AI action.`

This path maps to the existing cloud and OpenAI-compatible provider configuration.

Providers:

1. Anthropic
2. OpenAI
3. Google Gemini
4. OpenRouter
5. OpenAI-compatible

### Setup Path 3: Use A Command-Line AI Tool

Card title: `Use a command-line AI tool`

Body: `Run a local command when MacParakeet needs AI. The command may contact its own service.`

This maps to `LLMProviderID.localCLI` and existing Local CLI configuration.

Good defaults:

1. Claude Code template
2. Codex template
3. Custom command

### Advanced

Advanced fields stay available, but collapsed by default:

1. Base URL
2. Model ID
3. Optional API key for compatible servers
4. Timeout for Local CLI

## 6. Readiness State Model

Add a small readiness model in `MacParakeetViewModels` so feature surfaces can stay simple.

Suggested shape:

```swift
public enum AIReadinessState: Equatable {
    case setUpNeeded
    case ready(displayName: String, isLocal: Bool)
    case cannotConnect(displayName: String, message: String)
}
```

Rules:

1. No saved config means `.setUpNeeded`.
2. Saved config with no failed last attempt means `.ready`.
3. Saved config with a failed last actual attempt means `.cannotConnect`.
4. Do not probe providers just because a transcript view appeared.
5. Connection tests and real AI feature attempts may update the last-attempt state.

This aligns with the Settings IA decision that AI is opt-in and should not create speculative warnings.

## 7. Implementation Phases

### Current PR Slice

This branch starts with the low-risk UX foundation:

1. Add the plan document.
2. Make Settings > AI use audience-friendly "AI setup" language.
3. Put LM Studio first as the recommended local app and Ollama second.
4. Let Ollama refresh installed models, matching LM Studio's model-list behavior.
5. Update transcript chat and meeting Ask no-provider copy.
6. Leave mandatory onboarding, bundled MLX/runtime work, and settings deep links out of this slice.

### Phase 1: Readiness State

Files likely touched:

1. `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
2. `Sources/MacParakeetCore/Services/LLMConfigStore.swift`
3. `Sources/MacParakeetCore/Services/LLMService.swift`

Work:

1. Add `AIReadinessState`.
2. Persist or derive "last actual AI attempt" state.
3. Expose a simple readiness value for feature surfaces.
4. Keep readiness independent from speculative detection.

### Phase 2: Feature Empty States

Files likely touched:

1. `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
2. `Sources/MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift`
3. Any summary/prompt-action no-provider state.

Work:

1. Replace provider jargon with the audience-friendly setup copy.
2. Hide setup UI entirely when AI is ready.
3. Add `Set up AI` deep link to Settings > AI.
4. Add retry/open-settings state for connection failures.

### Phase 3: Settings > AI Refresh

Files likely touched:

1. `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`
2. `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
3. Settings IA files if the active Settings overhaul lands first.

Work:

1. Add the top `AI for summaries and chat` status card.
2. Replace the provider-first picker with three setup paths.
3. Put LM Studio first under local AI apps.
4. Keep Ollama below LM Studio.
5. Move endpoint/model details into Advanced.
6. Preserve the existing provider config store and Keychain behavior.

### Phase 4: Local App Detection

Files likely touched:

1. New `LLMLocalProviderDetector` in `MacParakeetCore` or `MacParakeetViewModels`.
2. `LLMSettingsViewModel`.
3. Unit tests.

Work:

1. Detect LM Studio via `/v1/models`.
2. Detect Ollama via `/api/tags` and/or `/v1/models`.
3. Normalize discovered model names.
4. Show model picker only when models exist.
5. Never auto-save a detected provider without user action.

### Phase 5: One-Click Adoption

Work:

1. Add `Use LM Studio` and `Use Ollama` actions.
2. Save provider, base URL, and selected model.
3. Immediately run `Test`.
4. Surface clear failure copy if the local app stops responding.

### Phase 6: Tests

Required coverage:

1. `AIReadinessState` derivation.
2. Last-attempt success/failure behavior.
3. LM Studio model-list parsing.
4. Ollama model-list parsing.
5. One-click provider save behavior.
6. Feature-surface visibility rules for set-up-needed, ready, and can't-connect states.

Run `swift test` before declaring implementation complete.

### Future Phase: Apple Foundation Models Provider

This is deliberately outside the current AI setup UX slice. Start it only after
an ADR-011 amendment accepts OS-managed local providers as distinct from
app-bundled runtimes.

Files likely touched:

1. `spec/adr/011-llm-cloud-and-local-providers.md`
2. `Sources/MacParakeetCore/Models/LLMProvider.swift`
3. `Sources/MacParakeetCore/Services/LLM/RoutingLLMClient.swift`
4. New Foundation Models client/adapter in `MacParakeetCore`
5. `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
6. `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`
7. LLM service/context-budget tests

Work:

1. Add an explicit `Apple Intelligence` setup option only on macOS 26+.
2. Gate all `FoundationModels` symbols with availability checks.
3. Add token-aware prompt budgeting for the 4096-token context window.
4. Ship first on short-prompt features, then Live Ask with a recent transcript window.
5. Show a clear too-long state for full transcript summary/chat instead of silently chunking or falling back to cloud.
6. Keep CLI support deferred until the GUI provider proves stable.

## 8. Acceptance Criteria

1. A new user can understand AI setup without knowing what an LLM provider is.
2. Transcript chat, summaries, and meeting Ask show setup help only when AI is not configured.
3. When AI is configured, feature surfaces show the feature itself, not a setup card.
4. LM Studio is the first and recommended local path.
5. Ollama is available but secondary.
6. Users can connect to detected LM Studio or Ollama without typing a base URL.
7. API-key and Local CLI users still have complete configuration paths.
8. Advanced users can still override base URL and model ID.
9. STT behavior and STT model packaging are untouched.
10. No bundled local LLM runtime or model is added to the stable app.
11. If Apple Foundation Models is later added, it is an explicit OS-managed provider, not an app-bundled model and not a silent default.
12. No user-facing surface implies recording or transcription is broken because AI is off.
13. Live recording controls and notes never interrupt the meeting with AI setup prompts.
14. Empty-state copy uses `Turn on AI` / `Set up AI`, not `Configure provider`.

## 9. Explicit Non-Goals

1. Do not add `mlx-swift` or `mlx-swift-lm` to stable builds in this plan.
2. Do not bundle a local LLM model in the app DMG.
3. Do not make AI setup part of mandatory first-run onboarding.
4. Do not require AI for transcription, dictation, or meeting recording.
5. Do not remove Local CLI.
6. Do not remove cloud API providers.
7. Do not rewrite the LLM provider architecture unless a specific implementation blocker appears.
8. Do not add Apple Foundation Models without an ADR-011 amendment.
9. Do not auto-fallback from a local/on-device provider to cloud.
