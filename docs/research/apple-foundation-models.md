# Baked-In LLM Options - Apple Foundation Models Evaluation

> Status: **ACTIVE RESEARCH**
> Last verified: 2026-05-26
> Scope: MacParakeet LLM features only. Speech-to-text model shipping is out of scope.
> Governing ADR today: `spec/adr/011-llm-cloud-and-local-providers.md`

This note answers one narrow question: should MacParakeet have an LLM "baked
into the app" instead of requiring the user to configure a provider?

## Verdict

Do **not** bundle an LLM runtime or model inside the stable MacParakeet app.
That would reopen the exact ADR-008/ADR-011 failure mode: multi-GB model
distribution, GPU/RAM contention, runtime lifecycle, model license tracking,
quality regressions, and a much larger maintenance surface.

The only baked-in path worth pursuing is **Apple Foundation Models as an
optional built-in provider** on macOS 26+ systems where Apple Intelligence is
enabled. It is "built in" because the OS owns the model and runtime; it is not
an app-bundled model.

Recommended product stance:

1. Keep ADR-011's external-provider architecture for the stable product.
2. Keep LM Studio and Ollama as the best local provider paths for users on
   macOS 14/15 or for long-context local work.
3. Consider a future `appleFoundation` provider as the first "no API key, no
   local server" setup path on eligible Macs.
4. Do not make Apple Foundation Models the silent default without a deliberate
   ADR-011 amendment, because ADR-011 currently locks "no default provider" and
   "no automatic fallback between providers."
5. Do not use Apple Foundation Models for full transcript summaries unless the
   prompt fits its context window. It is best for short prompts, selected-text
   transforms, dictation cleanup, and recent-window Live Ask.

## What "Baked In" Can Mean

| Shape | Examples | Fit for MacParakeet |
|---|---|---|
| OS-provided local model | Apple Foundation Models | Best candidate. No model bundle, no API key, no local daemon, but macOS 26+ and Apple Intelligence gated. |
| App-bundled native runtime + weights | `mlx-swift-lm` + Qwen/Gemma/LLM weights | Not recommended for stable. Technically viable, but brings back model management, RAM/GPU cost, packaging, and runtime churn. |
| App-bundled C/C++ runtime + GGUF weights | `llama.cpp` / `libllama` / XCFramework | Not recommended for stable. Broad model support, but still app-managed weights and native bridging/runtime responsibility. |
| Third-party SDK bundled in app | Cactus, similar SDKs | Not recommended now. Licensing, model-format, and cloud-handoff concerns need separate legal/product decisions. |
| Bundled local server app | Ollama, LM Studio, llama-server | Not a good "baked in" shape. Treat as external provider support; do not install, launch, or supervise another app's daemon from MacParakeet. |

## Current Repo Boundary

Current implementation already has the right seam for adding a new local
provider:

- `LLMProviderID` defines providers.
- `LLMProviderConfig` stores provider ID, base URL, model name, and local flag.
- `RoutingLLMClient` routes Local CLI separately from HTTP providers.
- `LLMService` owns summary, chat, formatter, and transform operations.
- Settings already has AI readiness states and local provider ordering.

The architecture gap is not "where would this go?" The gap is whether the
provider should be allowed by the ADR and how to represent a non-HTTP,
OS-managed provider cleanly.

No database schema change is needed for an Apple Foundation provider. `llm_runs`
already stores provider/model strings as metadata. UserDefaults/Keychain config
is enough.

## Apple Foundation Models Deep Dive

Apple Foundation Models is the only option that changes the zero-config story
without shipping a model inside MacParakeet.

### Officially Verified Facts

Apple's developer docs describe Foundation Models as access to the on-device
large language model that powers Apple Intelligence. The model is text-based
and supports language understanding, text generation, structured output, and
tool calling.

Apple's public developer page says the framework provides direct access to the
on-device foundation model, works without internet connectivity, has native
Swift support, and is suitable for entity extraction, summarization, guided
generation, and tool calling.

Apple's Newsroom launch note says the framework became available with iOS 26,
iPadOS 26, and macOS 26, uses a 3B parameter on-device model, and works on
Apple Intelligence-compatible devices when Apple Intelligence is enabled.

