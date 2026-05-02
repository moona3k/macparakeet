# AI Setup UX Plan

> Status: **ACTIVE PLAN**
> Drafted: 2026-05-02
> ADR: `spec/adr/011-llm-cloud-and-local-providers.md`
> Related history: `spec/adr/008-local-llm-runtime-and-model.md`
> Scope: AI setup for summaries, transcript chat, prompt actions, and meeting Ask. Speech-to-text is unchanged.

## 1. Decision

Keep the stable product on the ADR-011 model: MacParakeet does not bundle a local LLM runtime or model in the app. Users can bring a local AI app, an API key, or a command-line AI tool.

The product work is to make that setup feel first-class and low-friction:

1. LM Studio is the recommended local path.
2. Ollama is the secondary local path.
3. API-key providers remain available for users who prefer cloud AI.
4. Local CLI stays available for advanced users and agent workflows.
5. Feature surfaces do not show provider plumbing once AI is configured.

This gives users a clean path to local summaries and chat without reopening the bundled-MLX decision that was already tried and removed.

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

## 3. Product Principles

AI is optional. Dictation, transcription, and meeting recording must stay usable with no AI provider configured.

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

### Top Status

Card title: `AI for summaries and chat`

Possible states:

| State | Copy |
|---|---|
| Ready | `Ready: using <AI option name>.` |
| Set up needed | `Choose how MacParakeet should run AI features.` |
| Can't connect | `MacParakeet could not reach <AI option name> the last time it tried.` |

Primary actions:

1. `Test`
2. `Change`
3. `Clear`

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

## 9. Explicit Non-Goals

1. Do not add `mlx-swift` or `mlx-swift-lm` to stable builds in this plan.
2. Do not bundle a local LLM model in the app DMG.
3. Do not make AI setup part of mandatory first-run onboarding.
4. Do not require AI for transcription, dictation, or meeting recording.
5. Do not remove Local CLI.
6. Do not remove cloud API providers.
7. Do not rewrite the LLM provider architecture unless a specific implementation blocker appears.