Apple Support says Apple Intelligence on Mac requires an M1 or later Mac,
supported language/region settings, the user enabling Apple Intelligence, and
7 GB of storage for the on-device models. It also notes that models download
after the user turns Apple Intelligence on.

Apple's technote for Foundation Models context management says the on-device
model has a 4096-token context window per language model session. Instructions,
prompts, tool schemas and outputs, generated responses, and transcript entries
all count toward that same window.

Apple's Foundation Models updates page says macOS 26.4 changed the model and
developers should test prompts with the new model. It also added prompt
measurement APIs such as `tokenCount(for:)` and `contextSize`.

Apple's acceptable-use page prohibits several use categories, including
regulated healthcare, legal, financial services, employment-related decisions,
law-enforcement/criminal-justice uses, and attempts to bypass framework
guardrails. MacParakeet's generic transcript summarization/rewriting use case
is not inherently in those categories, but product copy must not pitch it as
professional regulated advice.

### Requirements

A MacParakeet user can use this provider only when all of these are true:

1. macOS 26+ for the developer framework.
2. Apple Silicon Mac compatible with Apple Intelligence.
3. Apple Intelligence enabled in System Settings.
4. The OS model has finished downloading and is ready.
5. The user's language/region/device combination supports Apple Intelligence.

MacParakeet's public minimum remains macOS 14.2+. The feature must therefore be
compiled and invoked behind availability checks. Older systems should simply
not see this setup path.

### Availability States

Do not collapse availability into one generic failure:

| Apple state | Meaning | MacParakeet UX |
|---|---|---|
| `.available` | Ready to run | Show "Apple Intelligence" as a setup option. |
| `.unavailable(.appleIntelligenceNotEnabled)` | Compatible Mac, user has not enabled OS feature | Offer System Settings guidance. Do not save provider yet. |
| `.unavailable(.modelNotReady)` | Model is downloading or otherwise not ready | Show "Apple Intelligence is getting ready" with Refresh. |
| `.unavailable(.deviceNotEligible)` | Device/region/language cannot use it | Hide the option or show non-actionable unsupported copy only in diagnostics. |
| unknown future case | Apple added a new reason | Treat as unavailable, preserve current provider. |

### Context Window Consequence

4096 tokens is the product-shaping constraint.

MacParakeet's current `LLMService` budgets are character-based:

- 500,000 characters for cloud providers.
- 80,000 characters for most local providers.
- 8,000 characters for LM Studio.

Apple Foundation Models needs a separate token-aware budget. A full transcript
cannot be assumed to fit. A 30-minute meeting often exceeds the model's window
before instructions, the user's question, and the response budget are added.

Do not silently chunk a long transcript in v1. Chunk-and-stitch can be useful
later, but it changes answer quality and makes "why did this answer miss
something?" harder to explain.

Recommended v1 behavior:

1. Use `contextSize` and `tokenCount(for:)` when available.
2. Refuse or truncate predictably before sending if the prompt will not fit.
3. Surface a clear "too long for Apple Intelligence" state.
4. Let the user choose another configured provider explicitly.
5. Do not automatically fall back to cloud. That conflicts with ADR-011's
   "no automatic fallback between providers" and with MacParakeet's privacy
   posture.

### Workload Fit

| Workload | Fit | Notes |
|---|---|---|
| AI dictation formatter | Strong | Short text, low latency, no provider setup. Good first integration. |
| Transforms | Strong for short selections | Selected text usually fits. Add a too-long state for large selections. |
| Live meeting Ask | Good for recent-window Ask | Use a short rolling transcript window. Avoid long-lived sessions that accumulate context. |
| Default transcript summary | Weak for real meeting length | Fine for short clips; most meetings need a longer-context provider. |
| Prompt Library custom summaries | Weak unless prompt and transcript are short | Use explicit fit checks. |
| Cross-meeting memory / agent workflows | Weak as primary engine | Context window and version drift make it a starter provider, not the agent substrate. |
| Screenshots/images/attachments | Not the answer | Foundation Models is a text model. Screenshot support needs OCR/text extraction first, or a separate VLM provider/runtime later. |

## App-Bundled Alternatives

### MLX Swift LM

`mlx-swift-lm` is the most natural native Swift app-bundled runtime. Its
current docs show a Swift package that loads LLM/VLM models, integrates with
Hugging Face downloaders/tokenizers, supports local model directories, and
has a broad registry including Qwen, Gemma, Llama/Mistral, Phi, DeepSeek, and
VLM families.

Why not stable-bundle it now:

1. It directly reopens ADR-008's removed path.
2. It adds SPM dependencies, tokenizer/downloader choices, model cache
   behavior, and runtime version churn.
3. Any useful default model still costs multiple GB on disk and several GB of
   unified memory under load.
4. It competes with the user's other GPU/Metal workloads.
5. It needs model licensing, download verification, cache retention, upgrade,
   unload, memory-pressure, and QA policy.

Use it only for a separate research branch or prototype if the product owner
explicitly wants to revisit ADR-011.

### llama.cpp / GGUF / libllama

`llama.cpp` is mature and broad. Its docs describe Apple Silicon Metal support,
GGUF model files, `llama-server` with an OpenAI-compatible API, CLI usage, and
an XCFramework option for Swift projects.

Why not stable-bundle it now:

1. It still makes MacParakeet responsible for model weights and model lifecycle.
2. It is a C/C++ integration surface inside a Swift app.
3. GGUF model selection and quantization become a product surface.
4. A local `llama-server` process would be a daemon MacParakeet must supervise,
   while in-process `libllama` still has memory/lifecycle pressure.
5. MacParakeet already supports this ecosystem safely through OpenAI-compatible
   local endpoints when the user chooses to run a server.

### Cactus

Cactus is technically interesting: it offers an Apple XCFramework, Swift usage,
on-device inference, small model support, and claimed low RAM via zero-copy
memory mapping. It also has a proprietary `.cact` model format and a hybrid
cloud handoff story.

Why not stable-bundle it now:

1. Its license is not simple open source for all commercial use. The public
   license grants use only to certain individuals/non-commercial users or
   organizations below funding/revenue thresholds; others need a commercial
   license.
2. Hybrid cloud handoff is contrary to MacParakeet's explicit provider-choice
   privacy model unless designed as a separate opt-in service.
3. The model format and SDK are another ecosystem MacParakeet would need to
   depend on, test, and explain.

Keep it on a watchlist, not in the stable app.

## Recommended Implementation Plan For A Future Agent

### Phase 0 - ADR Checkpoint

Before code, amend ADR-011 only if the owner accepts this precise exception:

> MacParakeet still does not bundle an LLM runtime or model. It may add
> OS-managed on-device providers, such as Apple Foundation Models, because the
> operating system owns model distribution and runtime lifecycle.

Do not remove these locked ideas:

1. LLM features remain optional.
2. Speech stays local.
3. Cloud transcript text is sent only by explicit user choice.
4. No automatic fallback between providers.
5. No app-bundled LLM runtime or weights in stable builds.

If the owner wants MacParakeet to auto-select Apple Intelligence for new users,
that is a second ADR change, because current ADR-011 says no default provider.
The safer first ship is an explicit "Use Apple Intelligence" button.

### Phase 1 - Provider Model

Add a provider ID:

```swift
case appleFoundation
```

Suggested properties:

| Property | Value |
|---|---|
| display name | `Apple Intelligence` |
| `isLocal` | `true` |
| supports API key | `false` |
| requires API key | `false` |
| requires custom endpoint | `false` |
| supports model selection | `false` |

Represent its config with a sentinel base URL that never routes to HTTP, such
as `apple-foundation://system`, or explicitly relax `LLMProviderConfig` so
non-HTTP providers are not forced into URL-shaped storage. The second option is
cleaner but touches more existing validation.

### Phase 2 - Client Boundary

Add an OS-managed client behind availability gates:

```swift
@available(macOS 26.0, *)
final class AppleFoundationLLMClient: LLMClientProtocol { ... }
```

Responsibilities:

1. Check `SystemLanguageModel.default.availability` for every operation.
2. Map unavailable reasons to `LLMError.connectionFailed` or a new typed error
   that Settings can render cleanly.
3. Implement `testConnection` as an availability check, not a generation call.
4. Implement `listModels` as a fixed system model list, or no-op if the UI hides
   model selection.
5. Use short-lived `LanguageModelSession` instances for chat/Ask rather than
   one long accumulating session.
6. Map context-window errors to `LLMError.contextTooLong`.
7. Preserve streaming behavior by adapting `streamResponse`.

Keep FoundationModels imports out of SwiftUI views and keep the provider inside
`MacParakeetCore` or a Core-adjacent adapter so feature surfaces still use
`LLMService`.

### Phase 3 - Routing

Teach `RoutingLLMClient` to route `.appleFoundation` to the new client. Do not
let it fall through to HTTP request construction.

Add focused tests with a protocol adapter/fake so unit tests can run on
non-eligible machines and older OS runners.

### Phase 4 - Settings UX

Add a first local setup path:

1. `Use Apple Intelligence` when available.
2. `Enable Apple Intelligence in System Settings` when compatible but disabled.
3. `Apple Intelligence is getting ready` when the model is downloading.
4. No API key, base URL, or model field for this provider.
5. Copy: `Built into macOS. Best for short prompts and selected-text rewrites.`

Do not auto-save it from passive detection. Save only when the user explicitly
chooses it.

### Phase 5 - Token Budgeting

Add an Apple-specific budget path before any prompt is sent:

1. Render the exact instructions/prompt/messages.
2. Count tokens with Foundation Models APIs when available.
3. Reserve response tokens.
4. If the call does not fit, return `contextTooLong` before starting a session.
5. Preserve existing character-budget paths for all other providers.

This must happen below the feature UI and above the provider client so every
surface gets the same behavior.

### Phase 6 - Rollout Order

Recommended first slices:

1. Provider type + availability/test-connection path.
2. Settings explicit "Use Apple Intelligence" tile.
3. AI formatter and Transforms only.
4. Live Ask with recent transcript window.
5. Short transcript summary support.
6. Only then decide whether to expose this in `macparakeet-cli`.

Defer:

1. Full transcript chunk-and-stitch.
2. Automatic cloud fallback.
3. Apple Foundation as default provider.
4. Image/screenshot understanding.
5. Custom adapters.

### Phase 7 - Tests And Manual Gates

Unit tests:

1. Provider metadata: local, no API key, no endpoint UI.
2. Settings availability state mapping.
3. Routing never builds HTTP requests for `.appleFoundation`.
4. Too-long prompts surface `contextTooLong`.
5. No auto-save from passive availability detection.
6. Existing providers still save/load unchanged.

Manual verification:

1. macOS 26.4+ Apple Silicon with Apple Intelligence enabled.
2. macOS 26.4+ compatible Mac with Apple Intelligence disabled.
3. macOS 26.4+ with model not ready, if reproducible.
4. macOS 14/15 build/run path: option hidden, existing providers unaffected.
5. Long transcript: clear too-long state, no cloud fallback without explicit user
   choice.
6. Confirm telemetry/logging does not include prompt, transcript, provider error
   body, or generated output.

## Acceptance Criteria

An Apple Foundation provider is ready to ship only when:

1. It does not bundle model weights or a third-party LLM runtime.
2. It works as an explicit user-selected provider.
3. It is unavailable without breaking macOS 14.2/15 users.
4. It has a clear too-long path for transcripts that exceed the context window.
5. It does not silently fall back to cloud.
6. It does not require a schema migration.
7. It leaves LM Studio, Ollama, cloud providers, OpenAI-compatible endpoints,
   and Local CLI intact.
8. It preserves the message: audio never leaves the Mac; text leaves the Mac
   only when the user chooses a non-local provider.

## Sources

Apple:

- Foundation Models documentation: https://developer.apple.com/documentation/FoundationModels
- Generating content and performing tasks: https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
- Context window technote TN3193: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- Foundation Models updates: https://developer.apple.com/documentation/updates/foundationmodels
- Apple Intelligence developer page: https://developer.apple.com/apple-intelligence/
- Apple Newsroom launch note: https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/
- Apple Intelligence requirements: https://support.apple.com/en-us/121115
- Acceptable use requirements: https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/

Runtime alternatives:

- MLX project page: https://opensource.apple.com/projects/mlx/
- MLX Swift LM: https://github.com/ml-explore/mlx-swift-lm
- MLX Swift LM supported models: https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/supported-models.md
- WWDC25 MLX session: https://developer.apple.com/videos/play/wwdc2025/298/
- llama.cpp: https://github.com/ggml-org/llama.cpp
- Cactus Swift SDK: https://docs.cactuscompute.com/latest/apple/
- Cactus license: https://github.com/cactus-compute/cactus/blob/main/LICENSE
